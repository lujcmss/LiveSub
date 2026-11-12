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
                if let latency { stats.record(Stage.final, ms: latency) }
                for ms in words.finalized(runs: r.timedRuns, at: r.receivedHostTime, captureTime: { self.timeline.hostTime(at: $0) }) {
                    stats.record(Stage.word, ms: ms)
                }
                if let start = timeline.hostTime(at: r.audioStart) {
                    stats.record(Stage.finalFromStart, ms: HostClock.ms(from: start, to: r.receivedHostTime))
                }
                onEvent(.final(text: segment.text, runs: r.timedRuns, latencyMS: latency, receivedHostTime: r.receivedHostTime))
                for s in segmenter.append(segment.text) { onEvent(.sentence(s)) }
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
