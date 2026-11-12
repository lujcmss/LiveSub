import AppKit
import Carbon.HIToolbox
import Combine
import LiveSubCore

/// What one run listens to and how it shows it. The user-facing choices are copied in from
/// `AppSettings`; the rest are options for test runs.
struct OverlayConfig {
    var language: String = "ja-JP"
    var appQuery: String?
    var file: String?
    /// Translation target ("en", "zh-Hans", …); nil shows the original language only.
    var target: String?
    var engine: AppleSpeechBackend.Engine?
    var chunkDuration: Double = 0.1
    var style = SubtitleStyle()
    var clickThrough = false
    /// Seconds without new speech before the overlay fades out.
    var idleSeconds: Double = 5
    var snapshotDirectory: URL?
    var quitAfter: Double?
    /// Save subtitles so a second viewing can show them with no delay.
    var saveSessions = true
    /// Show saved subtitles this many seconds before the speech starts.
    var replayLead = 0.1
    /// Test aids for --file: start position and a simulated pause.
    var fileStartAt = 0.0
    var filePauseAt: Double?
    var filePauseFor = 0.0
    var filePauseSilence = false
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config: OverlayConfig
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var pipeline: TranscriptionPipeline?
    private var pipelineTask: Task<Void, Never>?
    private var engine = CaptionEngine(translator: nil)
    private var window = SentenceWindow()
    private var translationNote: String?
    private var replay: ReplayController!
    private var isReplaying = false
    private var replayRows: [SubtitleView.Row] = []
    let settings: AppSettings
    private var settingsObserver: AnyCancellable?
    private var restartTask: Task<Void, Never>?
    private var outputMonitor: AudioOutputMonitor?
    private let stats = LatencyStats()
    private var idleTimer: Timer?
    private var activity: NSObjectProtocol?
    private var statusLine = "Starting…"
    private var isPaused = false
    private var isReady = false
    private var isHovering = false
    private var isRepositioning = false
    private var isResizing = false
    private var resizeStartHeight: CGFloat = 0
    private var snapshotIndex = 0
    private var lastSnapshot = ""

    init(settings: AppSettings, config: OverlayConfig) {
        self.settings = settings
        self.config = config
        super.init()
        copySettingsIntoConfig()
    }

    /// Bring the user's choices into the run configuration.
    private func copySettingsIntoConfig() {
        config.language = settings.sourceLanguage
        config.appQuery = settings.sourceApp.isEmpty ? nil : settings.sourceApp
        config.target = settings.target
        config.style = settings.style(basedOn: config.style)
        config.clickThrough = settings.clickThrough
        config.idleSeconds = settings.idleSeconds
        config.saveSessions = settings.saveSessions
        config.replayLead = settings.replayLead
    }

    /// Called after any setting changed: restart listening if what we listen to changed,
    /// otherwise just restyle what is on screen.
    private func settingsChanged() {
        let before = [config.language, config.appQuery ?? "", config.target ?? "", "\(config.saveSessions)"]
        copySettingsIntoConfig()
        let after = [config.language, config.appQuery ?? "", config.target ?? "", "\(config.saveSessions)"]
        panel.clickThrough = config.clickThrough
        replay.lead = config.replayLead
        replay.linger = config.idleSeconds
        replay.saveEnabled = config.saveSessions
        applyStyle()
        window.reset()
        replayRows = []
        render(stamp: nil)
        rebuildMenu()
        guard before != after, !isPaused else { return }
        // Several settings often change together (and sliders fire repeatedly): restart once.
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self.stop()
            guard !Task.isCancelled, !self.isPaused else { return }
            self.engine.clearScreen()
            self.start()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Subtitles are latency-critical: opt out of App Nap and timer coalescing, which
        // otherwise delay a background menu-bar app's drawing by ~100 ms.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Showing live subtitles")
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            // The notification comes before the value changes; read it on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingsChanged() } }
        }
        panel = OverlayPanel(style: config.style)
        panel.remembersFrame = settings.persist
        panel.clickThrough = config.clickThrough
        panel.subtitleView.onDrawn = { [stats] stamp in
            stats.record(TranscriptionPipeline.Stage.display, ms: HostClock.ms(from: stamp, to: HostClock.now()))
        }
        // Dragging the window taller or shorter resizes the text to fit it.
        panel.onLiveResize = { [weak self] size in
            guard let self else { return }
            if !self.isResizing {
                self.isResizing = true
                self.resizeStartHeight = OverlayPanel.height(for: self.config.style)
            }
            // A sideways drag changes only the width: leave the text size alone.
            guard abs(size.height - self.resizeStartHeight) >= 1 else {
                self.window.reset()
                self.replayRows = []
                self.render(stamp: nil)
                return
            }
            let fitted = OverlayPanel.fontSize(forHeight: size.height, style: self.config.style)
            guard fitted != self.config.style.fontSize else { return }
            self.config.style.fontSize = fitted
            self.panel.subtitleView.style = self.config.style
            self.window.reset()
            self.replayRows = []
            self.render(stamp: nil)
        }
        panel.onEndResize = { [weak self] in
            guard let self, self.isResizing else { return }
            self.isResizing = false
            // Remember the size; this also snaps the window to fit the text exactly.
            if self.settings.fontSize != Double(self.config.style.fontSize) {
                self.settings.fontSize = Double(self.config.style.fontSize)
            } else {
                self.applyStyle()
            }
            self.scheduleIdleFade(after: 1.5)
        }
        panel.subtitleView.hoverChanged = { [weak self] inside in
            self?.isHovering = inside
            self?.refreshFrameOutline()
        }
        replay = ReplayController(saveEnabled: config.saveSessions, lead: config.replayLead,
                                  linger: config.idleSeconds, stats: stats)
        replay.onStatus = { [weak self] status in
            guard let self else { return }
            if let status {
                self.setStatus(status)
            } else if self.isReady {
                self.setStatus(self.liveStatus)
            }
        }
        // Saved subtitles are driven by the clock, not by recognizer events.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickReplay() }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.transcriptWindow.isVisible else { return }
                self.transcriptWindow.update(self.currentTranscript())
            }
        }
        registerShortcuts()
        loadMenuLanguages()
        // First launch as an app: say what LiveSub is and what the permission dialog is for.
        if settings.persist, config.file == nil, !UserDefaults.standard.bool(forKey: "LiveSub.didWelcome") {
            UserDefaults.standard.set(true, forKey: "LiveSub.didWelcome")
            WelcomeWindowController.show { [weak self] in self?.openSettings() }
        }
        // Development aid: LIVESUB_SETTINGS_SNAPSHOT=DIR saves pictures of the Settings tabs.
        if let dir = ProcessInfo.processInfo.environment["LIVESUB_SETTINGS_SNAPSHOT"] {
            Task {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for tab in 0..<3 {
                    SettingsWindowController.show(settings: self.settings, store: self.replay.store, tab: tab) {}
                    self.render(stamp: nil)
                    try? await Task.sleep(for: .milliseconds(1500))
                    try? SettingsWindowController.snapshotPNG()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(tab).png"))
                    if tab == 1, let png = self.panel.subtitleView.snapshotPNG() {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample.png"))
                    }
                    SettingsWindowController.close()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        outputMonitor = AudioOutputMonitor { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.outputDeviceChanged() } }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession(announce: false) }
        }
        if Log.verbose {
            // Sanity check of drag-to-resize: a window sized for N pt must map back to N pt.
            for size in [14, 22, 30, 44, 72] as [CGFloat] {
                var probe = config.style
                probe.fontSize = size
                let h = OverlayPanel.height(for: probe)
                Log.debug("resize check: \(Int(size)) pt needs height \(Int(h)); that height gives \(Int(OverlayPanel.fontSize(forHeight: h, style: config.style))) pt")
            }
        }
        panel.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["LIVESUB_TEST_RESIZE"] != nil {
            // Self-test: drag edges in code and report what happens to the window and the text.
            Task {
                @MainActor func report(_ what: String) {
                    print(String(format: "resize test: %@ → frame %@, font %.0f pt (settings %.0f pt)", what, NSStringFromRect(self.panel.frame), self.config.style.fontSize, self.settings.fontSize))
                }
                let view = self.panel.subtitleView!
                try? await Task.sleep(for: .seconds(1))
                report("start")
                for (name, zone, dx, dy) in [("top edge up 70", SubtitleView.Zone.top, 0.0, 70.0), ("bottom edge up 50", .bottom, 0, 50),
                                             ("right edge left 200", .right, -200, 0), ("top-left corner out", [.top, .left], -100, 40)] {
                    view.simulateDrag(zone, dx: dx, dy: dy)
                    try? await Task.sleep(for: .milliseconds(300))
                    report(name)
                }
            }
        }
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

    /// Audio is arriving but it is pure digital silence: either nothing is playing, or macOS
    /// is withholding the audio because the permission was not granted.
    private func hearingOnlySilence(_ silent: Bool) {
        guard isReady, !isPaused, !isReplaying else { return }
        setStatus(silent ? "Hearing only silence. If something is playing, see Audio Permission Help" : liveStatus)
    }

    private func registerShortcuts() {
        let mods = controlKey | optionKey
        HotKeys.register(id: 1, keyCode: kVK_ANSI_C, modifiers: mods) { [weak self] in self?.copySentence() }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_E, modifiers: mods) { [weak self] in self?.explainInClaude() }
        HotKeys.register(id: 3, keyCode: kVK_ANSI_G, modifiers: mods) { [weak self] in self?.searchInGoogle() }
        HotKeys.register(id: 4, keyCode: kVK_ANSI_T, modifiers: mods) { [weak self] in self?.showTranscript() }
    }

    /// Headphones plugged in, AirPods connected…: the audio tap is tied to the old device.
    private func outputDeviceChanged() {
        guard config.file == nil, !isPaused, pipeline != nil else { return }
        print("Output device changed: restarting audio capture")
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self.stop()
            guard !Task.isCancelled, !self.isPaused else { return }
            self.start()
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
                    f.startAt = config.fileStartAt
                    f.pauseAt = config.filePauseAt
                    f.pauseFor = config.filePauseFor
                    f.pauseDeliversSilence = config.filePauseSilence
                    f.onEnd = { Task { @MainActor in self?.sourceEnded() } }
                    source = f
                    sourceName = f.label
                } else if let query = config.appQuery {
                    guard let app = try AudioProcessCatalog.findApp(query) else {
                        // The chosen app is not running or has not played anything yet: wait for it.
                        guard let self else { return }
                        let name = AppNames.name(forBundleID: query)
                        self.setStatus("Waiting for \(name) to play audio")
                        self.panel.subtitleView.showNotice("Waiting for \(name) to play something…")
                        self.scheduleIdleFade(after: 4)
                        try? await Task.sleep(for: .seconds(3))
                        if !self.isPaused, self.pipeline == nil, !Task.isCancelled { self.start() }
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
            let sync = self.replay.begin(language: language.id, target: self.engine.translator == nil ? nil : self.config.style.translationLanguage,
                                         sourceName: sourceName)
            let silence = SilenceWatch()
            pipeline.onChunk = { chunk in
                sync.ingest(chunk)
                if let hearingSilence = silence.note(chunk) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.hearingOnlySilence(hearingSilence) } }
                }
            }
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
        // Give the last finals (queued on the main queue) and their translations a moment.
        try? await Task.sleep(for: .milliseconds(250))
        if let tail = engine.flush() { replay.record([tail]) }
        try? await Task.sleep(for: .milliseconds(150))
        saveSession(announce: true)
    }

    private func saveSession(announce: Bool) {
        guard let session = replay.save(translations: { [engine] in engine.translation(for: $0) }) else { return }
        if announce {
            print(String(format: "Saved %d subtitles (%.0f s) for replay: %@", session.captions.count, session.duration,
                         replay.store.url(for: session.id).path))
        }
    }

    /// Show saved subtitles when the audio is recognized; hand back to live ones when it is not.
    private func tickReplay() {
        guard !isPaused, let rows = replay.currentRows() else {
            if isReplaying {
                isReplaying = false
                replayRows = []
                window.reset()
                render(stamp: nil)
            }
            return
        }
        if !isReplaying {
            isReplaying = true
            window.reset()
        }
        guard rows != replayRows else { return }
        replayRows = rows
        let view = panel.subtitleView!
        let first = window.firstVisible(count: rows.count) { view.fits(Array(rows[$0...])) }
        view.update(rows: Array(rows.dropFirst(first)))
        if rows.isEmpty {
            scheduleIdleFade(after: 0.3)
        } else {
            showOverlay()
        }
    }

    private var liveStatus = "Listening"

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
            liveStatus = "Listening to \(sourceName) · \(language.displayName)"
            setStatus(liveStatus)
            rebuildMenu()
            panel.subtitleView.showNotice("Listening to \(sourceName)…")
            scheduleIdleFade(after: 2.5)
        case let .partial(text, _, received):
            engine.handlePartial(text)
            render(stamp: received)
        case let .final(text, runs, latency, received):
            recordCaptions(engine.handleFinal(text, runs: runs))
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

    private func recordCaptions(_ captions: [CaptionTimeline.Caption]) {
        replay.record(captions)
        transcript.append(contentsOf: captions.map { .init(source: $0.source, translation: engine.translation(for: $0.source)) })
        if transcript.count > 2000 { transcript.removeFirst(transcript.count - 2000) }
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
        applyStyle()
    }

    private func applyStyle() {
        // Without a translator there is only the original to show.
        config.style.mode = engine.translator == nil ? .originalOnly : settings.displayMode
        panel.subtitleView.style = config.style
        panel.applyHeight(for: config.style)
    }

    // MARK: Rendering

    private func render(stamp: UInt64?) {
        // While saved subtitles are showing, live results are only collected, not drawn.
        guard !isPaused, !isReplaying else { return }
        let view = panel.subtitleView!
        var rows = engine.rows.map {
            SubtitleView.Row(source: $0.source, translation: $0.translation, isProvisional: $0.isProvisional)
        }
        if !rows.isEmpty { rows[rows.count - 1].tentativeCount = engine.tentativeCount }
        // Start at a sentence boundary: drop whole leading sentences until the rest fits.
        if rows.isEmpty, SettingsWindowController.isOpen || isResizing {
            // Nothing is being said: show a sample so appearance changes can be judged.
            view.update(rows: [sampleRow])
            showOverlay()
            return
        }
        let first = window.firstVisible(count: rows.count) { view.fits(Array(rows[$0...])) }
        view.update(rows: Array(rows.dropFirst(first)), stamp: stamp)
        guard !rows.isEmpty else { return }
        showOverlay()
        scheduleIdleFade(after: config.idleSeconds)
    }

    private static let samples: [String: String] = [
        "en": "This is how your subtitles will look.", "ja": "字幕はこのように表示されます。",
        "ko": "자막은 이렇게 표시됩니다.", "zh-Hans": "字幕会这样显示。", "zh-Hant": "字幕會這樣顯示。",
        "es": "Así se verán tus subtítulos.", "fr": "Voici à quoi ressembleront vos sous-titres.",
        "de": "So sehen deine Untertitel aus.", "it": "Ecco come appariranno i sottotitoli.", "pt": "É assim que as legendas vão aparecer.",
    ]

    private var sampleRow: SubtitleView.Row {
        let source = Self.samples[TranslationLanguage(speechLocale: settings.sourceLanguage).id] ?? Self.samples["en"]!
        let target = settings.target.flatMap { Self.samples[TranslationLanguage(speechLocale: $0).id] } ?? Self.samples["en"]!
        return SubtitleView.Row(source: source, translation: target)
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
                guard let self, !self.isRepositioning, !self.isResizing, !SettingsWindowController.isOpen else { return }
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

    func menuWillOpen(_ menu: NSMenu) {
        // Languages may have been installed since launch.
        if menu === statusItem.menu { loadMenuLanguages() }
    }

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

        // Quick pickers; the full lists are in Settings.
        menu.addItem(submenu("Spoken Language", menuLanguages.map { language in
            let i = item(language.displayName, #selector(chooseLanguage(_:)), key: "")
            i.representedObject = language.id
            i.state = language.id == settings.sourceLanguage ? .on : .off
            return i
        } + [.separator(), item("More Languages…", #selector(openSettings), key: "")]))

        var targetItems: [NSMenuItem] = [{
            let i = item("Don't Translate", #selector(chooseTarget(_:)), key: "")
            i.representedObject = "none"
            i.state = settings.targetLanguage == "none" ? .on : .off
            return i
        }(), .separator()]
        targetItems += menuTargets.prefix(8).map { language in
            let i = item(language.displayName, #selector(chooseTarget(_:)), key: "")
            i.representedObject = language.id
            i.state = language.id == settings.targetLanguage ? .on : .off
            return i
        }
        targetItems += [.separator(), item("More Languages…", #selector(openSettings), key: "")]
        menu.addItem(submenu("Translate Into", targetItems))

        var appItems: [NSMenuItem] = [{
            let i = item("Everything This Mac Plays", #selector(chooseApp(_:)), key: "")
            i.representedObject = ""
            i.state = settings.sourceApp.isEmpty ? .on : .off
            return i
        }(), .separator()]
        var apps = ((try? AudioProcessCatalog.apps()) ?? []).map { ($0.bundleID, $0.name + ($0.isPlayingAudio ? "  ●" : "")) }
        if !settings.sourceApp.isEmpty, !apps.contains(where: { $0.0 == settings.sourceApp }) {
            apps.insert((settings.sourceApp, AppNames.name(forBundleID: settings.sourceApp)), at: 0)
        }
        appItems += apps.map { bundleID, name in
            let i = item(name, #selector(chooseApp(_:)), key: "")
            i.representedObject = bundleID
            i.state = bundleID == settings.sourceApp ? .on : .off
            return i
        }
        menu.addItem(submenu("Listen To", appItems))

        if engine.translator != nil {
            menu.addItem(submenu("Show", [("Original and Translation", SubtitleStyle.DisplayMode.both),
                                          ("Translation Only", .translationOnly), ("Original Only", .originalOnly)].map { title, mode in
                let i = item(title, #selector(chooseMode(_:)), key: "")
                i.representedObject = mode.rawValue
                i.state = settings.displayMode == mode ? .on : .off
                return i
            }))
        }
        menu.addItem(.separator())
        menu.addItem(item("Copy Sentence", #selector(copySentence), key: "c", modifiers: [.control, .option]))
        menu.addItem(item("Explain in Claude", #selector(explainInClaude), key: "e", modifiers: [.control, .option]))
        menu.addItem(item("Search in Google", #selector(searchInGoogle), key: "g", modifiers: [.control, .option]))
        menu.addItem(item("Show Transcript", #selector(showTranscript), key: "t", modifiers: [.control, .option]))
        menu.addItem(.separator())
        let through = item("Click Through Subtitles", #selector(toggleClickThrough), key: "")
        through.state = panel.clickThrough ? .on : .off
        menu.addItem(through)
        menu.addItem(item("Move or Resize Subtitles…", #selector(reposition), key: "m"))
        menu.addItem(item("Reset Position", #selector(resetPosition), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Audio Permission Help…", #selector(openPrivacySettings), key: ""))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit LiveSub", #selector(quit), key: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for i in items { sub.addItem(i) }
        parent.submenu = sub
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let i = item(title, action, key: key)
        i.keyEquivalentModifierMask = modifiers
        return i
    }

    /// Languages for the quick menus: those installed for speech, and the translation targets.
    private var menuLanguages: [AppleSpeechBackend.Language] = []
    private var menuTargets: [TranslationLanguage] = []

    private func loadMenuLanguages() {
        Task {
            let all = await AppleSpeechBackend.languages()
            // One entry per language (the main regional variant), installed ones only.
            let preferred = ["en-US", "ja-JP", "ko-KR", "es-ES", "fr-FR", "zh-CN", "zh-TW", "de-DE", "it-IT", "pt-BR", "yue-CN"]
            var list = all.filter { $0.isInstalled && preferred.contains($0.id) }
            if let current = all.first(where: { $0.id == self.settings.sourceLanguage }), !list.contains(current) { list.append(current) }
            self.menuLanguages = list.sorted { $0.displayName < $1.displayName }
            self.menuTargets = await AppleTranslator.targetLanguages()
            self.rebuildMenu()
        }
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { settings.sourceLanguage = id }
    }

    @objc private func chooseTarget(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { settings.targetLanguage = id }
    }

    @objc private func chooseApp(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { settings.sourceApp = id }
    }

    /// Opens the pane where LiveSub can be allowed to record system audio.
    @objc private func openPrivacySettings() {
        let alert = NSAlert()
        alert.messageText = "LiveSub needs to hear your Mac's audio"
        alert.informativeText = "If subtitles never appear while something is playing, macOS is probably not letting LiveSub listen.\n\nIn System Settings › Privacy & Security › Screen & System Audio Recording, scroll to “System Audio Recording Only” and turn LiveSub on. Then choose Pause and Resume from the LiveSub menu."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openSettings() {
        SettingsWindowController.show(settings: settings, store: replay.store) { [weak self] in
            // Settings closed: stop holding the sample on screen.
            self?.scheduleIdleFade(after: 0.5)
        }
        render(stamp: nil)
    }

    // MARK: Copy, explain, transcript

    /// The sentence on screen right now (or the last one), with its translation.
    private var currentSentence: (source: String, translation: String?)? {
        if isReplaying, let row = replayRows.last { return (row.source, row.translation) }
        if let c = engine.currentSentence { return c }
        return transcript.last.map { ($0.source, $0.translation) }
    }

    @objc private func copySentence() {
        guard let sentence = currentSentence else { flash("Nothing to copy yet"); return }
        let text = [sentence.source, sentence.translation].compactMap { $0 }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied")
    }

    /// Opens the sentence in the browser. This is the one thing that leaves the Mac, and only
    /// when asked.
    @objc private func explainInClaude() {
        guard let sentence = currentSentence else { flash("Nothing to explain yet"); return }
        let language = Locale(identifier: "en").localizedString(forLanguageCode: TranslationLanguage(speechLocale: config.language).id) ?? "foreign-language"
        var prompt = "Explain this \(language) sentence from something I'm watching: what it means, how the grammar works, and any vocabulary or nuance worth knowing.\n\n\(sentence.source)"
        if let t = sentence.translation { prompt += "\n\nMy subtitles translated it as: \(t)" }
        open("https://claude.ai/new", query: prompt)
    }

    @objc private func searchInGoogle() {
        guard let sentence = currentSentence else { flash("Nothing to search yet"); return }
        open("https://www.google.com/search", query: sentence.source)
    }

    private func open(_ base: String, query: String) {
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// Brief confirmation next to the menu-bar icon.
    private func flash(_ text: String) {
        guard let button = statusItem.button else { return }
        button.title = " " + text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak button] in button?.title = "" }
    }

    private var transcript: [TranscriptWindow.Entry] = []
    private let transcriptWindow = TranscriptWindow()

    private func currentTranscript() -> [TranscriptWindow.Entry] {
        // Fill in translations that arrived after the sentence was recorded.
        for i in transcript.indices where transcript[i].translation == nil {
            transcript[i].translation = engine.translation(for: transcript[i].source)
        }
        return transcript
    }

    @objc private func showTranscript() {
        transcriptWindow.show(currentTranscript())
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
        settings.displayMode = mode
    }

    @objc private func toggleClickThrough() {
        settings.clickThrough.toggle()
    }

    /// Show the window outline for a while so it can be dragged and resized even when no
    /// subtitles are on screen (and even in click-through mode).
    @objc private func reposition() {
        isRepositioning = true
        let wasClickThrough = panel.clickThrough
        panel.clickThrough = false
        if panel.subtitleView.isEmpty { panel.subtitleView.showNotice("Drag to move · drag an edge to resize the text") }
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
func runOverlayApp(settings: AppSettings, config: OverlayConfig) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    let controller = AppController(settings: settings, config: config)
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

/// Notices when the incoming audio has been digital silence for a while (and when sound returns).
private final class SilenceWatch: @unchecked Sendable {
    private var silentSeconds = 0.0
    private var reported = false

    /// Returns true/false when the "only silence" state changes, nil otherwise. Audio queue only.
    func note(_ chunk: AudioChunk) -> Bool? {
        let duration = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
        if chunk.levelDB <= -120 {
            silentSeconds += duration
            if silentSeconds >= 20, !reported { reported = true; return true }
        } else {
            silentSeconds = 0
            if reported { reported = false; return false }
        }
        return nil
    }
}
