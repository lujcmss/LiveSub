import AppKit
import LiveSubCore

/// Saves what is watched and recognizes it when it is watched again.
///
/// While subtitles run live, every sentence (with timing and translation) and a fingerprint of
/// the audio are collected and saved. When the audio of a saved session is heard again,
/// `currentRows` returns the saved subtitles for the exact position, so they can be shown with
/// no recognition delay at all.
@MainActor
final class ReplayController {
    static let stage = "R saved subtitle shown vs. start of its speech (negative = early)"

    let store: SessionStore
    /// Save new sessions to disk.
    var saveEnabled: Bool
    /// Show saved subtitles this many seconds before their speech starts.
    var lead: Double
    /// Seconds a saved subtitle stays after its speech ends.
    var linger: Double
    /// Called when the viewer skipped back within this session: the app should get everything
    /// heard so far committed, so the replayed stretch has final text.
    var onRewind: (() -> Void)?
    /// Called when replay starts, pauses, resumes or stops (argument: short status, nil = live).
    var onStatus: ((String?) -> Void)?

    private let stats: LatencyStats
    private(set) var sync: ReplaySync?
    private var captions: [CaptionTimeline.Caption] = []
    private var recordingID = UUID().uuidString
    private var recordingStarted = Date()
    private var language = ""
    private var target: String?
    private var sourceName = ""
    private var lastShownStart = -1.0
    private var lastStatus: String?
    private var savedCount = 0

    init(store: SessionStore = SessionStore(), saveEnabled: Bool, lead: Double, linger: Double, stats: LatencyStats) {
        self.store = store
        self.saveEnabled = saveEnabled
        self.lead = lead
        self.linger = linger
        self.stats = stats
    }

    /// Start listening for a new run. Returns the object the audio must be fed to.
    func begin(language: String, target: String?, sourceName: String) -> ReplaySync {
        self.language = language
        self.target = target
        self.sourceName = sourceName
        captions = []
        recordingID = UUID().uuidString
        recordingStarted = Date()
        lastShownStart = -1
        // Only sessions in the same languages can stand in for live subtitles.
        let usable = store.loadAll().filter { $0.sourceLanguage == language && $0.targetLanguage == target }
        savedCount = usable.count
        let sync = ReplaySync(sessions: usable, currentSessionID: recordingID)
        currentSnapshot = nil
        sync.onStateChange = { state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.stateChanged(state) } }
        }
        self.sync = sync
        let seconds = usable.reduce(0) { $0 + $1.duration }
        print("Saved sessions for \(language)\(target.map { "→\($0)" } ?? ""): \(usable.count) (\(Int(seconds)) s) in \(store.directory.path)")
        return sync
    }

    private func stateChanged(_ state: SessionMatcher.State) {
        switch state {
        case .searching:
            print(String(format: "replay: lost sync, back to live subtitles (last match quality %.2f)", sync?.diagnostics.lockedErrorRate ?? 1))
        case let .locked(id, delta):
            lastShownStart = -1
            if id == recordingID { onRewind?() }
            let heard = sync?.recording().seconds ?? 0
            Log.debug(String(format: "replay: lock quality %.2f (0 = identical, 0.5 = unrelated, limit 0.30)", sync?.diagnostics.lockedErrorRate ?? 1))
            print(String(format: "replay: in sync with saved session %@ (offset %.2f s) after %.1f s of audio", String(id.prefix(8)), Double(delta) * AudioFingerprinter.hopSeconds, heard))
        case let .paused(id, frame):
            print(String(format: "replay: paused at %.2f s of %@", Double(frame) * AudioFingerprinter.hopSeconds, String(id.prefix(8))))
        }
    }

    // MARK: Showing saved subtitles

    /// Saved subtitles for this instant, or nil when the audio is not from a saved session.
    func currentRows(now: UInt64 = HostClock.now()) -> [SubtitleView.Row]? {
        guard let position = sync?.position(at: now) else {
            report(nil)
            return nil
        }
        // Either a session saved earlier, or (after skipping back) this very session.
        let isRewind = position.session == nil
        guard let session = position.session ?? currentSession() else {
            report(nil)
            return nil
        }
        report(position.isPaused ? "Saved subtitles · paused"
               : isRewind ? "Replaying what you just watched · no delay" : "Saved subtitles · in sync, no delay")
        let visible = session.captions(at: position.time, lead: lead, linger: linger)
        if let newest = visible.last, newest.start != lastShownStart, !position.isPaused {
            // Only count captions as they come up in normal playback, not ones already on screen
            // when sync was (re)gained.
            if position.time - newest.start < 0.5 {
                stats.record(Self.stage, ms: (position.time - newest.start) * 1000)
            }
            lastShownStart = newest.start
        }
        return visible.map { SubtitleView.Row(source: $0.source, translation: $0.translation) }
    }

    private func report(_ status: String?) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus?(status)
    }

    /// Looks up the translation of a sentence from the current run (set by the app).
    var translations: (String) -> String? = { _ in nil }
    private var currentSnapshot: (count: Int, session: SubtitleSession)?

    /// The run in progress as a session, for replaying after the viewer skips back.
    private func currentSession() -> SubtitleSession? {
        if let snapshot = currentSnapshot, snapshot.count == captions.count { return snapshot.session }
        let session = SubtitleSession(id: recordingID, title: sourceName, createdAt: recordingStarted, sourceLanguage: language,
                                      targetLanguage: target, duration: 0, captions: timedCaptions(), fingerprints: [])
        currentSnapshot = (captions.count, session)
        return session
    }

    private func timedCaptions() -> [SubtitleSession.Caption] {
        captions.compactMap { c in
            guard let start = c.start, let end = c.end else { return nil }
            return .init(start: start, end: max(end, start), source: c.source, translation: translations(c.source))
        }
    }

    // MARK: Saving

    func record(_ new: [CaptionTimeline.Caption]) {
        // Sentences heard while replaying are already saved (and may be garbled at the point
        // where playback jumped): don't save them a second time.
        captions.append(contentsOf: new.filter { c in
            guard let sync, let start = c.start, let end = c.end else { return true }
            // A scrap of a word or two right after a replay is the tail of a cut-off sentence.
            if c.source.count <= 3, sync.replayEnded(shortlyBefore: start) { return false }
            return !sync.wasReplay(at: start) && !sync.wasReplay(at: (start + end) / 2)
        })
    }

    /// Write the current run to disk if it contains enough audio that was not already saved.
    @discardableResult
    func save() -> SubtitleSession? {
        guard saveEnabled, let sync else { return nil }
        let recording = sync.recording()
        let timed = timedCaptions()
        Log.debug(String(format: "save check: %.1f s heard, %.1f s new, %d captions (%d timed)", recording.seconds, recording.unmatchedSeconds, captions.count, timed.count))
        // A run that was (almost) entirely a replay adds nothing new.
        guard recording.unmatchedSeconds >= 10, !timed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let session = SubtitleSession(id: recordingID, title: "\(sourceName) · \(formatter.string(from: recordingStarted))",
                                      createdAt: recordingStarted, sourceLanguage: language, targetLanguage: target,
                                      duration: recording.seconds, captions: timed, fingerprints: recording.fingerprints)
        do {
            try store.save(session)
            return session
        } catch {
            print("error: could not save subtitles for replay: \(error)")
            return nil
        }
    }
}
