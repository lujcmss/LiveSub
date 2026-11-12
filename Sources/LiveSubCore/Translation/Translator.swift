import Foundation
import Translation

/// Text translation between two fixed languages. Implementations: `AppleTranslator`.
public protocol Translator: Sendable {
    var name: String { get }
    func translate(_ text: String) async throws -> String
}

/// A language LiveSub can translate into (or from).
public struct TranslationLanguage: Sendable, Hashable, Identifiable {
    /// Minimal identifier: "en", "ja", "zh-Hans", "zh-Hant", "pt-BR"…
    public let id: String
    public var language: Locale.Language { Locale.Language(identifier: id) }
    public var displayName: String { Locale.current.localizedString(forIdentifier: id) ?? id }

    public init(id: String) { self.id = id }

    /// Translation works on languages, not regional speech locales: "ja-JP" → "ja",
    /// "zh-CN" → "zh-Hans", "zh-TW"/"zh-HK"/"yue-CN" → Chinese with the right script.
    public init(speechLocale identifier: String) {
        let lang = Locale.Language(identifier: identifier)
        let code = lang.languageCode?.identifier ?? identifier
        switch code {
        case "zh", "yue":
            let script = lang.script?.identifier ?? Locale.Language(identifier: lang.maximalIdentifier).script?.identifier
            let region = lang.region?.identifier
            let traditional = script == "Hant" || region == "TW" || region == "HK" || region == "MO"
            id = traditional && code == "zh" ? "zh-Hant" : (code == "yue" ? "zh-Hant" : "zh-Hans")
        default:
            id = code
        }
    }

    public func isSameLanguage(as other: TranslationLanguage) -> Bool { id == other.id }
}

/// Apple's on-device Translation framework (macOS 26.4 low-latency strategy).
///
/// Models are downloaded once by macOS (the app must ask through the system's own dialog;
/// see `TranslationModelInstaller` in the app target). After that everything is offline.
public actor AppleTranslator: Translator {
    public enum Status: Sendable { case installed, needsDownload, unsupported }

    public nonisolated let source: TranslationLanguage
    public nonisolated let target: TranslationLanguage
    public nonisolated var name: String { "Apple Translation \(source.id)→\(target.id)" }

    private nonisolated(unsafe) let session: TranslationSession
    /// Requests run one at a time, in order.
    private var tail: Task<Void, Never>?

    public init(source: TranslationLanguage, target: TranslationLanguage) {
        self.source = source
        self.target = target
        session = TranslationSession(installedSource: source.language, target: target.language,
                                     preferredStrategy: .lowLatency)
    }

    public static func status(from source: TranslationLanguage, to target: TranslationLanguage) async -> Status {
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        switch await availability.status(from: source.language, to: target.language) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Languages offered as translation targets, one entry per language/script
    /// (so Simplified and Traditional Chinese are separate), preferred languages first.
    public static func targetLanguages() async -> [TranslationLanguage] {
        let supported = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        var out: [TranslationLanguage] = []
        for l in supported {
            let t = TranslationLanguage(speechLocale: l.maximalIdentifier)
            if seen.insert(t.id).inserted { out.append(t) }
        }
        let preferred = Locale.preferredLanguages.map { TranslationLanguage(speechLocale: $0).id }
        func rank(_ t: TranslationLanguage) -> Int { preferred.firstIndex(of: t.id) ?? Int.max }
        return out.sorted { (rank($0), $0.displayName) < (rank($1), $1.displayName) }
    }

    /// The Mac's first preferred language that differs from `source`.
    public static func defaultTarget(for source: TranslationLanguage) -> TranslationLanguage {
        for id in Locale.preferredLanguages {
            let t = TranslationLanguage(speechLocale: id)
            if !t.isSameLanguage(as: source) { return t }
        }
        return TranslationLanguage(id: source.id == "en" ? "zh-Hans" : "en")
    }

    public func translate(_ text: String) async throws -> String {
        let previous = tail
        let session = self.session
        let work = Task<String, Error> {
            await previous?.value
            return try await session.translate(text).targetText
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
}
