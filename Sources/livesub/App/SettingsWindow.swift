import AppKit
import LiveSubCore
import SwiftUI

/// The Settings window: what to listen to, languages, look, and saved subtitles.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let store: SessionStore

    @State private var apps: [AudioApp] = []
    @State private var languages: [AppleSpeechBackend.Language] = []
    @State private var targets: [TranslationLanguage] = []
    @State private var sessions: [SubtitleSession] = []
    @State private var keptLanguages: [String] = []
    @State var tab = 0

    static let fonts: [(name: String, label: String)] = [
        ("Avenir Next", "Avenir Next (default)"), ("system", "San Francisco"), ("rounded", "San Francisco Rounded"),
        ("Helvetica Neue", "Helvetica Neue"), ("Gill Sans", "Gill Sans"), ("Optima", "Optima"),
        ("Futura", "Futura"), ("Verdana", "Verdana"), ("Georgia", "Georgia"), ("Charter", "Charter"),
    ]

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "captions.bubble") }.tag(0)
            appearance.tabItem { Label("Appearance", systemImage: "textformat.size") }.tag(1)
            saved.tabItem { Label("Saved Subtitles", systemImage: "clock.arrow.circlepath") }.tag(2)
        }
        .frame(width: 520, height: 470)
        .task { await load() }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("Listen") {
                Picker("Audio from", selection: $settings.sourceApp) {
                    Text("Everything this Mac plays").tag("")
                    ForEach(appChoices, id: \.bundleID) { app in
                        Text(app.name + (app.isPlaying ? "  (playing)" : "")).tag(app.bundleID)
                    }
                }
                Picker("Spoken language", selection: $settings.sourceLanguage) {
                    ForEach(languageChoices, id: \.id) { language in
                        Text(language.label).tag(language.id)
                    }
                }
                Text("Pick the language being spoken. LiveSub never guesses it. Languages marked ↓ download once from Apple; macOS keeps up to \(AppleSpeechBackend.maximumKeptLanguages) installed for offline use.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Translate") {
                Picker("Translate into", selection: $settings.targetLanguage) {
                    Text("Don't translate").tag("none")
                    ForEach(targetChoices) { language in
                        Text(language.displayName).tag(language.id)
                    }
                }
                Text("Translation runs on this Mac. A language pair that isn't installed yet asks once to download.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Let clicks pass through the subtitles", isOn: $settings.clickThrough)
                LabeledContent("Hide after silence") {
                    Slider(value: $settings.idleSeconds, in: 2...15, step: 1)
                    Text("\(Int(settings.idleSeconds)) s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Section("Shortcuts") {
                LabeledContent("Copy current sentence", value: "⌃⌥C")
                LabeledContent("Explain in Claude", value: "⌃⌥E")
                LabeledContent("Search in Google", value: "⌃⌥G")
                LabeledContent("Show transcript", value: "⌃⌥T")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Appearance

    private var appearance: some View {
        Form {
            Section {
                Picker("Show", selection: $settings.displayMode) {
                    Text("Original and translation").tag(SubtitleStyle.DisplayMode.both)
                    Text("Translation only").tag(SubtitleStyle.DisplayMode.translationOnly)
                    Text("Original only").tag(SubtitleStyle.DisplayMode.originalOnly)
                }
                Stepper("Lines per language: \(settings.maxLines)", value: $settings.maxLines, in: 1...4)
            }
            Section("Text") {
                Picker("Font", selection: $settings.fontName) {
                    ForEach(Self.fonts, id: \.name) { Text($0.label).tag($0.name) }
                    Divider()
                    ForEach(otherFonts, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    Slider(value: $settings.fontSize, in: 16...64, step: 1)
                    Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                LabeledContent("Original line size") {
                    Slider(value: $settings.originalScale, in: 0.5...1, step: 0.05)
                    Text("\(Int(settings.originalScale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                LabeledContent("Line spacing") {
                    Slider(value: $settings.lineSpacing, in: 0.95...1.6, step: 0.01)
                    Text(String(format: "%.2f", settings.lineSpacing)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section("Colors") {
                ColorPicker("Main text", selection: color(\.textColor), supportsOpacity: false)
                ColorPicker("Original line (when both are shown)", selection: color(\.originalColor), supportsOpacity: false)
                LabeledContent("Background") {
                    Slider(value: $settings.backgroundOpacity, in: 0...1)
                    Text("\(Int(settings.backgroundOpacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section {
                Button("Reset Appearance") { settings.resetAppearance() }
            } footer: {
                Text("The subtitles on screen update as you change these. Drag them to move; drag the left or right edge to resize.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Saved subtitles

    private var saved: some View {
        Form {
            Section {
                Toggle("Save subtitles as I watch", isOn: $settings.saveSessions)
                LabeledContent("Show saved subtitles early by") {
                    Slider(value: $settings.replayLead, in: 0...0.5, step: 0.05)
                    Text(String(format: "%.2f s", settings.replayLead)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            } footer: {
                Text("When you play something again, LiveSub recognizes the audio and shows the saved subtitles with no delay. Only text, timing and an audio fingerprint are stored, never the audio.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Saved (\(sessions.count))") {
                if sessions.isEmpty {
                    Text("Nothing saved yet.").foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                            Text(detail(session)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            try? store.delete(id: session.id)
                            sessions = store.loadAll().reversed()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete these saved subtitles")
                    }
                }
            }
            Section {
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(store.directory)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { sessions = store.loadAll().reversed() }
    }

    // MARK: Data

    private struct AppChoice { let bundleID: String; let name: String; let isPlaying: Bool }
    private struct LanguageChoice { let id: String; let label: String }

    private var appChoices: [AppChoice] {
        var out = apps.map { AppChoice(bundleID: $0.bundleID, name: $0.name, isPlaying: $0.isPlayingAudio) }
        // Keep the chosen app in the list even when it is not running.
        if !settings.sourceApp.isEmpty, !out.contains(where: { $0.bundleID == settings.sourceApp }) {
            out.insert(AppChoice(bundleID: settings.sourceApp, name: AppNames.name(forBundleID: settings.sourceApp), isPlaying: false), at: 0)
        }
        return out
    }

    private var languageChoices: [LanguageChoice] {
        var out = languages.map { l in
            LanguageChoice(id: l.id, label: "\(l.isInstalled ? "✓" : "↓") \(l.displayName)\(l.engine == .dictation ? " · basic" : "")")
        }
        if !out.contains(where: { $0.id == settings.sourceLanguage }) {
            out.insert(LanguageChoice(id: settings.sourceLanguage, label: Locale.current.localizedString(forIdentifier: settings.sourceLanguage) ?? settings.sourceLanguage), at: 0)
        }
        return out
    }

    private var targetChoices: [TranslationLanguage] {
        var out = targets
        if settings.targetLanguage != "none", !out.contains(where: { $0.id == settings.targetLanguage }) {
            out.insert(TranslationLanguage(id: settings.targetLanguage), at: 0)
        }
        return out
    }

    private var otherFonts: [String] {
        let listed = Set(Self.fonts.map(\.name))
        var families = NSFontManager.shared.availableFontFamilies.filter { !listed.contains($0) && !$0.hasPrefix(".") }
        if !listed.contains(settings.fontName), !families.contains(settings.fontName) { families.insert(settings.fontName, at: 0) }
        return families
    }

    private func color(_ keyPath: ReferenceWritableKeyPath<AppSettings, NSColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: settings[keyPath: keyPath]) },
                set: { settings[keyPath: keyPath] = NSColor($0) })
    }

    private func detail(_ s: SubtitleSession) -> String {
        let language = Locale.current.localizedString(forIdentifier: s.sourceLanguage) ?? s.sourceLanguage
        let target = s.targetLanguage.map { " → " + (Locale.current.localizedString(forIdentifier: $0) ?? $0) } ?? ""
        return String(format: "%@%@ · %d:%02d · %d subtitles", language, target, Int(s.duration) / 60, Int(s.duration) % 60, s.captions.count)
    }

    private func load() async {
        apps = (try? AudioProcessCatalog.apps()) ?? []
        sessions = store.loadAll().reversed()
        // Common languages first: installed ones, then the rest alphabetically by name.
        let all = await AppleSpeechBackend.languages()
        languages = all.sorted { ($0.isInstalled ? 0 : 1, $0.displayName) < ($1.isInstalled ? 0 : 1, $1.displayName) }
        targets = await AppleTranslator.targetLanguages()
        keptLanguages = await AppleSpeechBackend.keptLanguages()
    }
}

enum AppNames {
    /// Display name of an installed app, from its bundle ID.
    @MainActor
    static func name(forBundleID id: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName { return running }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }
}

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?

    static var isOpen: Bool { window?.isVisible ?? false }

    static func close() { window?.close() }

    /// PNG of the window's contents (for automated visual checks).
    static func snapshotPNG() -> Data? {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func show(settings: AppSettings, store: SessionStore, tab: Int = 0, onClose: @escaping @MainActor () -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "LiveSub Settings"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(settings: settings, store: store, tab: tab))
        w.center()
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                window = nil
                onClose()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Shown the first time LiveSub is opened.
private struct WelcomeView: View {
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "captions.bubble.fill").font(.system(size: 34)).foregroundStyle(.tint)
                Text("Welcome to LiveSub").font(.title.weight(.semibold))
            }
            Text("LiveSub shows live subtitles, with a translation, for anything your Mac is playing. Everything runs on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                row("menubar.rectangle", "It lives in the menu bar", "Look for the captions icon at the top right: pause, pick languages, open Settings, quit.")
                row("waveform", "It needs to hear your Mac", "macOS will ask once to let LiveSub record system audio. Choose Allow. Nothing is recorded to disk or sent anywhere.")
                row("clock.arrow.circlepath", "Second viewings have no delay", "Subtitles are saved as you watch. Play the same thing again and they appear right on time.")
                row("keyboard", "Handy shortcuts", "⌃⌥C copies the current sentence, ⌃⌥E explains it in Claude, ⌃⌥G searches Google, ⌃⌥T shows the transcript.")
            }
            HStack {
                Spacer()
                Button("Open Settings…") { openSettings() }
                Button("Start Watching") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
enum WelcomeWindowController {
    private static var window: NSWindow?

    static func show(openSettings: @escaping @MainActor () -> Void) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "LiveSub"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WelcomeView(openSettings: {
            window?.close(); window = nil
            openSettings()
        }, dismiss: {
            window?.close(); window = nil
        }))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static func snapshotPNG() -> Data? {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
