import Foundation

/// Turns recognizer output into the rows the overlay shows: each sentence with its translation.
///
/// Translation does not wait for the recognizer to finalize (in continuous speech that can take
/// many seconds). Instead:
/// - a sentence is translated the moment it is *complete* (ends in sentence punctuation), even
///   while the recognizer may still revise it;
/// - the sentence still being spoken gets an *eager* provisional translation, refreshed as fast
///   as the translator can keep up (one request in flight, latest text wins).
/// Translations are cached by source text, so a revised sentence is simply translated again.
/// On-device translation takes ~25-50 ms per sentence, so the occasional redo is cheap.
@MainActor
public final class CaptionEngine {
    public struct Row: Sendable, Equatable {
        public var source: String
        public var translation: String?
        /// The translation is for an unfinished sentence and will be replaced.
        public var isProvisional: Bool
        /// The sentence has ended (it has sentence-final punctuation or was finalized).
        public var isComplete: Bool
    }

    public enum Stage {
        public static let translate = "5 translation request time"
        public static let sentenceToTranslation = "6 sentence complete on screen → translation shown"
        public static let eager = "6b in-progress text → provisional translation shown"
    }

    /// Called on the main actor whenever `rows` may have changed because a translation arrived.
    public var onChange: (() -> Void)?
    public private(set) var timeline = CaptionTimeline()
    public let translator: Translator?
    public var eagerTranslation: Bool
    /// Shortest unfinished text worth translating eagerly (characters).
    public var eagerMinimumLength = 2

    private let stats: LatencyStats
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var inFlight = Set<String>()
    private var firstSeenComplete: [String: UInt64] = [:]
    private var eagerSource: String?
    private var eagerText: String?
    private var eagerInFlight = false

    public init(translator: Translator?, stats: LatencyStats = LatencyStats(), eagerTranslation: Bool = true) {
        self.translator = translator
        self.stats = stats
        self.eagerTranslation = eagerTranslation
    }

    // MARK: Input

    public func handlePartial(_ text: String) {
        timeline.setVolatile(text)
        schedule()
    }

    /// The speaker has paused mid-"sentence" (the recognizer has not closed it and will not
    /// until it hears more). Treat what is there as a finished sentence: translate and show it.
    /// If the sentence does continue, its text changes and it is handled afresh.
    public func handleIdle() {
        guard let last = timeline.displayUnits.last, !Self.isComplete(last) else { return }
        heldComplete = last
        if firstSeenComplete[last] == nil { firstSeenComplete[last] = HostClock.now() }
        requestTranslation(last)
    }

    /// Text of the unfinished sentence that a pause promoted to "finished".
    private var heldComplete: String?

    /// - Returns: the sentences this completed, with their timing when `runs` are given.
    @discardableResult
    public func handleFinal(_ text: String, runs: [ASRResult.TimedRun] = []) -> [CaptionTimeline.Caption] {
        timeline.setVolatile("")
        let done = timeline.finalize(text, runs: runs)
        for caption in done { requestTranslation(caption.source) }
        schedule()
        return done
    }

    /// Close the unfinished sentence (end of the session); returns it if there was one.
    @discardableResult
    public func flush() -> CaptionTimeline.Caption? {
        let tail = timeline.flush()
        if let tail { requestTranslation(tail.source) }
        return tail
    }

    /// Hide everything (speech paused); history is kept in `timeline`.
    public func clearScreen() {
        timeline.clearScreen()
        eagerSource = nil
        eagerText = nil
        heldComplete = nil
    }

    // MARK: Output

    public var rows: [Row] {
        let units = timeline.displayUnits
        return units.enumerated().map { index, source in
            let complete = Self.isComplete(source) || index < timeline.visibleCaptions.count || source == heldComplete
            if let t = cache[source] {
                return Row(source: source, translation: t, isProvisional: false, isComplete: complete)
            }
            // The sentence went on after a pause: keep the translation of its first part
            // (marked provisional) until the whole of it is translated.
            if index == units.count - 1, let held = heldComplete, source.hasPrefix(held), let t = cache[held] {
                return Row(source: source, translation: t, isProvisional: true, isComplete: false)
            }
            // Unfinished last sentence: show the eager translation if it is for a prefix of it.
            if eagerTranslation, index == units.count - 1, let eagerSource, let eagerText, source.hasPrefix(eagerSource) || eagerSource.hasPrefix(source) {
                return Row(source: source, translation: eagerText, isProvisional: true, isComplete: complete)
            }
            return Row(source: source, translation: nil, isProvisional: false, isComplete: complete)
        }
    }

    /// How many trailing characters of the last row's source are still being revised.
    public var tentativeCount: Int { timeline.tentative.count }

    /// The newest sentence and its translation, for copying.
    public var currentSentence: (source: String, translation: String?)? {
        guard let last = rows.last ?? timeline.captions.last.map({
            Row(source: $0.source, translation: cache[$0.source], isProvisional: false, isComplete: true)
        }) else { return nil }
        return (last.source, last.translation)
    }

    public func translation(for source: String) -> String? { cache[source] }

    // MARK: Scheduling

    static func isComplete(_ sentence: String) -> Bool {
        let (sentences, rest) = SentenceSegmenter.split(sentence)
        return !sentences.isEmpty && rest.isEmpty
    }

    private func schedule() {
        guard translator != nil else { return }
        let units = timeline.displayUnits
        let now = HostClock.now()
        for (index, unit) in units.enumerated() {
            let isLast = index == units.count - 1
            if Self.isComplete(unit) {
                if firstSeenComplete[unit] == nil { firstSeenComplete[unit] = now }
                requestTranslation(unit)
            } else if isLast {
                requestEager(unit)
            }
        }
        if firstSeenComplete.count > 400 { firstSeenComplete.removeAll() }
    }

    private func requestTranslation(_ source: String) {
        guard let translator, cache[source] == nil, !inFlight.contains(source) else { return }
        inFlight.insert(source)
        let seen = firstSeenComplete[source] ?? HostClock.now()
        firstSeenComplete[source] = seen
        let started = HostClock.now()
        Task {
            let result = (try? await translator.translate(source))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let done = HostClock.now()
            inFlight.remove(source)
            guard let result, !result.isEmpty else { return }
            stats.record(Stage.translate, ms: HostClock.ms(from: started, to: done))
            stats.record(Stage.sentenceToTranslation, ms: HostClock.ms(from: seen, to: done))
            store(result, for: source)
            onChange?()
        }
    }

    private func requestEager(_ source: String) {
        guard eagerTranslation, let translator, !eagerInFlight, source != eagerSource,
              source.count >= eagerMinimumLength, cache[source] == nil else { return }
        eagerInFlight = true
        let started = HostClock.now()
        Task {
            let result = (try? await translator.translate(source))?.trimmingCharacters(in: .whitespacesAndNewlines)
            eagerInFlight = false
            if let result, !result.isEmpty {
                stats.record(Stage.eager, ms: HostClock.ms(from: started, to: HostClock.now()))
                eagerSource = source
                eagerText = result
                onChange?()
            }
            // The text has usually grown while we were translating: go again with the latest.
            if let last = timeline.displayUnits.last, !Self.isComplete(last), last != source { requestEager(last) }
        }
    }

    /// When a sentence was first seen complete, and when its translation arrived (host times).
    public func timing(for source: String) -> (complete: UInt64?, translated: UInt64?) {
        (firstSeenComplete[source], translatedAt[source])
    }

    private var translatedAt: [String: UInt64] = [:]

    private func store(_ translation: String, for source: String) {
        translatedAt[source] = HostClock.now()
        if translatedAt.count > 600 { translatedAt.removeAll() }
        if cache[source] == nil { cacheOrder.append(source) }
        cache[source] = translation
        if cacheOrder.count > 300 {
            for old in cacheOrder.prefix(100) { cache[old] = nil }
            cacheOrder.removeFirst(100)
        }
    }
}
