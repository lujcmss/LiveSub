import AppKit
import LiveSubCore
import SwiftUI
import Translation

/// Gets macOS to download a translation model. Apple only allows this through its own
/// confirmation dialog, which must be presented from a SwiftUI view, so this shows a small
/// explanatory window and triggers that dialog from it.
@MainActor
enum TranslationModelInstaller {
    private static var window: NSWindow?

    /// Returns true once the pair is installed (immediately if it already is).
    static func ensureInstalled(source: TranslationLanguage, target: TranslationLanguage) async -> Bool {
        switch await AppleTranslator.status(from: source, to: target) {
        case .installed: return true
        case .unsupported: return false
        case .needsDownload: break
        }
        return await withCheckedContinuation { continuation in
            let completion = Completion { ok in
                window?.close()
                window = nil
                continuation.resume(returning: ok)
            }
            let view = DownloadView(source: source, target: target, onFinish: { completion.finish($0) })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "LiveSub"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.center()
            w.level = .floating
            window = w
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { completion.finish(false) }
            }
        }
    }
}

/// Resumes the waiting caller exactly once.
@MainActor
private final class Completion: Sendable {
    private var done = false
    private let handler: @MainActor (Bool) -> Void
    init(_ handler: @escaping @MainActor (Bool) -> Void) { self.handler = handler }
    func finish(_ ok: Bool) {
        guard !done else { return }
        done = true
        handler(ok)
    }
}

private struct DownloadView: View {
    let source: TranslationLanguage
    let target: TranslationLanguage
    let onFinish: (Bool) -> Void
    @State private var configuration: TranslationSession.Configuration?
    @State private var message = "Waiting for the macOS download dialog…"
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One-time download")
                .font(.title2.weight(.semibold))
            Text("To translate \(source.displayName) into \(target.displayName), macOS needs to download Apple's translation model. After that, translation works offline and nothing leaves your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !failed { ProgressView().controlSize(.small) }
                Text(message).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if failed {
                    Button("Try Again") { start() }
                }
                Button("Not Now") { onFinish(false) }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { start() }
        .translationTask(configuration) { session in
            do {
                // Shows Apple's confirmation and downloads the model(s).
                nonisolated(unsafe) let session = session
                try await session.prepareTranslation()
                if await AppleTranslator.status(from: source, to: target) == .installed {
                    onFinish(true)
                } else {
                    failed = true
                    message = "The model isn't installed yet. If the download is still running, try again in a moment."
                }
            } catch {
                failed = true
                message = "The download didn't start: \(error.localizedDescription)"
            }
        }
    }

    private func start() {
        failed = false
        message = "Waiting for the macOS download dialog…"
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: source.language, target: target.language,
                                                             preferredStrategy: .lowLatency)
        } else {
            configuration?.invalidate()
        }
    }
}

/// `livesub translation-setup`: ask for each missing pair in turn, then quit.
@MainActor
func runTranslationSetup(sources: [TranslationLanguage], targets: [TranslationLanguage]) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        for source in sources {
            for target in targets where !target.isSameLanguage(as: source) {
                let before = await AppleTranslator.status(from: source, to: target)
                if before == .unsupported {
                    print("\(source.id)→\(target.id): not supported by Apple Translation")
                    continue
                }
                let ok = await TranslationModelInstaller.ensureInstalled(source: source, target: target)
                print("\(source.id)→\(target.id): \(ok ? "installed" : "not installed")\(before == .installed ? " (already)" : "")")
            }
        }
        exit(0)
    }
    app.run()
    exit(0)
}
