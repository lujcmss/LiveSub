import AppKit
import LiveSubCore

/// What to listen to and how to show it; filled from the command line now, Settings later.
struct OverlayConfig {
    var language: String
    var appQuery: String?
    var file: String?
    /// Translation target ("en", "zh-Hans", …); nil shows the original language only.
    var target: String?
    var translationOnly = false
    var engine: AppleSpeechBackend.Engine?
    var chunkDuration: Double = 0.1
    var style = SubtitleStyle()
    var clickThrough = false
    /// Seconds without new speech before the overlay fades out.
    var idleSeconds: Double = 5
    var snapshotDirectory: URL?
    var quitAfter: Double?
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var config: OverlayConfig
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var pipeline: TranscriptionPipeline?
    private var pipelineTask: Task<Void, Never>?
    private var engine = CaptionEngine(translator: nil)
    private var window = SentenceWindow()
    private var translationNote: String?
    /// Display mode picked from the menu (overrides the launch option).
    private var userMode: SubtitleStyle.DisplayMode?
    private let stats = LatencyStats()
    private var idleTimer: Timer?
    private var activity: NSObjectProtocol?
    private var statusLine = "Starting…"
    private var isPaused = false
    private var isReady = false
    private var isHovering = false
    private var isRepositioning = false
    private var snapshotIndex = 0
    private var lastSnapshot = ""

    init(config: OverlayConfig) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Subtitles are latency-critical: opt out of App Nap and timer coalescing, which
        // otherwise delay a background menu-bar app's drawing by ~100 ms.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Showing live subtitles")
        panel = OverlayPanel(style: config.style)
        panel.clickThrough = config.clickThrough
        panel.subtitleView.onDrawn = { [stats] stamp in
            stats.record(TranscriptionPipeline.Stage.display, ms: HostClock.ms(from: stamp, to: HostClock.now()))
        }
        panel.subtitleView.hoverChanged = { [weak self] inside in
            self?.isHovering = inside
            self?.refreshFrameOutline()
        }
        panel.orderFrontRegardless()
        Log.debug("overlay frame \(NSStringFromRect(panel.frame)), level \(panel.level.rawValue), behavior \(panel.collectionBehavior.rawValue), visible \(panel.isVisible), clickThrough \(panel.clickThrough), screen \(NSStringFromRect(NSScreen.main?.frame ?? .zero))")
        buildStatusItem()
        start()

        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [stats] _ in
            let report = stats.report()
            if !report.isEmpty { print("── latency ──\n\(report)\n─────────────") }
        }
        if let dir = config.snapshotDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.snapshot(to: dir) }
            }
        }
        if let seconds = config.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.quit() }
        }
    }

    // MARK: Pipeline

    private func start() {
        isPaused = false
        let config = self.config
        setStatus("Loading speech model…")
        panel.subtitleView.showNotice("Loading speech model…")
        showOverlay()

        pipelineTask = Task { [weak self] in
            guard let language = await AppleSpeechBackend.resolve(config.language, forcing: config.engine) else {
                self?.fail("LiveSub can't transcribe \"\(config.language)\" on this Mac.")
                return
            }
            let source: AudioSource
            let sourceName: String
            do {
                if let file = config.file {
                    let f = FileAudioSource(url: URL(fileURLWithPath: file))
                    f.onEnd = { Task { @MainActor in self?.sourceEnded() } }
                    source = f
                    sourceName = f.label
                } else if let query = config.appQuery {
                    guard let app = try AudioProcessCatalog.findApp(query) else {
                        self?.fail("\"\(query)\" isn't playing audio. Start playback, then choose Resume.")
                        return
                    }
                    source = ProcessTapSource(target: .app(bundleID: app.bundleID, name: app.name))
                    sourceName = app.name
                } else {
                    source = ProcessTapSource(target: .systemWide)
                    sourceName = "all audio"
                }
            } catch {
                self?.fail("Couldn't find audio to listen to: \(error)")
                return
            }
            guard let self else { return }
            await self.setUpTranslation(from: language)
            let backend = AppleSpeechBackend(language: language)
            let pipeline = TranscriptionPipeline(source: source, backend: backend,
                                                 chunkDuration: config.chunkDuration, stats: self.stats)
            self.pipeline = pipeline
            self.isReady = false
            // While macOS shows its permission dialog, starting the audio tap simply blocks.
            // Say so instead of leaving "Loading…" on screen.
            if config.file == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard self.pipeline === pipeline, !self.isReady, !self.isPaused else { return }
                    self.setStatus("Waiting for permission to hear your Mac's audio")
                    self.panel.subtitleView.showNotice("LiveSub needs permission to hear your Mac's audio. Click Allow in the macOS dialog.")
                    self.showOverlay()
                }
            }
            do {
                try await pipeline.run { event in
                    // Main queue (not a Task) so events are handled strictly in order.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.handle(event, sourceName: sourceName, language: language) }
                    }
                }
            } catch is CoreAudioError {
                // Typically: macOS is still showing its permission dialog, or it was denied.
                self.pipeline = nil
                print("error: system audio not available yet (permission pending or denied); retrying")
                self.setStatus("Needs permission: System Settings › Privacy & Security › Screen & System Audio Recording")
                self.panel.subtitleView.showNotice("LiveSub needs permission to hear your Mac's audio. Click Allow in the macOS dialog.")
                self.showOverlay()
                try? await Task.sleep(for: .seconds(3))
                if !self.isPaused, self.pipeline == nil, !Task.isCancelled { self.start() }
            } catch {
                self.fail("Transcription stopped: \(error)")
            }
        }
    }

    private func stop() async {
        await pipeline?.stop()
        pipeline = nil
        pipelineTask = nil
    }

    private func handle(_ event: TranscriptionPipeline.Event, sourceName: String, language: AppleSpeechBackend.Language) {
        guard !isPaused else { return }
        switch event {
        case let .downloading(fraction):
            let text = "Downloading \(language.displayName) speech model… \(Int(fraction * 100))%"
            setStatus(text)
            panel.subtitleView.showNotice(text)
        case let .ready(recognizer, format):
            isReady = true
            print("Ready: \(recognizer), \(format). Listening to \(sourceName).")
            setStatus("Listening to \(sourceName) · \(language.displayName)")
            rebuildMenu()
            panel.subtitleView.showNotice("Listening to \(sourceName)…")
            scheduleIdleFade(after: 2.5)
        case let .partial(text, _, received):
            engine.handlePartial(text)
            render(stamp: received)
        case let .final(text, latency, received):
            engine.handleFinal(text)
            print("✓ \(text)" + (latency.map { String(format: "  [final %.0f ms after last word]", $0) } ?? ""))
            render(stamp: received)
        case .sentence:
            break
        }
    }

    private func sourceEnded() {
        Task {
            await stop()
            print("\n— Source ended —\nLatency:\n\(stats.report())")
            if config.quitAfter == nil { setStatus("Finished") }
        }
    }

    private func fail(_ message: String) {
        print("error: \(message)")
        setStatus(message)
        panel.subtitleView.showNotice(message)
        showOverlay()
    }

    // MARK: Rendering

    /// Decide whether to translate, getting the model downloaded if needed, and set the
    /// display mode to match.
    private func setUpTranslation(from language: AppleSpeechBackend.Language) async {
        var translator: Translator?
        let source = TranslationLanguage(speechLocale: language.id)
        if let targetID = config.target, ProcessInfo.processInfo.environment["LIVESUB_STUB_TRANSLATION"] != nil {
            // Layout testing without installed models: a fake translator with realistic delay.
            translator = StubTranslator(tag: targetID)
            translationNote = "stub \(targetID)"
        } else if let targetID = config.target {
            let target = TranslationLanguage(speechLocale: targetID)
            if target.isSameLanguage(as: source) {
                print("Source and target are both \(target.displayName): showing the original only.")
            } else if await AppleTranslator.status(from: source, to: target) == .unsupported {
                print("error: Apple Translation does not support \(source.id)→\(target.id)")
                translationNote = "Can't translate \(source.displayName) → \(target.displayName)"
            } else {
                panel.subtitleView.showNotice("Preparing \(source.displayName) → \(target.displayName) translation…")
                if await TranslationModelInstaller.ensureInstalled(source: source, target: target) {
                    let apple = AppleTranslator(source: source, target: target)
                    translator = apple
                    // The first request loads the model (~0.5 s); do that before speech arrives.
                    Task { _ = try? await apple.translate("OK") }
                    translationNote = "\(source.displayName) → \(target.displayName)"
                    print("Translating \(source.id)→\(target.id) on-device")
                } else {
                    translationNote = "Translation model not downloaded"
                    print("error: translation model for \(source.id)→\(target.id) is not installed; showing the original only")
                }
            }
        }
        config.style.originalLanguage = source.id
        if let targetID = config.target { config.style.translationLanguage = TranslationLanguage(speechLocale: targetID).id }
        engine = CaptionEngine(translator: translator, stats: stats)
        engine.onChange = { [weak self] in self?.render(stamp: nil) }
        window.reset()
        if translator == nil {
            config.style.mode = .originalOnly
        } else if config.style.mode == .originalOnly || userMode == nil {
            config.style.mode = config.translationOnly ? .translationOnly : .both
        }
        if let userMode, translator != nil { config.style.mode = userMode }
        applyStyle()
    }

    private func applyStyle() {
        panel.subtitleView.style = config.style
        panel.applyHeight(for: config.style)
    }

    // MARK: Rendering

    private func render(stamp: UInt64?) {
        guard !isPaused else { return }
        let view = panel.subtitleView!
        var rows = engine.rows.map {
            SubtitleView.Row(source: $0.source, translation: $0.translation, isProvisional: $0.isProvisional)
        }
        if !rows.isEmpty { rows[rows.count - 1].tentativeCount = engine.tentativeCount }
        // Start at a sentence boundary: drop whole leading sentences until the rest fits.
        let first = window.firstVisible(count: rows.count) { view.fits(Array(rows[$0...])) }
        view.update(rows: Array(rows.dropFirst(first)), stamp: stamp)
        guard !rows.isEmpty else { return }
        showOverlay()
        scheduleIdleFade(after: config.idleSeconds)
    }

    private func showOverlay() {
        idleTimer?.invalidate()
        panel.animator().alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// When speech stops, fade the subtitles away so they don't sit on top of the picture.
    private func scheduleIdleFade(after seconds: Double) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRepositioning else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.6
                    self.panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        guard self.panel.alphaValue == 0 else { return }
                        self.engine.clearScreen()
                        self.window.reset()
                        self.panel.subtitleView.update(rows: [])
                    }
                })
            }
        }
    }

    private func refreshFrameOutline() {
        panel.subtitleView.showsFrame = isHovering || isRepositioning
    }

    private func snapshot(to dir: URL) {
        let key = "\(engine.rows)|\(engine.tentativeCount)|\(panel.alphaValue)"
        guard key != lastSnapshot, panel.alphaValue > 0.5, let png = panel.subtitleView.snapshotPNG() else { return }
        lastSnapshot = key
        snapshotIndex += 1
        Log.debug("snapshot \(snapshotIndex): \(engine.rows.map { "[\($0.source) | \($0.translation.map { "'\($0)'" } ?? "nil") | prov \($0.isProvisional)]" }.joined(separator: " "))")
        try? png.write(to: dir.appendingPathComponent(String(format: "overlay-%03d.png", snapshotIndex)))
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "LiveSub")
            button.toolTip = "LiveSub"
        }
        rebuildMenu()
    }

    private func setStatus(_ text: String) {
        statusLine = text
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let translationNote {
            let note = NSMenuItem(title: "Translation: \(translationNote)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        menu.addItem(item(isPaused ? "Resume Subtitles" : "Pause Subtitles", #selector(togglePause), key: "p"))
        if engine.translator != nil {
            let show = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, mode) in [("Original and Translation", SubtitleStyle.DisplayMode.both),
                                  ("Translation Only", .translationOnly), ("Original Only", .originalOnly)] {
                let i = item(title, #selector(chooseMode(_:)), key: "")
                i.representedObject = mode.rawValue
                i.state = config.style.mode == mode ? .on : .off
                sub.addItem(i)
            }
            show.submenu = sub
            menu.addItem(show)
        }
        let through = item("Click Through Subtitles", #selector(toggleClickThrough), key: "t")
        through.state = panel.clickThrough ? .on : .off
        menu.addItem(through)
        menu.addItem(item("Move or Resize Subtitles…", #selector(reposition), key: "m"))
        menu.addItem(item("Reset Position", #selector(resetPosition), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit LiveSub", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func togglePause() {
        if isPaused {
            start()
        } else {
            isPaused = true
            Task { await stop() }
            engine.clearScreen()
            window.reset()
            panel.subtitleView.update(rows: [])
            setStatus("Paused")
        }
        rebuildMenu()
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SubtitleStyle.DisplayMode(rawValue: raw) else { return }
        userMode = mode
        config.style.mode = mode
        window.reset()
        applyStyle()
        render(stamp: nil)
        rebuildMenu()
    }

    @objc private func toggleClickThrough() {
        panel.clickThrough.toggle()
        rebuildMenu()
    }

    /// Show the window outline for a while so it can be dragged and resized even when no
    /// subtitles are on screen (and even in click-through mode).
    @objc private func reposition() {
        isRepositioning = true
        let wasClickThrough = panel.clickThrough
        panel.clickThrough = false
        if panel.subtitleView.isEmpty { panel.subtitleView.showNotice("Drag to move · drag the left or right edge to resize") }
        refreshFrameOutline()
        showOverlay()
        Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRepositioning = false
                self.panel.clickThrough = wasClickThrough
                self.refreshFrameOutline()
                self.scheduleIdleFade(after: 0.5)
            }
        }
    }

    @objc private func resetPosition() {
        panel.placeDefault()
        reposition()
    }

    @objc func quit() {
        // Never hang on quit, even if the recognizer is slow to wind down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        Task {
            await stop()
            print("\n— Quit —\nLatency:\n\(stats.report())")
            NSApp.terminate(nil)
        }
    }
}

nonisolated(unsafe) private var retainedController: AppController?

/// Start the menu-bar app. Does not return.
@MainActor
func runOverlayApp(_ config: OverlayConfig) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    let controller = AppController(config: config)
    retainedController = controller
    app.delegate = controller
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { controller.quit() } }
        src.resume()
        signalSources.append(src)
    }
    app.run()
    exit(0)
}

/// Development aid (LIVESUB_STUB_TRANSLATION=1): pretends to translate, to exercise the layout.
private struct StubTranslator: Translator {
    let tag: String
    var name: String { "stub" }
    func translate(_ text: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(120))
        return "(\(tag)) This is where the translation of a \(text.count)-character sentence goes."
    }
}
