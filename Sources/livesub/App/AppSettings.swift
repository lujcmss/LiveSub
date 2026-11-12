import AppKit
import Combine
import LiveSubCore

/// Everything the user can choose, remembered between launches (UserDefaults).
@MainActor
final class AppSettings: ObservableObject {
    /// false for timed command-line test runs: changes then last only for that run.
    let persist: Bool
    private let defaults = UserDefaults.standard

    // Listening
    /// Bundle ID of the app to listen to; empty = everything the Mac plays.
    @Published var sourceApp: String { didSet { save("sourceApp", sourceApp) } }
    /// Spoken language as a speech locale ("ja-JP").
    @Published var sourceLanguage: String { didSet { save("sourceLanguage", sourceLanguage) } }
    /// Translation target ("en", "zh-Hans", …) or "none".
    @Published var targetLanguage: String { didSet { save("targetLanguage", targetLanguage) } }

    /// Show a provisional translation while a sentence is still being spoken (off: wait for
    /// the whole sentence).
    @Published var translateWhileSpeaking: Bool { didSet { save("translateWhileSpeaking", translateWhileSpeaking) } }

    /// End sentences at pauses in speech: translations come about 0.3 s sooner, recognition is
    /// slightly less accurate.
    @Published var fasterSentences: Bool { didSet { save("fasterSentences", fasterSentences) } }

    // Appearance
    @Published var displayMode: SubtitleStyle.DisplayMode { didSet { save("displayMode", displayMode.rawValue) } }
    @Published var fontName: String { didSet { save("fontName", fontName) } }
    @Published var fontSize: Double { didSet { save("fontSize", fontSize) } }
    @Published var textColor: NSColor { didSet { save("textColor", textColor.hexString) } }
    @Published var originalColor: NSColor { didSet { save("originalColor", originalColor.hexString) } }
    @Published var backgroundOpacity: Double { didSet { save("backgroundOpacity", backgroundOpacity) } }
    @Published var lineSpacing: Double { didSet { save("lineSpacing", lineSpacing) } }
    @Published var originalScale: Double { didSet { save("originalScale", originalScale) } }
    @Published var maxLines: Int { didSet { save("maxLines", maxLines) } }

    // Behaviour
    @Published var clickThrough: Bool { didSet { save("clickThrough", clickThrough) } }
    @Published var idleSeconds: Double { didSet { save("idleSeconds", idleSeconds) } }
    @Published var saveSessions: Bool { didSet { save("saveSessions", saveSessions) } }
    @Published var replayLead: Double { didSet { save("replayLead", replayLead) } }

    init(persist: Bool) {
        self.persist = persist
        let d = UserDefaults.standard
        func string(_ key: String, _ fallback: String) -> String { d.string(forKey: "LiveSub.\(key)") ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: "LiveSub.\(key)") as? Double ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: "LiveSub.\(key)") as? Bool ?? fallback }
        let style = SubtitleStyle()

        sourceApp = string("sourceApp", "")
        let language = string("sourceLanguage", "ja-JP")
        sourceLanguage = language
        targetLanguage = string("targetLanguage", AppleTranslator.defaultTarget(for: TranslationLanguage(speechLocale: language)).id)
        translateWhileSpeaking = bool("translateWhileSpeaking", false)
        fasterSentences = bool("fasterSentences", false)
        displayMode = SubtitleStyle.DisplayMode(rawValue: string("displayMode", "")) ?? .both
        fontName = string("fontName", style.fontName)
        fontSize = double("fontSize", Double(style.fontSize))
        textColor = NSColor(hexString: string("textColor", "")) ?? style.textColor
        originalColor = NSColor(hexString: string("originalColor", "")) ?? style.originalColor
        backgroundOpacity = double("backgroundOpacity", Double(style.backgroundOpacity))
        lineSpacing = double("lineSpacing", Double(style.lineSpacing))
        originalScale = double("originalScale", Double(style.originalScale))
        maxLines = d.object(forKey: "LiveSub.maxLines") as? Int ?? style.maxLines
        clickThrough = bool("clickThrough", false)
        idleSeconds = double("idleSeconds", 5)
        saveSessions = bool("saveSessions", true)
        replayLead = double("replayLead", 0.1)
    }

    private func save(_ key: String, _ value: Any) {
        guard persist else { return }
        defaults.set(value, forKey: "LiveSub.\(key)")
    }

    /// The translation target, or nil when translation is off.
    var target: String? { targetLanguage == "none" ? nil : targetLanguage }

    /// The look described by these settings (languages are filled in when a run starts).
    func style(basedOn current: SubtitleStyle) -> SubtitleStyle {
        var s = current
        s.mode = displayMode
        s.fontName = fontName
        s.fontSize = CGFloat(fontSize)
        s.textColor = textColor
        s.originalColor = originalColor
        s.backgroundOpacity = CGFloat(backgroundOpacity)
        s.lineSpacing = CGFloat(lineSpacing)
        s.originalScale = CGFloat(originalScale)
        s.maxLines = maxLines
        return s
    }

    /// Put everything about the look back to how LiveSub ships.
    func resetAppearance() {
        let style = SubtitleStyle()
        displayMode = .both
        fontName = style.fontName
        fontSize = Double(style.fontSize)
        textColor = style.textColor
        originalColor = style.originalColor
        backgroundOpacity = Double(style.backgroundOpacity)
        lineSpacing = Double(style.lineSpacing)
        originalScale = Double(style.originalScale)
        maxLines = style.maxLines
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB.
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
