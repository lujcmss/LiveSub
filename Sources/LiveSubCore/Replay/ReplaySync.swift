import AVFAudio
import Foundation

/// Listens to the live audio alongside the recognizer and (1) fingerprints it so the viewing can
/// be saved, (2) recognizes when it matches a saved session and tracks the position in it.
/// Thread-safe: `ingest` is called from the audio queue, everything else from the main thread.
public final class ReplaySync: @unchecked Sendable {
    public struct Position: Sendable {
        /// The saved session being replayed, or nil when it is the session being recorded now
        /// (the viewer skipped back): see `currentSessionID`.
        public let session: SubtitleSession?
        public let sessionID: String
        /// Seconds into that session that are playing right now.
        public let time: Double
        public let isPaused: Bool
    }

    /// ID under which this run's own audio is matched (for skipping back within the run).
    public let currentSessionID: String
    /// Audio becomes matchable this long after it was heard. It must exceed the matching window
    /// so that live audio can never match itself.
    static let selfMatchDelayFrames = 320   // about 5 s
    private var matchable = 0

    /// Called (on the audio queue) when the matcher locks, pauses, resumes or loses the audio.
    public var onStateChange: (@Sendable (SessionMatcher.State) -> Void)?

    private let lock = NSLock()
    private let fingerprinter = AudioFingerprinter()
    private var matcher: SessionMatcher
    private var sessions: [String: SubtitleSession] = [:]
    private var recorded: [UInt32] = []
    private var samplesFed = 0
    private var lastChunkEnd: UInt64 = 0
    private var unmatchedFrames = 0

    public init(sessions: [SubtitleSession], currentSessionID: String = UUID().uuidString) {
        self.currentSessionID = currentSessionID
        matcher = SessionMatcher(references: sessions.map { .init(id: $0.id, fingerprints: $0.fingerprints) })
        for s in sessions { self.sessions[s.id] = s }
    }

    /// Feed the same 16 kHz chunks that go to the recognizer.
    public func ingest(_ chunk: AudioChunk) {
        let frames = fingerprinter.process(chunk.buffer)
        lock.lock()
        samplesFed += Int(chunk.buffer.frameLength)
        lastChunkEnd = chunk.endHostTime
        recorded.append(contentsOf: frames)
        // Make our own audio from a few seconds ago findable (for skipping back).
        let ready = recorded.count - Self.selfMatchDelayFrames
        if ready > matchable {
            matcher.extend(id: currentSessionID, with: Array(recorded[matchable..<ready]))
            matchable = ready
        }
        let changed = matcher.append(frames)
        if case .searching = matcher.state {
            unmatchedFrames += frames.count
            if replayStart != nil { endReplayInterval() }
        } else {
            // Audio that is itself a replay must not be saved again: blank it in the recording
            // (including the stretch it took to recognize it), and remember when it happened so
            // captions from it are skipped too.
            if replayStart == nil {
                // The replay began where the audio started agreeing with the saved session.
                // (Frame numbers here count from the start of the run, like `recorded`.)
                let first = max(matchable, min(recorded.count, matcherFrameOffset + matcher.lockStartFrame - 8))
                replayStart = Double(first) * AudioFingerprinter.hopSeconds
                for i in first..<recorded.count { recorded[i] = AudioFingerprinter.silent }
            } else {
                for i in max(matchable, recorded.count - frames.count)..<recorded.count { recorded[i] = AudioFingerprinter.silent }
            }
        }
        let state = matcher.state
        lock.unlock()
        if changed { onStateChange?(state) }
    }

    public var state: SessionMatcher.State {
        lock.lock(); defer { lock.unlock() }
        return matcher.state
    }

    /// Where we are in a saved session at host time `now`, if the audio has been recognized.
    public func position(at now: UInt64 = HostClock.now()) -> Position? {
        lock.lock(); defer { lock.unlock() }
        switch matcher.state {
        case .searching:
            return nil
        case let .paused(id, frame):
            guard sessions[id] != nil || id == currentSessionID else { return nil }
            return Position(session: sessions[id], sessionID: id, time: Double(frame) * AudioFingerprinter.hopSeconds, isPaused: true)
        case let .locked(id, delta):
            guard sessions[id] != nil || id == currentSessionID else { return nil }
            let session = sessions[id]
            // The newest live sample corresponds to this saved time; then run on the clock.
            // After a pause the matcher restarts its frame count, so use its own frame position.
            let liveFrames = matcher.liveFrameCount
            let framePosition = Double(liveFrames + delta) * AudioFingerprinter.hopSeconds
            // The newest complete frame starts (frameLength - hop) before the newest sample.
            let newestSample = framePosition + Double(AudioFingerprinter.frameLength - AudioFingerprinter.hop) / AudioFingerprinter.sampleRate
            // Run on the clock between chunks (they arrive every ~100 ms). If audio stops
            // arriving altogether (the player was paused), stop the clock too.
            let sinceChunk = max(0, HostClock.ms(from: lastChunkEnd, to: now) / 1000)
            return Position(session: session, sessionID: id, time: newestSample + min(sinceChunk, 0.15), isPaused: sinceChunk > 0.35)
        }
    }

    /// Matching quality right now, for logs: (bit error rate of the current lock, closest
    /// candidate while searching).
    public var diagnostics: (lockedErrorRate: Double, searchBest: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (matcher.lastErrorRate, matcher.lastSearchBest)
    }

    /// The matcher restarts its frame count after a pause; this keeps it comparable with
    /// `recorded`.
    private var matcherFrameOffset: Int { recorded.count - matcher.liveFrameCount }

    /// Seconds of the most recent audio that belong to the replay now in progress.
    public var secondsSinceReplayBegan: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let start = replayStart else { return nil }
        return Double(recorded.count) * AudioFingerprinter.hopSeconds - start
    }

    private var replayStart: Double?
    private var replayIntervals: [ClosedRange<Double>] = []

    private func endReplayInterval() {
        guard let start = replayStart else { return }
        // The last few frames before the lock was dropped were already new audio.
        let end = Double(max(0, recorded.count - matcher.unlockLagFrames)) * AudioFingerprinter.hopSeconds
        replayIntervals.append(start...max(start, end))
        replayStart = nil
    }

    /// Whether the audio at `streamSeconds` of this run was a replay of something already saved.
    public func wasReplay(at streamSeconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let start = replayStart, streamSeconds >= start { return true }
        return replayIntervals.contains { $0.contains(streamSeconds) }
    }

    /// Whether a replay ended within `window` seconds before `streamSeconds` (the first words
    /// after a replay are usually the cut-off tail of a sentence).
    public func replayEnded(shortlyBefore streamSeconds: Double, within window: Double = 1.5) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return replayIntervals.contains { streamSeconds >= $0.upperBound && streamSeconds - $0.upperBound <= window }
    }

    // MARK: Recording

    /// Fingerprints of everything heard so far, and how much of it was not found in a saved session.
    public func recording() -> (fingerprints: [UInt32], seconds: Double, unmatchedSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        return (recorded, Double(samplesFed) / AudioFingerprinter.sampleRate, Double(unmatchedFrames) * AudioFingerprinter.hopSeconds)
    }
}
