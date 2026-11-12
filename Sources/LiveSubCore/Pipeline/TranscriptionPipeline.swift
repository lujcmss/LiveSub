import AVFAudio
import Foundation

/// Audio source → conditioner → recognizer → merged transcript, with per-stage latency.
public final class TranscriptionPipeline: @unchecked Sendable {
    public enum Event: Sendable {
        /// Model download progress, 0...1.
        case downloading(Double)
        /// The recognizer is loaded and audio is flowing.
        case ready(recognizer: String, format: String)
        /// The not-yet-final tail changed. `latencyMS`: age of its newest word.
        case partial(text: String, latencyMS: Double?, receivedHostTime: UInt64)
        /// A stretch of speech was finalized. `latencyMS`: age of its last word.
        case final(text: String, runs: [ASRResult.TimedRun], latencyMS: Double?, receivedHostTime: UInt64)
        /// A complete sentence is available (what translation will consume).
        case sentence(String)
        /// Speech paused (or playback jumped) here: whatever sentence was in progress is over,
        /// even if the recognizer gave it no closing punctuation.
        case sentenceBreak
    }

    public enum Stage {
        public static let capture = "1 capture → recognizer input"
        /// Cross-checked against the final result's word timing (see `WordLatencyTracker`).
        public static let word = "2 word spoken → first shown"
        /// As reported by the recognizer's own (rough) timing on partial results.
        public static let partial = "2b newest audio → partial text"
        public static let final = "3 word spoken → final text"
        public static let finalFromStart = "3b phrase start → final text"
        public static let display = "4 recognizer output → drawn on screen"
    }

    public let stats: LatencyStats
    public let timeline = AudioTimeline()
    private let source: AudioSource
    private let backend: ASRBackend
    private let chunkDuration: Double
    private let queue = DispatchQueue(label: "LiveSub.pipeline.audio", qos: .userInitiated)
    private var conditioner: AudioConditioner?
    /// Audio that arrives while the recognizer is still starting is fed once it is ready.
    private var accepting = false
    private var sawAudio = false
    /// In continuous dialogue the recognizer can hold text as "not final" for 10-15 s. Final
    /// text is what gets saved (with accurate timing) for replay, so that is too stale for a
    /// viewer who skips back a few seconds: after `commitLimit` seconds uncommitted, the
    /// pipeline asks for a commit.
    ///
    /// `commitAtPauses` goes further and commits at every pause in speech (once `commitAfter`
    /// seconds are pending), ending the sentence there. Measured on recordings this marks
    /// sentences complete about 0.45 s sooner (0.9 s → 0.44 s after the last word) and shows
    /// their translation about 0.3 s sooner, because the recognizer gives up its look-ahead.
    /// The price is accuracy: it also starts the next phrase without context, and on the test
    /// recording that turned a correctly heard word into a wrong one. Off by default.
    public var commitAtPauses = false
    public var commitAfter: Double = 1.5
    public var commitLimit: Double = 9
    /// Stream times of commits that should also end the sentence in progress.
    private var pendingBreaks: [Double] = []
    private var pauses = PauseDetector()
    private let commitLock = NSLock()
    /// Stream time (seconds fed) up to which text has been committed.
    private var committedThrough: Double = 0

    /// Ask the recognizer to finalize everything heard so far (e.g. the viewer just skipped
    /// back and the last few seconds are about to be replayed).
    /// - Parameter endsSentence: treat this point as the end of the sentence in progress.
    public func commitNow(secondsBack: Double = 0, endsSentence: Bool = false) {
        commitLock.lock()
        committedThrough = timeline.secondsFed - secondsBack
        if endsSentence { pendingBreaks.append(committedThrough) }
        commitLock.unlock()
        backend.finalizePending(secondsBack: secondsBack)
    }

    /// Whether a final result ending at `audioEnd` reaches a commit that ends a sentence.
    private func takeBreak(upTo audioEnd: Double) -> Bool {
        commitLock.lock(); defer { commitLock.unlock() }
        let reached = pendingBreaks.filter { $0 <= audioEnd + 0.35 }
        pendingBreaks.removeAll { $0 <= audioEnd + 0.35 }
        return !reached.isEmpty
    }

    private func noteCommitted(through seconds: Double) {
        commitLock.lock()
        committedThrough = max(committedThrough, seconds)
        commitLock.unlock()
    }
    /// Called on the audio queue with every chunk fed to the recognizer (set before `run`).
    public var onChunk: (@Sendable (AudioChunk) -> Void)?

    public init(source: AudioSource, backend: ASRBackend, chunkDuration: Double = 0.1, stats: LatencyStats = LatencyStats()) {
        self.source = source
        self.backend = backend
        self.chunkDuration = chunkDuration
        self.stats = stats
    }

    /// Runs until `stop()` is called or the source ends. Events are delivered in order.
    public func run(onEvent: @escaping @Sendable (Event) -> Void) async throws {
        let format = try await backend.prepare { onEvent(.downloading($0)) }
        let conditioner = AudioConditioner(format: format, chunkDuration: chunkDuration)
        self.conditioner = conditioner
        let results = try await backend.start()

        queue.sync { accepting = true }
        do {
            try source.start { [self] buffer in
                queue.async { self.ingest(buffer) }
            }
        } catch {
            // Don't leave the recognizer running if the audio never started.
            await backend.finish()
            throw error
        }
        let fmt = "\(Int(format.sampleRate)) Hz \(format.commonFormat == .pcmFormatInt16 ? "Int16" : "Float32"), \(Int(chunkDuration * 1000)) ms chunks"
        onEvent(.ready(recognizer: backend.name, format: fmt))

        var assembler = TranscriptAssembler()
        var segmenter = SentenceSegmenter()
        var words = WordLatencyTracker()
        for try await r in results {
            let spokenAt = timeline.hostTime(at: r.newestWordEnd ?? r.audioEnd)
            let latency = spokenAt.map { HostClock.ms(from: $0, to: r.receivedHostTime) }
            switch assembler.apply(r) {
            case .none:
                continue
            case .volatileUpdated:
                if let latency, !assembler.volatileText.isEmpty { stats.record(Stage.partial, ms: latency) }
                words.sawPartial(assembler.volatileText, at: r.receivedHostTime)
                onEvent(.partial(text: assembler.volatileText, latencyMS: latency, receivedHostTime: r.receivedHostTime))
            case let .finalized(segment):
                noteCommitted(through: r.audioEnd)
                if let latency { stats.record(Stage.final, ms: latency) }
                for ms in words.finalized(runs: r.timedRuns, at: r.receivedHostTime, captureTime: { self.timeline.hostTime(at: $0) }) {
                    stats.record(Stage.word, ms: ms)
                }
                if let start = timeline.hostTime(at: r.audioStart) {
                    stats.record(Stage.finalFromStart, ms: HostClock.ms(from: start, to: r.receivedHostTime))
                }
                onEvent(.final(text: segment.text, runs: r.timedRuns, latencyMS: latency, receivedHostTime: r.receivedHostTime))
                for s in segmenter.append(segment.text) { onEvent(.sentence(s)) }
                if takeBreak(upTo: r.audioEnd) {
                    if let tail = segmenter.flush() { onEvent(.sentence(tail)) }
                    onEvent(.sentenceBreak)
                }
                assembler.trim(keepingLast: 120)
            }
        }
        if let tail = segmenter.flush() { onEvent(.sentence(tail)) }
    }

    private func ingest(_ buffer: SourceBuffer) {
        guard accepting, let conditioner else { return }
        if !sawAudio {
            sawAudio = true
            Log.debug("first audio buffer: \(buffer.buffer.frameLength) frames, \(buffer.buffer.format)")
        }
        for chunk in conditioner.process(buffer) {
            let duration = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            timeline.append(duration: duration, startHostTime: chunk.startHostTime)
            backend.feed(chunk.buffer)
            let paused = pauses.note(levelDB: chunk.levelDB, duration: duration)
            commitLock.lock()
            let uncommitted = timeline.secondsFed - committedThrough
            commitLock.unlock()
            if commitAtPauses, paused, uncommitted >= commitAfter {
                commitNow(endsSentence: true)
            } else if uncommitted >= commitLimit {
                commitNow()
            }
            onChunk?(chunk)
            stats.record(Stage.capture, ms: HostClock.ms(from: chunk.endHostTime, to: HostClock.now()))
        }
    }

    /// Stop capturing, let the recognizer finish what it has, and end `run`.
    public func stop() async {
        source.stop()
        queue.sync { accepting = false }
        await backend.finish()
    }
}

/// Spots a pause in speech from loudness alone: the level drops well below recent speech for a
/// moment. Works with background music because it compares against the recent peak rather than
/// against silence.
public struct PauseDetector: Sendable {
    /// How far below the recent peak counts as a pause (dB), and for how long (seconds).
    public var drop: Float = 14
    public var hold: Double = 0.4
    /// Speech needed since the last pause before another one is reported (seconds).
    public var minimumSpeech: Double = 0.5

    private var peak: Float = -160
    private var quiet = 0.0
    private var speech = 0.0
    private var reported = false

    public init() {}

    /// Feed one chunk's level. Returns true once per pause, when it has lasted `hold` seconds.
    public mutating func note(levelDB: Float, duration: Double) -> Bool {
        // The reference peak fades slowly so a loud scene does not mask later quiet speech.
        peak = max(levelDB, peak - Float(duration) * 3)
        let isQuiet = levelDB < peak - drop || levelDB < -55
        if isQuiet {
            quiet += duration
            if quiet >= hold, !reported, speech >= minimumSpeech {
                reported = true
                speech = 0
                return true
            }
        } else {
            if quiet >= hold { reported = false }
            quiet = 0
            speech += duration
            reported = false
        }
        return false
    }
}
