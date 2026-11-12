import Foundation
import LiveSubCore

func listLanguages() async {
    let langs = await AppleSpeechBackend.languages()
    let kept = await AppleSpeechBackend.keptLanguages()
    print("Languages LiveSub can transcribe on this Mac (✓ installed, ↓ downloads on first use):\n")
    print("Kept for offline use (\(kept.count) of \(AppleSpeechBackend.maximumKeptLanguages) allowed by macOS): \(kept.sorted().joined(separator: ", "))\n")
    for engine in [AppleSpeechBackend.Engine.speechTranscriber, .dictation] {
        let group = langs.filter { $0.engine == engine }
        print(engine == .speechTranscriber ? "SpeechTranscriber (best quality, fastest):" : "\nDictationTranscriber (fallback for more languages):")
        for l in group {
            print("  \(l.isInstalled ? "✓" : "↓") \(l.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \(l.displayName)")
        }
    }
}

/// Console renderer: partials are redrawn in place (dim) on a terminal, finals are committed.
final class ConsoleRenderer: @unchecked Sendable {
    private let isTTY = isatty(STDOUT_FILENO) != 0
    private let showPartials: Bool
    private var partialOnScreen = false
    private let lock = NSLock()

    init(showPartials: Bool) { self.showPartials = showPartials }

    private func clearPartial() {
        if partialOnScreen, isTTY { print("\r\u{1B}[2K", terminator: "") }
        partialOnScreen = false
    }

    func handle(_ event: TranscriptionPipeline.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .downloading(p):
            line("Downloading speech model… \(Int(p * 100))%")
        case let .ready(recognizer, format):
            line("Ready: \(recognizer), \(format). Listening…\n")
        case let .partial(text, _, latency, _):
            guard showPartials, !text.isEmpty else { return }
            let tag = latency.map { String(format: " (%.0f ms)", $0) } ?? ""
            if isTTY {
                // Keep to one terminal row: show the tail of long partials.
                let tail = String(text.suffix(100))
                print("\r\u{1B}[2K\u{1B}[2m\(tail)\(tag)\u{1B}[0m", terminator: "")
                fflush(stdout)
                partialOnScreen = true
            } else {
                print("  ~ \(text)\(tag)")
            }
        case let .final(text, _, latency, _):
            clearPartial()
            let tag = latency.map { String(format: "  [final %.0f ms after last word]", $0) } ?? ""
            print("✓ \(text)\(isTTY ? "\u{1B}[2m\(tag)\u{1B}[0m" : tag)")
        case .sentence, .sentenceBreak, .idle:
            break
        }
    }

    func line(_ s: String) {
        clearPartial()
        print(s)
    }
}

@MainActor
func runTranscribe(_ opts: Options) throws {
    guard let lang = opts.lang else {
        print("transcribe needs --lang (for example --lang en-US). Run `livesub languages` for the list.")
        exit(2)
    }
    let source: AudioSource
    var fileSource: FileAudioSource?
    if let file = opts.file {
        let f = FileAudioSource(url: URL(fileURLWithPath: file))
        fileSource = f
        source = f
        print("Transcribing file \(file) at real-time pace")
    } else {
        source = ProcessTapSource(target: try resolveTarget(opts))
    }
    let engine: AppleSpeechBackend.Engine? = switch opts.engine {
    case "speech": .speechTranscriber
    case "dictation": .dictation
    default: nil
    }
    let renderer = ConsoleRenderer(showPartials: opts.partials)
    let chunk = opts.chunkMS / 1000
    let seconds: Double? = opts.secondsSet ? opts.seconds : nil

    Task {
        guard let language = await AppleSpeechBackend.resolve(lang, forcing: engine) else {
            print("No on-device speech model for \"\(lang)\". Run `livesub languages` for the list.")
            exit(1)
        }
        let backend = AppleSpeechBackend(language: language)
        let pipeline = TranscriptionPipeline(source: source, backend: backend, chunkDuration: chunk)
        let stop: @Sendable () -> Void = { Task { await pipeline.stop() } }
        fileSource?.onEnd = stop
        await MainActor.run { onStopRequest(after: seconds, stop) }

        let reporter = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                let report = pipeline.stats.report()
                if !report.isEmpty { renderer.line("── latency ──\n\(report)\n─────────────") }
            }
        }
        do {
            try await pipeline.run { renderer.handle($0) }
        } catch {
            renderer.line("error: \(error)")
            exit(1)
        }
        reporter.cancel()
        renderer.line("\n— Finished: \(String(format: "%.1f", pipeline.timeline.secondsFed)) s of audio —\nLatency:\n\(pipeline.stats.report())")
        exit(0)
    }
}
