import AVFAudio
import CoreMedia
import Foundation
import Speech

public enum ASRError: Error, CustomStringConvertible {
    case unsupportedLanguage(String)
    case notPrepared
    case noAudioFormat

    public var description: String {
        switch self {
        case let .unsupportedLanguage(id): "No on-device speech model supports \(id). Run `livesub languages` to see the list."
        case .notPrepared: "prepare() must be called before start()"
        case .noAudioFormat: "The recognizer did not report a usable audio format"
        }
    }
}

/// Apple's on-device recognizers, driven through SpeechAnalyzer (macOS 26).
///
/// - `SpeechTranscriber`: the new long-form model. Best accuracy and speed; ~10 languages.
/// - `DictationTranscriber`: the older dictation model. Covers ~25 more languages, so it is the
///   automatic fallback when SpeechTranscriber does not support the chosen language.
public final class AppleSpeechBackend: ASRBackend, @unchecked Sendable {
    public enum Engine: String, Sendable { case speechTranscriber, dictation }

    public struct Language: Sendable, Hashable {
        public let locale: Locale
        public let engine: Engine
        public let isInstalled: Bool
        public var id: String { locale.identifier(.bcp47) }
        public var displayName: String { Locale.current.localizedString(forIdentifier: locale.identifier) ?? id }
    }

    /// Every language that can be transcribed on this Mac, preferring SpeechTranscriber.
    public static func languages() async -> [Language] {
        let st = await SpeechTranscriber.supportedLocales
        let stInstalled = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        let dt = await DictationTranscriber.supportedLocales
        let dtInstalled = Set(await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        var seen = Set<String>()
        var out: [Language] = []
        for l in st {
            let id = l.identifier(.bcp47)
            if seen.insert(id).inserted {
                out.append(Language(locale: l, engine: .speechTranscriber, isInstalled: stInstalled.contains(id)))
            }
        }
        for l in dt {
            let id = l.identifier(.bcp47)
            if seen.insert(id).inserted {
                out.append(Language(locale: l, engine: .dictation, isInstalled: dtInstalled.contains(id)))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Resolve a user-supplied identifier ("en", "en-US", "zh-Hans", "ja") to a supported language.
    public static func resolve(_ identifier: String, forcing engine: Engine? = nil) async -> Language? {
        let requested = Locale(identifier: identifier)
        if engine != .dictation, let l = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == l.identifier(.bcp47) }
            return Language(locale: l, engine: .speechTranscriber, isInstalled: installed)
        }
        if engine != .speechTranscriber, let l = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            let installed = await DictationTranscriber.installedLocales.contains { $0.identifier(.bcp47) == l.identifier(.bcp47) }
            return Language(locale: l, engine: .dictation, isInstalled: installed)
        }
        return nil
    }

    // MARK: Model reservations

    /// macOS lets an app keep only a few speech languages reserved (5 on macOS 26). Reserved
    /// languages stay installed for offline use; others may be purged by the system.
    public static var maximumKeptLanguages: Int { AssetInventory.maximumReservedLocales }

    public static func keptLanguages() async -> [String] {
        await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
    }

    @discardableResult
    public static func stopKeeping(_ identifier: String) async -> Bool {
        for l in await AssetInventory.reservedLocales where l.identifier(.bcp47) == identifier {
            return await AssetInventory.release(reservedLocale: l)
        }
        return false
    }

    private static let usageKey = "LiveSub.speechLanguageUsage"

    /// If the reservation limit is reached, release the language used least recently so the
    /// requested one can be installed. Also records `locale` as the most recently used.
    static func makeRoomForReservation(of locale: Locale) async {
        let id = locale.identifier(.bcp47)
        var usage = UserDefaults.standard.stringArray(forKey: usageKey) ?? []
        usage.removeAll { $0 == id }
        usage.insert(id, at: 0)
        UserDefaults.standard.set(Array(usage.prefix(20)), forKey: usageKey)

        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier(.bcp47) == id }),
              reserved.count >= AssetInventory.maximumReservedLocales else { return }
        // Least recently used first; languages we have no record of using go before all others.
        let victim = reserved.max { a, b in
            (usage.firstIndex(of: a.identifier(.bcp47)) ?? Int.max) < (usage.firstIndex(of: b.identifier(.bcp47)) ?? Int.max)
        }
        if let victim {
            Log.info("speech language limit (\(AssetInventory.maximumReservedLocales)) reached: no longer keeping \(victim.identifier(.bcp47)) to make room for \(id)")
            await AssetInventory.release(reservedLocale: victim)
        }
    }

    public let language: Language
    public var name: String { "\(language.engine == .speechTranscriber ? "SpeechTranscriber" : "DictationTranscriber") \(language.id)" }

    private var analyzer: SpeechAnalyzer?
    private var speechTranscriber: SpeechTranscriber?
    private var dictationTranscriber: DictationTranscriber?
    private var format: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    public init(language: Language) {
        self.language = language
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> AVAudioFormat {
        let module: any SpeechModule
        switch language.engine {
        case .speechTranscriber:
            // volatileResults: fast guesses we can show immediately.
            // fastResults: bias the model toward responsiveness over a little accuracy.
            // audioTimeRange: per-word timing, used for latency measurement and line timing.
            let t = SpeechTranscriber(locale: language.locale, transcriptionOptions: [],
                                      reportingOptions: [.volatileResults, .fastResults],
                                      attributeOptions: [.audioTimeRange])
            speechTranscriber = t
            module = t
        case .dictation:
            let t = DictationTranscriber(locale: language.locale, contentHints: [],
                                         transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults, .frequentFinalization],
                                         attributeOptions: [.audioTimeRange])
            dictationTranscriber = t
            module = t
        }

        let t0 = HostClock.now()
        func elapsed() -> String { String(format: "%.2f s", HostClock.seconds(HostClock.now() - t0)) }
        let status = await AssetInventory.status(forModules: [module])
        Log.debug("asset status \(status) at \(elapsed())")
        if status == .unsupported {
            throw ASRError.unsupportedLanguage(language.id)
        }
        await Self.makeRoomForReservation(of: language.locale)
        // One-time model download from Apple, if this language is not installed yet.
        if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                progress(p.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            Log.debug("assets installed at \(elapsed())")
        }

        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw ASRError.noAudioFormat
        }
        format = fmt
        // Keep the model loaded for the life of the process so restarts are instant.
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: fmt)
        Log.debug("model loaded at \(elapsed())")
        self.analyzer = analyzer
        return fmt
    }

    public func start() async throws -> AsyncThrowingStream<ASRResult, Error> {
        guard let analyzer else { throw ASRError.notPrepared }
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        input = inputContinuation
        let (stream, output) = AsyncThrowingStream<ASRResult, Error>.makeStream()

        if let t = speechTranscriber {
            resultsTask = Task {
                do {
                    for try await r in t.results {
                        output.yield(Self.convert(text: r.text, range: r.range, isFinal: r.isFinal))
                    }
                    output.finish()
                } catch { output.finish(throwing: error) }
            }
        } else if let t = dictationTranscriber {
            resultsTask = Task {
                do {
                    for try await r in t.results {
                        output.yield(Self.convert(text: r.text, range: r.range, isFinal: r.isFinal))
                    }
                    output.finish()
                } catch { output.finish(throwing: error) }
            }
        }
        try await analyzer.start(inputSequence: inputSequence)
        return stream
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        input?.yield(AnalyzerInput(buffer: buffer))
    }

    public func finish() async {
        let t0 = HostClock.now()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        Log.debug("analyzer finished after \(String(format: "%.2f s", HostClock.seconds(HostClock.now() - t0)))")
        await resultsTask?.value
        resultsTask = nil
        Log.debug("results drained after \(String(format: "%.2f s", HostClock.seconds(HostClock.now() - t0)))")
    }

    private static func convert(text: AttributedString, range: CMTimeRange, isFinal: Bool) -> ASRResult {
        let received = HostClock.now()
        var newest: Double?
        var runs: [ASRResult.TimedRun] = []
        for run in text.runs {
            if let r = run.audioTimeRange, r.end.isNumeric {
                newest = max(newest ?? 0, r.end.seconds)
                runs.append(.init(text: String(text[run.range].characters), end: r.end.seconds))
            }
        }
        return ASRResult(text: String(text.characters), isFinal: isFinal,
                         audioStart: range.start.seconds, audioEnd: range.end.seconds,
                         newestWordEnd: newest, timedRuns: runs, receivedHostTime: received)
    }
}
