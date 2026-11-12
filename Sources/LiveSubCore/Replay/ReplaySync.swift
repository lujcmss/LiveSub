import AVFAudio
import Foundation

/// Listens to the live audio alongside the recognizer and (1) fingerprints it so the viewing can
/// be saved, (2) recognizes when it matches a saved session and tracks the position in it.
/// Thread-safe: `ingest` is called from the audio queue, everything else from the main thread.
public final class ReplaySync: @unchecked Sendable {
    public struct Position: Sendable {
        public let session: SubtitleSession
        /// Seconds into the saved session that are playing right now.
        public let time: Double
        public let isPaused: Bool
    }

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

    public init(sessions: [SubtitleSession]) {
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
        let changed = matcher.append(frames)
        if case .searching = matcher.state { unmatchedFrames += frames.count }
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
            guard let session = sessions[id] else { return nil }
            return Position(session: session, time: Double(frame) * AudioFingerprinter.hopSeconds, isPaused: true)
        case let .locked(id, delta):
            guard let session = sessions[id] else { return nil }
            // The newest live sample corresponds to this saved time; then run on the clock.
            // After a pause the matcher restarts its frame count, so use its own frame position.
            let liveFrames = matcher.liveFrameCount
            let framePosition = Double(liveFrames + delta) * AudioFingerprinter.hopSeconds
            // The newest complete frame starts (frameLength - hop) before the newest sample.
            let newestSample = framePosition + Double(AudioFingerprinter.frameLength - AudioFingerprinter.hop) / AudioFingerprinter.sampleRate
            // Run on the clock between chunks (they arrive every ~100 ms). If audio stops
            // arriving altogether (the player was paused), stop the clock too.
            let sinceChunk = max(0, HostClock.ms(from: lastChunkEnd, to: now) / 1000)
            return Position(session: session, time: newestSample + min(sinceChunk, 0.15), isPaused: sinceChunk > 0.35)
        }
    }

    // MARK: Recording

    /// Fingerprints of everything heard so far, and how much of it was not found in a saved session.
    public func recording() -> (fingerprints: [UInt32], seconds: Double, unmatchedSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        return (recorded, Double(samplesFed) / AudioFingerprinter.sampleRate, Double(unmatchedFrames) * AudioFingerprinter.hopSeconds)
    }
}
