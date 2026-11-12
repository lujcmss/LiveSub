import AVFAudio
import Foundation

/// One recognizer update. Times are seconds on the stream timeline (0 = first sample fed).
public struct ASRResult: Sendable, Equatable {
    public var text: String
    /// Final results never change again; volatile ones are a fast guess that will be replaced.
    public var isFinal: Bool
    public var audioStart: Double
    public var audioEnd: Double
    /// End time of the last word in `text`, when the recognizer reports word timing.
    public var newestWordEnd: Double?
    /// Word timing as reported by the recognizer: each run of text and when its audio ended.
    public var timedRuns: [TimedRun]
    /// Host time at which the result came out of the recognizer.
    public var receivedHostTime: UInt64

    public struct TimedRun: Sendable, Equatable {
        public var text: String
        /// When this piece of text was spoken (seconds on the stream timeline).
        public var start: Double
        public var end: Double
        public init(text: String, start: Double? = nil, end: Double) {
            self.text = text
            self.start = start ?? end
            self.end = end
        }
    }

    public init(text: String, isFinal: Bool, audioStart: Double, audioEnd: Double,
                newestWordEnd: Double? = nil, timedRuns: [TimedRun] = [], receivedHostTime: UInt64 = 0) {
        self.text = text
        self.isFinal = isFinal
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.newestWordEnd = newestWordEnd
        self.timedRuns = timedRuns
        self.receivedHostTime = receivedHostTime
    }
}

/// Streaming speech-to-text. Implementations: `AppleSpeechBackend` (SpeechAnalyzer).
public protocol ASRBackend: AnyObject, Sendable {
    /// Short description, e.g. "SpeechTranscriber en-US".
    var name: String { get }
    /// Download/install models if needed and warm up. Returns the audio format to feed.
    /// `progress` reports model download progress in 0...1 (only called if a download happens).
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> AVAudioFormat
    /// Begin recognition. The stream ends after `finish()`.
    func start() async throws -> AsyncThrowingStream<ASRResult, Error>
    /// Feed the next contiguous block of audio, in the format returned by `prepare`.
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Ask for final results for everything fed so far, without ending recognition. Called at a
    /// pause in speech so finished sentences are committed (and translated) sooner.
    /// `secondsBack` leaves the most recent audio uncommitted.
    func finalizePending(secondsBack: Double)
    /// Flush pending audio, emit the last results and end the stream.
    func finish() async
}

/// Maps positions on the recognizer's stream timeline back to when that audio was captured,
/// so latency can be measured from "the moment the word was played". Thread-safe.
public final class AudioTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [(stream: Double, host: UInt64)] = []
    private var fedSeconds: Double = 0

    public init() {}

    /// Record that a chunk of `duration` seconds, whose first sample was captured at
    /// `startHostTime`, is about to be fed to the recognizer.
    public func append(duration: Double, startHostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        marks.append((fedSeconds, startHostTime))
        fedSeconds += duration
        if marks.count > 20_000 { marks.removeFirst(10_000) }
    }

    public var secondsFed: Double {
        lock.lock(); defer { lock.unlock() }
        return fedSeconds
    }

    /// Host time at which the audio at `streamSeconds` was captured.
    public func hostTime(at streamSeconds: Double) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard !marks.isEmpty else { return nil }
        // Last mark starting at or before the requested position.
        var lo = 0, hi = marks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if marks[mid].stream <= streamSeconds { lo = mid } else { hi = mid - 1 }
        }
        let m = marks[lo]
        let delta = streamSeconds - m.stream
        return delta >= 0 ? m.host &+ HostClock.ticks(seconds: delta) : m.host &- HostClock.ticks(seconds: -delta)
    }
}
