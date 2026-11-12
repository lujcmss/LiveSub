import Foundation
import Testing
@testable import LiveSubCore

/// Translator stand-in: wraps the text and records what it was asked for.
private actor FakeTranslator: Translator {
    nonisolated let name = "fake"
    private(set) var requests: [String] = []
    func translate(_ text: String) async throws -> String {
        requests.append(text)
        return "T(\(text))"
    }
}

/// Let pending translation tasks run.
@MainActor private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

@MainActor @Suite struct CaptionEngineTests {
    @Test func finalizedSentencesGetTranslations() async {
        let fake = FakeTranslator()
        let engine = CaptionEngine(translator: fake, eagerTranslation: false)
        engine.handleFinal("Hello world. How are you?")
        await settle()
        #expect(engine.rows.map(\.source) == ["Hello world.", "How are you?"])
        #expect(engine.rows.map(\.translation) == ["T(Hello world.)", "T(How are you?)"])
        #expect(engine.rows.allSatisfy { $0.isComplete && !$0.isProvisional })
    }

    @Test func completeSentenceInsidePartialIsTranslatedBeforeItIsFinal() async {
        let fake = FakeTranslator()
        let engine = CaptionEngine(translator: fake, eagerTranslation: false)
        engine.handlePartial("今日は晴れ")
        await settle()
        #expect(await fake.requests.isEmpty)
        // Complete as soon as the sentence mark appears, long before the recognizer finalizes.
        engine.handlePartial("今日は晴れです。散歩に")
        await settle()
        #expect(await fake.requests == ["今日は晴れです。"])
        #expect(engine.rows.first?.translation == "T(今日は晴れです。)")
        #expect(engine.rows.last?.translation == nil)
        // Finalizing the same sentence later does not translate it again.
        engine.handleFinal("今日は晴れです。散歩に行きましょう。")
        await settle()
        #expect(await fake.requests == ["今日は晴れです。", "散歩に行きましょう。"])
    }

    @Test func revisedSentenceIsTranslatedAgain() async {
        let fake = FakeTranslator()
        let engine = CaptionEngine(translator: fake, eagerTranslation: false)
        engine.handlePartial("I sea the ship. And")
        await settle()
        engine.handlePartial("I see the ship. And then")
        await settle()
        #expect(await fake.requests == ["I sea the ship.", "I see the ship."])
        #expect(engine.rows.first == .init(source: "I see the ship.", translation: "T(I see the ship.)", isProvisional: false, isComplete: true))
    }

    @Test func unfinishedSentenceGetsProvisionalTranslation() async {
        let fake = FakeTranslator()
        let engine = CaptionEngine(translator: fake, eagerTranslation: true)
        engine.handlePartial("私は駅まで")
        await settle()
        #expect(engine.rows.last?.translation == "T(私は駅まで)")
        #expect(engine.rows.last?.isProvisional == true)
        engine.handlePartial("私は駅まで歩いて行きました。")
        await settle()
        engine.handlePartial("私は駅まで歩いて行きました。そして")
        await settle()
        let first = engine.rows.first
        #expect(first?.translation == "T(私は駅まで歩いて行きました。)")
        #expect(first?.isProvisional == false)
    }

    @Test func noTranslatorMeansSourceOnlyRows() async {
        let engine = CaptionEngine(translator: nil)
        engine.handleFinal("Hello.")
        engine.handlePartial("More")
        await settle()
        #expect(engine.rows.map(\.translation) == [nil, nil])
        #expect(engine.currentSentence?.source == "More")
    }

    @Test func clearScreenEmptiesRowsButKeepsCurrentSentenceForCopy() async {
        let fake = FakeTranslator()
        let engine = CaptionEngine(translator: fake)
        engine.handleFinal("Hello.")
        await settle()
        engine.clearScreen()
        #expect(engine.rows.isEmpty)
        #expect(engine.currentSentence?.source == "Hello.")
        #expect(engine.currentSentence?.translation == "T(Hello.)")
    }

    @Test func speechLocalesMapToTranslationLanguages() {
        #expect(TranslationLanguage(speechLocale: "ja-JP").id == "ja")
        #expect(TranslationLanguage(speechLocale: "ko-KR").id == "ko")
        #expect(TranslationLanguage(speechLocale: "zh-CN").id == "zh-Hans")
        #expect(TranslationLanguage(speechLocale: "zh-TW").id == "zh-Hant")
        #expect(TranslationLanguage(speechLocale: "zh-Hant").id == "zh-Hant")
        #expect(TranslationLanguage(speechLocale: "zh-Hans-US").id == "zh-Hans")
        #expect(TranslationLanguage(speechLocale: "en-US").id == "en")
    }
}
