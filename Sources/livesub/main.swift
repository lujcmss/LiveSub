import AppKit
import AVFAudio
import Foundation
import LiveSubCore

// Milestone 1 command-line front end: list audio apps, and capture an app (or all system
// audio) to WAV while measuring capture latency. Later milestones add transcription,
// the overlay and translation on top of the same LiveSubCore pipeline.

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage:
  livesub list
      Show apps that have audio clients (● = playing right now).
  livesub capture [--app NAME|BUNDLE_ID|PID] [--seconds N] [--out DIR]
                  [--chunk-ms N] [--rate HZ] [--gate-db DB]
      Capture audio to WAV. Without --app, captures all system audio.
      Writes <out>/capture-<time>-native.wav (tap format) and -16k.wav (recognizer format).
      Defaults: --seconds 30, --out ~/LiveSub/captures, --chunk-ms 100, --rate 16000, --gate-db -50.
      Ctrl-C (or SIGTERM) stops early and finalizes the files.
  livesub languages
      Show the languages that can be transcribed on this Mac (✓ = model already installed)
      and which are kept for offline use. `--lang ID --release` stops keeping one.
  livesub transcribe --lang LANG [--app NAME|BUNDLE_ID|PID | --file AUDIO] [--seconds N]
                     [--chunk-ms N] [--engine speech|dictation] [--no-partials]
      Live transcription to the console. Without --app or --file, listens to all system audio.
      --file plays an audio file through the pipeline in real time (silently), for testing.
      Prints running p50/p95 latency per stage every 10 s and at the end.
  livesub overlay --lang LANG [--app NAME | --file AUDIO] [--font-size PT] [--lines N]
                  [--click-through] [--idle-seconds N] [--seconds N]
      Floating subtitles over whatever is on screen, with a menu-bar icon (pause, click-through,
      move/resize, quit). --seconds quits automatically; otherwise use the menu-bar icon.
      Translates into your Mac's language by default; --to LANG (en, zh-Hans, zh-Hant, … or none)
      chooses the target, --translation-only hides the original.
  livesub translation-setup --lang LANG[,LANG…] --to LANG[,LANG…]
      Ask macOS to download the translation models for those pairs (one-time, needs one click each).
  livesub translate --lang LANG --to LANG --text "…"
      Translate one string and print how long it took.
"""

struct Options {
    var command = "help"
    var app: String?
    var seconds: Double = 30
    var out = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("LiveSub/captures")
    var chunkMS: Double = 100
    var rate: Double = 16_000
    var gateDB: Float = -50
    var lang: String?
    var file: String?
    var engine: String?
    var partials = true
    var secondsSet = false
    var fontSize: Double?
    var lines: Int?
    var clickThrough = false
    var idleSeconds: Double?
    var snapshot: String?
    var to: String?
    var text: String?
    var translationOnly = false
    var release = false
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var it = args.dropFirst().makeIterator()
    if let c = it.next() { o.command = c }
    while let a = it.next() {
        func val() -> String {
            guard let v = it.next() else { print("missing value for \(a)"); exit(2) }
            return v
        }
        switch a {
        case "--app": o.app = val()
        case "--seconds": o.seconds = Double(val()) ?? o.seconds; o.secondsSet = true
        case "--lang": o.lang = val()
        case "--file": o.file = (val() as NSString).expandingTildeInPath
        case "--engine": o.engine = val()
        case "--no-partials": o.partials = false
        case "--font-size": o.fontSize = Double(val())
        case "--lines": o.lines = Int(val())
        case "--click-through": o.clickThrough = true
        case "--to": o.to = val()
        case "--text": o.text = val()
        case "--translation-only": o.translationOnly = true
        case "--release": o.release = true
        case "--idle-seconds": o.idleSeconds = Double(val())
        case "--snapshot": o.snapshot = (val() as NSString).expandingTildeInPath
        case "--out": o.out = URL(fileURLWithPath: (val() as NSString).expandingTildeInPath)
        case "--chunk-ms": o.chunkMS = Double(val()) ?? o.chunkMS
        case "--rate": o.rate = Double(val()) ?? o.rate
        case "--gate-db": o.gateDB = Float(val()) ?? o.gateDB
        case "-v", "--verbose": Log.verbose = true
        default: print("unknown option \(a)\n\n\(usage)"); exit(2)
        }
    }
    return o
}

@MainActor
func listApps() throws {
    let apps = try AudioProcessCatalog.apps()
    if apps.isEmpty { print("No apps have opened audio yet. Start playback, then run list again."); return }
    for app in apps {
        let mark = app.isPlayingAudio ? "●" : "○"
        print("\(mark) \(app.name)  [\(app.bundleID)]")
        for p in app.processes {
            print("    pid \(p.pid)  \(p.bundleID ?? "?")\(p.isPlayingAudio ? "  (playing)" : "")")
        }
    }
}

/// Owns the capture session. All mutable state is confined to `queue`.
final class CaptureSession: @unchecked Sendable {
    let source: AudioSource
    let conditioner: AudioConditioner
    let stats = LatencyStats()
    let queue = DispatchQueue(label: "LiveSub.capture.process", qos: .userInitiated)
    let outDir: URL
    let stamp: String
    var nativeWAV: WAVRecorder?
    var asrWAV: WAVRecorder?
    var buffers = 0
    var chunks = 0, loudChunks = 0
    var peakDB: Float = -160
    var levelsThisSecond: [Float] = []
    var lastMeter = HostClock.now()
    var sawNonSilence = false

    init(source: AudioSource, opts: Options) {
        self.source = source
        conditioner = AudioConditioner(sampleRate: opts.rate, chunkDuration: opts.chunkMS / 1000, gateThresholdDB: opts.gateDB)
        outDir = opts.out
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        stamp = f.string(from: Date())
    }

    func start() throws {
        try source.start { [self] buf in queue.async { self.handle(buf) } }
        guard let fmt = source.format else { return }
        print("Tap format: \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, \(fmt.commonFormat == .pcmFormatFloat32 ? "Float32" : "\(fmt.commonFormat)")")
        print("Recognizer format: \(Int(conditioner.outputFormat.sampleRate)) Hz mono, \(Int(conditioner.chunkFrames)) frames per chunk")
    }

    private func handle(_ sb: SourceBuffer) {
        let processingStart = HostClock.now()
        buffers += 1
        stats.record("tap→callback", ms: HostClock.ms(from: sb.hostTime, to: sb.receivedHostTime))
        do {
            if nativeWAV == nil {
                nativeWAV = try WAVRecorder(url: outDir.appendingPathComponent("capture-\(stamp)-native.wav"), format: sb.buffer.format)
                asrWAV = try WAVRecorder(url: outDir.appendingPathComponent("capture-\(stamp)-16k.wav"), format: conditioner.outputFormat)
            }
            try nativeWAV?.write(sb.buffer)
            for chunk in conditioner.process(sb) {
                try asrWAV?.write(chunk.buffer)
                chunks += 1
                if chunk.isLoud { loudChunks += 1 }
                if chunk.levelDB > -100 { sawNonSilence = true }
                peakDB = max(peakDB, chunk.levelDB)
                levelsThisSecond.append(chunk.levelDB)
                // How old the newest sample in the chunk is when the chunk is ready for ASR.
                stats.record("chunk ready (newest sample age)", ms: HostClock.ms(from: chunk.endHostTime, to: chunk.emittedHostTime))
                // How old the oldest sample is; this is roughly what chunk size costs in latency.
                stats.record("chunk ready (oldest sample age)", ms: HostClock.ms(from: chunk.startHostTime, to: chunk.emittedHostTime))
            }
        } catch {
            Log.warn("write failed: \(error)")
        }
        stats.record("conditioning work", ms: HostClock.ms(from: processingStart, to: HostClock.now()))
        meter()
    }

    private func meter() {
        let now = HostClock.now()
        guard HostClock.ms(from: lastMeter, to: now) >= 1000, !levelsThisSecond.isEmpty else { return }
        lastMeter = now
        let loudest = levelsThisSecond.max()!
        levelsThisSecond.removeAll()
        let width = 40
        let filled = max(0, min(width, Int((loudest + 60) / 60 * Float(width))))
        let bar = String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
        let gate = loudest >= conditioner.gateThresholdDB ? "voice?" : "quiet "
        print(String(format: "%6.1fs  %@ %6.1f dBFS  %@", asrWAV?.duration ?? 0, bar, loudest, gate))
    }

    func stop() {
        source.stop()
        queue.sync {
            nativeWAV?.close()
            asrWAV?.close()
            print("\n— Capture finished —")
            print("Source: \(source.label)")
            if let w = nativeWAV { print(String(format: "Native WAV: %@ (%.1f s)", w.url.path, w.duration)) }
            if let w = asrWAV { print(String(format: "16 kHz WAV: %@ (%.1f s)", w.url.path, w.duration)) }
            if nativeWAV == nil { print("No audio buffers arrived at all.") }
            print("Buffers: \(buffers), chunks: \(chunks), above gate: \(loudChunks), peak \(String(format: "%.1f", peakDB)) dBFS")
            if buffers > 0 && !sawNonSilence {
                print("""
                ⚠︎ Every sample was silent. Either nothing was playing, or LiveSub does not have the
                  "System Audio Recording" permission (macOS delivers silence instead of an error).
                  Check System Settings › Privacy & Security › Screen & System Audio Recording.
                """)
            }
            print("Latency:\n" + stats.report())
        }
    }
}

@MainActor
func resolveTarget(_ opts: Options) throws -> ProcessTapSource.Target {
    let target: ProcessTapSource.Target
    if let q = opts.app {
        if let app = try AudioProcessCatalog.findApp(q) {
            target = .app(bundleID: app.bundleID, name: app.name)
            print("Capturing \(app.name) [\(app.bundleID)] via \(app.processes.count) audio process(es)")
        } else if let pid = pid_t(q), kill(pid, 0) == 0 {
            target = .pids([pid])
            print("Capturing process \(pid)")
        } else {
            print("No app matching \"\(q)\" has audio. Start playback in it first, or run `livesub list`.")
            exit(1)
        }
    } else {
        target = .systemWide
        print("Capturing all system audio (except LiveSub)")
    }
    return target
}

@MainActor
func runCapture(_ opts: Options) throws {
    let target = try resolveTarget(opts)
    let session = CaptureSession(source: ProcessTapSource(target: target), opts: opts)
    try session.start()
    print("Recording for up to \(Int(opts.seconds)) s. Ctrl-C to stop early.\n")

    onStopRequest(after: opts.seconds) {
        session.stop()
        exit(0)
    }
}

/// Run `handler` once on Ctrl-C / SIGTERM, or after `seconds` if given.
@MainActor
func onStopRequest(after seconds: Double?, _ handler: @escaping @Sendable () -> Void) {
    nonisolated(unsafe) var fired = false
    let once: @Sendable () -> Void = {
        if fired { return }
        fired = true
        handler()
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler(handler: once)
        src.resume()
        signalSources.append(src)
    }
    if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: once) }
}

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

var opts = parse(CommandLine.arguments)
// Opened as an app (double-click or `open LiveSub.app`) with no command: show subtitles for
// all system audio in the last-used language.
if CommandLine.arguments.count == 1, Bundle.main.bundlePath.hasSuffix(".app") {
    opts.command = "overlay"
    opts.lang = UserDefaults.standard.string(forKey: "LiveSub.sourceLanguage") ?? "ja-JP"
}
MainActor.assumeIsolated {
    do {
        switch opts.command {
        case "list":
            try listApps()
            exit(0)
        case "capture":
            try runCapture(opts)
        case "languages":
            Task {
                // `livesub languages --lang zh-CN --release` stops keeping a language installed.
                if let lang = opts.lang, opts.release {
                    print(await AppleSpeechBackend.stopKeeping(lang) ? "No longer keeping \(lang).\n" : "\(lang) was not being kept.\n")
                }
                await listLanguages()
                exit(0)
            }
        case "transcribe":
            try runTranscribe(opts)
        case "translation-setup":
            let sources = (opts.lang ?? "ja-JP").split(separator: ",").map { TranslationLanguage(speechLocale: String($0)) }
            let targets = (opts.to ?? "en").split(separator: ",").map { TranslationLanguage(speechLocale: String($0)) }
            runTranslationSetup(sources: sources, targets: targets)
        case "translate":
            guard let lang = opts.lang, let to = opts.to, let text = opts.text else {
                print("translate needs --lang, --to and --text"); exit(2)
            }
            Task {
                let source = TranslationLanguage(speechLocale: lang), target = TranslationLanguage(speechLocale: to)
                let status = await AppleTranslator.status(from: source, to: target)
                guard status == .installed else {
                    print("\(source.id)→\(target.id): \(status). Run `livesub translation-setup --lang \(lang) --to \(to)` first.")
                    exit(1)
                }
                let translator = AppleTranslator(source: source, target: target)
                for sentence in text.split(separator: "|") {
                    let t0 = HostClock.now()
                    do {
                        let out = try await translator.translate(String(sentence))
                        print(String(format: "%4.0f ms  %@  →  %@", HostClock.ms(from: t0, to: HostClock.now()), String(sentence), out))
                    } catch { print("error: \(error)") }
                }
                exit(0)
            }
        case "overlay":
            guard let lang = opts.lang else {
                print("overlay needs --lang (for example --lang ja-JP). Run `livesub languages` for the list.")
                exit(2)
            }
            // Remember the language for next launch (but not for timed test runs).
            if !opts.secondsSet { UserDefaults.standard.set(lang, forKey: "LiveSub.sourceLanguage") }
            var config = OverlayConfig(language: lang, appQuery: opts.app, file: opts.file)
            config.engine = opts.engine == "dictation" ? .dictation : opts.engine == "speech" ? .speechTranscriber : nil
            config.chunkDuration = opts.chunkMS / 1000
            if let size = opts.fontSize { config.style.fontSize = size }
            if let lines = opts.lines { config.style.maxLines = max(1, lines) }
            if let idle = opts.idleSeconds { config.idleSeconds = idle }
            config.clickThrough = opts.clickThrough
            // Translate into the chosen language, else the last one used, else the Mac's first
            // preferred language that isn't the source. `--to none` shows the original only.
            let target = opts.to ?? UserDefaults.standard.string(forKey: "LiveSub.targetLanguage")
                ?? AppleTranslator.defaultTarget(for: TranslationLanguage(speechLocale: lang)).id
            config.target = target == "none" ? nil : target
            if !opts.secondsSet, opts.to != nil { UserDefaults.standard.set(target, forKey: "LiveSub.targetLanguage") }
            config.translationOnly = opts.translationOnly
            config.snapshotDirectory = opts.snapshot.map { URL(fileURLWithPath: $0) }
            config.quitAfter = opts.secondsSet ? opts.seconds : nil
            runOverlayApp(config)
        default:
            print(usage)
            exit(opts.command == "help" || opts.command == "--help" ? 0 : 2)
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
// Keep the process alive (and the main queue serviced) while capturing.
dispatchMain()
