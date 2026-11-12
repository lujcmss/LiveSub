import Foundation
import Testing
@testable import LiveSubCore

private func vol(_ t: String, _ a: Double, _ b: Double) -> ASRResult { ASRResult(text: t, isFinal: false, audioStart: a, audioEnd: b) }
private func fin(_ t: String, _ a: Double, _ b: Double) -> ASRResult { ASRResult(text: t, isFinal: true, audioStart: a, audioEnd: b) }

@Suite struct TranscriptAssemblerTests {
    @Test func volatileGuessesReplaceEachOther() {
        var a = TranscriptAssembler()
        #expect(a.apply(vol("Hel", 0, 0.3)) == .volatileUpdated)
        #expect(a.apply(vol("Hello wor", 0, 0.8)) == .volatileUpdated)
        #expect(a.volatileText == "Hello wor")
        #expect(a.finalized.isEmpty)
    }

    @Test func finalResultReplacesOverlappingVolatile() {
        var a = TranscriptAssembler()
        a.apply(vol("Hello word", 0, 1))
        let change = a.apply(fin("Hello world.", 0, 1))
        #expect(change == .finalized(.init(text: "Hello world.", start: 0, end: 1)))
        #expect(a.volatileText == "")
        #expect(a.finalizedText == "Hello world.")
    }

    @Test func volatileForLaterAudioSurvivesFinal() {
        var a = TranscriptAssembler()
        a.apply(vol("How are", 1, 1.6))
        a.apply(fin("Hello world.", 0, 1))
        #expect(a.volatileText == "How are")
    }

    @Test func staleVolatileAfterFinalIsIgnored() {
        var a = TranscriptAssembler()
        a.apply(fin("Hello world.", 0, 1))
        #expect(a.apply(vol("Hello word", 0, 1)) == .none)
        #expect(a.volatileText == "")
    }

    @Test func duplicateAndRevisedFinals() {
        var a = TranscriptAssembler()
        a.apply(fin("Hello world.", 0, 1))
        #expect(a.apply(fin("Hello world.", 0, 1)) == .none)
        #expect(a.apply(fin("Hello, world.", 0, 1)) == .finalized(.init(text: "Hello, world.", start: 0, end: 1)))
        #expect(a.finalized.count == 1)
    }

    @Test func finalsAppendInOrderAndJoin() {
        var a = TranscriptAssembler()
        a.apply(fin("Hello world.", 0, 1))
        a.apply(fin(" How are you?", 1, 2))
        #expect(a.apply(fin("old", 0.2, 0.9)) == .none)
        #expect(a.finalizedText == "Hello world. How are you?")
    }

    @Test func emptyResultsAreQuiet() {
        var a = TranscriptAssembler()
        #expect(a.apply(vol("  ", 0, 0.2)) == .none)
        #expect(a.apply(fin("", 0, 0.5)) == .none)
        a.apply(vol("um", 0.5, 0.7))
        #expect(a.apply(vol("", 0.5, 0.9)) == .volatileUpdated)
        #expect(a.volatile == nil)
    }

    @Test func cjkJoinsWithoutSpaces() {
        #expect(TranscriptAssembler.join(["你好", "世界"]) == "你好世界")
        #expect(TranscriptAssembler.join(["Hello", "world"]) == "Hello world")
        #expect(TranscriptAssembler.join(["こんにちは。", "元気"]) == "こんにちは。元気")
    }

    @Test func trimDropsOldSegments() {
        var a = TranscriptAssembler()
        for i in 0..<10 { a.apply(fin("s\(i).", Double(i), Double(i + 1))) }
        a.trim(keepingLast: 3)
        #expect(a.finalized.first?.text == "s6.")
    }
}

@Suite struct SentenceSegmenterTests {
    @Test func splitsOnTerminatorsFollowedBySpace() {
        let r = SentenceSegmenter.split("Hello world. How are you? Fine")
        #expect(r.sentences == ["Hello world.", "How are you?"])
        #expect(r.remainder == "Fine")
    }

    @Test func keepsDecimalsAbbreviationsAndInitials() {
        #expect(SentenceSegmenter.split("It costs 3.5 dollars. Ok").sentences == ["It costs 3.5 dollars."])
        #expect(SentenceSegmenter.split("Dr. Smith met Mr. Jones. Then").sentences == ["Dr. Smith met Mr. Jones."])
        #expect(SentenceSegmenter.split("J. K. Rowling wrote it. Yes").sentences == ["J. K. Rowling wrote it."])
        #expect(SentenceSegmenter.split("Visit example.com today. Bye").sentences == ["Visit example.com today."])
    }

    @Test func groupsRepeatedPunctuationAndQuotes() {
        let r = SentenceSegmenter.split("Really?! \"No way.\" Wait... what")
        #expect(r.sentences == ["Really?!", "\"No way.\"", "Wait..."])
        #expect(r.remainder == "what")
    }

    @Test func splitsCJKWithoutSpaces() {
        let r = SentenceSegmenter.split("你好。今天天气很好！你呢")
        #expect(r.sentences == ["你好。", "今天天气很好！"])
        #expect(r.remainder == "你呢")
        #expect(SentenceSegmenter.split("こんにちは。元気ですか？").sentences == ["こんにちは。", "元気ですか？"])
    }

    @Test func streamsAcrossAppends() {
        var s = SentenceSegmenter()
        #expect(s.append("Hello") == [])
        #expect(s.append("world. How") == ["Hello world."])
        #expect(s.pending == "How")
        #expect(s.append("are you?") == ["How are you?"])
        #expect(s.flush() == nil)
    }

    @Test func trailingAbbreviationWaitsForMoreText() {
        var s = SentenceSegmenter()
        #expect(s.append("I spoke to Dr.") == [])
        #expect(s.append("Smith today.") == ["I spoke to Dr. Smith today."])
    }

    @Test func flushEmitsUnfinishedTail() {
        var s = SentenceSegmenter()
        _ = s.append("and then we")
        #expect(s.flush() == "and then we")
        #expect(s.pending == "")
    }

    @Test func overlongRunBreaksAtSoftBoundary() {
        var s = SentenceSegmenter(maxPendingCharacters: 40)
        let out = s.append("la la la la la la la la, oh oh oh oh oh oh oh oh oh oh oh oh oh")
        #expect(out.count == 1)
        #expect(out[0].count <= 40)
        #expect(!s.pending.isEmpty)
    }
}

@Suite struct AudioTimelineTests {
    @Test func mapsStreamTimeToCaptureTime() {
        let t = AudioTimeline()
        let base: UInt64 = 1_000_000_000
        t.append(duration: 0.1, startHostTime: base)
        t.append(duration: 0.1, startHostTime: base + HostClock.ticks(seconds: 0.1))
        // A gap in capture (e.g. the app paused) shifts later audio.
        t.append(duration: 0.1, startHostTime: base + HostClock.ticks(seconds: 5))
        #expect(abs(HostClock.ms(from: base, to: t.hostTime(at: 0.15)!) - 150) < 0.01)
        #expect(abs(HostClock.ms(from: base, to: t.hostTime(at: 0.25)!) - 5050) < 0.01)
        #expect(abs(t.secondsFed - 0.3) < 1e-9)
    }
}

@Suite struct WordLatencyTrackerTests {
    @Test func countsWordsAndCJKCharacters() {
        #expect(WordLatencyTracker.tokenCount("the quick  brown fox.") == 4)
        #expect(WordLatencyTracker.tokenCount("你好世界") == 4)
        #expect(WordLatencyTracker.tokenCount("我用 iPhone 拍照") == 5)
        #expect(WordLatencyTracker.tokenCount("") == 0)
    }

    @Test func comparesFirstAppearanceWithTrueWordEnd() {
        var t = WordLatencyTracker()
        let base: UInt64 = 5_000_000_000
        func at(_ s: Double) -> UInt64 { base + HostClock.ticks(seconds: s) }
        t.sawPartial("hello", at: at(0.6))
        t.sawPartial("hello big world", at: at(1.5))
        // Final adds a fourth word that no partial showed.
        let runs: [ASRResult.TimedRun] = [.init(text: "Hello ", end: 0.4), .init(text: "big ", end: 0.9),
                                          .init(text: "world ", end: 1.2), .init(text: "today.", end: 1.8)]
        let ms = t.finalized(runs: runs, at: at(2.5)) { at($0) }
        #expect(ms.count == 4)
        for (got, want) in zip(ms, [200.0, 600, 300, 700]) { #expect(abs(got - want) < 0.01) }
        // State resets for the next phrase.
        #expect(t.finalized(runs: [.init(text: "ok", end: 3)], at: at(3.5)) { at($0) }.count == 1)
    }
}

@Test func punctuationOnlyResultsAreTreatedAsSilence() {
    var a = TranscriptAssembler()
    #expect(a.apply(ASRResult(text: ", , , ,", isFinal: false, audioStart: 0, audioEnd: 2)) == .none)
    #expect(a.apply(ASRResult(text: " … ", isFinal: true, audioStart: 0, audioEnd: 2)) == .none)
    #expect(a.finalized.isEmpty)
    #expect(a.apply(ASRResult(text: "7.", isFinal: true, audioStart: 2, audioEnd: 3)) != .none)
}

@Suite struct CaptionTimelineTests {
    @Test func finalizedTextBecomesSentences() {
        var t = CaptionTimeline()
        #expect(t.finalize("Hello world. How are").map(\.source) == ["Hello world."])
        #expect(t.live.final == "How are")
        t.setVolatile("you doing")
        #expect(t.currentSentence == "How are you doing")
        #expect(t.finalize("you doing today?").map(\.source) == ["How are you doing today?"])
        #expect(t.captions.map(\.id) == [1, 2])
        #expect(t.live.final == "")
    }

    @Test func translationsAttachById() {
        var t = CaptionTimeline()
        let c = t.finalize("こんにちは。元気ですか？")
        #expect(c.count == 2)
        t.setTranslation("Hello.", for: c[0].id)
        t.setTranslation("ignored", for: 99)
        #expect(t.captions[0].translation == "Hello.")
        #expect(t.captions[1].translation == nil)
    }

    @Test func clearScreenHidesOldCaptionsButKeepsHistory() {
        var t = CaptionTimeline()
        t.finalize("One. Two. Thr")
        t.setVolatile("ee")
        t.clearScreen()
        #expect(t.isScreenEmpty)
        #expect(t.captions.map(\.source) == ["One.", "Two.", "Thr"])
        #expect(t.currentSentence == "Thr")
        t.finalize("Four.")
        #expect(t.visibleCaptions.map(\.source) == ["Four."])
    }

    @Test func historyIsBounded() {
        var t = CaptionTimeline()
        t.maxHistory = 3
        for i in 1...10 { t.finalize("S\(i).") }
        #expect(t.captions.map(\.source) == ["S8.", "S9.", "S10."])
    }
}

@Suite struct DisplayRuleTests {
    @Test func onlyTheNewestCharactersAreTentative() {
        var t = CaptionTimeline()
        t.setVolatile("私は東京")
        #expect(t.tentative == "私は東京")
        t.setVolatile("私は東京の学生")
        #expect(t.stableVolatile == "私は東京")
        #expect(t.tentative == "の学生")
        // A revision makes everything after the changed character tentative again.
        t.setVolatile("私は東北の学生")
        #expect(t.stableVolatile == "私は東")
        t.setVolatile("")
        #expect(t.tentative == "")
    }

    @Test func displayUnitsSplitLiveTextIntoSentences() {
        var t = CaptionTimeline()
        t.finalize("One. Two")
        t.setVolatile("more. Three is")
        #expect(t.displayUnits == ["One.", "Two more.", "Three is"])
    }

    @Test func windowDropsWholeSentencesAndNeverGoesBack() {
        var w = SentenceWindow()
        // Pretend at most two sentences fit.
        #expect(w.firstVisible(count: 2) { 2 - $0 <= 2 } == 0)
        #expect(w.firstVisible(count: 4) { 4 - $0 <= 2 } == 2)
        // Everything would fit again (shorter revision), but dropped sentences stay dropped.
        #expect(w.firstVisible(count: 4) { _ in true } == 2)
        // A single sentence that does not fit is still shown.
        #expect(w.firstVisible(count: 5) { _ in false } == 4)
        w.reset()
        #expect(w.firstVisible(count: 1) { _ in true } == 0)
        #expect(w.firstVisible(count: 0) { _ in true } == 0)
    }
}

@Suite struct CaptionTimingTests {
    private func runs(_ pieces: [(String, Double, Double)]) -> [ASRResult.TimedRun] {
        pieces.map { .init(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func sentencesGetTheTimeOfTheirWords() {
        var t = CaptionTimeline()
        let done = t.finalize("Hello world. How are you?", runs: runs([
            ("Hello ", 1.0, 1.4), ("world. ", 1.4, 1.9), ("How ", 2.5, 2.7), ("are ", 2.7, 2.8), ("you?", 2.8, 3.2),
        ]))
        #expect(done.map(\.source) == ["Hello world.", "How are you?"])
        #expect(done[0].start == 1.0 && done[0].end == 1.9)
        #expect(done[1].start == 2.5 && done[1].end == 3.2)
    }

    @Test func sentenceSpanningTwoFinalsKeepsItsStart() {
        var t = CaptionTimeline()
        #expect(t.finalize("I went to", runs: runs([("I ", 0.2, 0.3), ("went ", 0.3, 0.6), ("to", 0.6, 0.7)])).isEmpty)
        let done = t.finalize("the station. Then", runs: runs([("the ", 5.0, 5.1), ("station. ", 5.1, 5.6), ("Then", 6.0, 6.3)]))
        #expect(done.count == 1)
        #expect(done[0].start == 0.2 && done[0].end == 5.6)
        let tail = t.flush()
        #expect(tail?.start == 6.0 && tail?.end == 6.3)
    }

    @Test func runStraddlingTwoSentencesIsSplit() {
        var t = CaptionTimeline()
        // No spaces in Japanese; one run covers the end of a sentence and the start of the next.
        let done = t.finalize("晴れです。行こう。", runs: runs([("晴れで", 0, 0.6), ("す。行", 0.6, 1.2), ("こう。", 1.2, 1.8)]))
        #expect(done.count == 2)
        #expect(done[0].start == 0)
        #expect(abs(done[0].end! - 1.0) < 1e-9)
        #expect(abs(done[1].start! - 1.0) < 1e-9)
        #expect(done[1].end == 1.8)
    }

    @Test func untimedFinalsHaveNoTimes() {
        var t = CaptionTimeline()
        #expect(t.finalize("No timing here.").first?.start == nil)
    }
}

@Suite struct SubtitleSessionTests {
    private let session = SubtitleSession(title: "t", sourceLanguage: "ja-JP", targetLanguage: "en", duration: 60, captions: [
        .init(start: 1, end: 2, source: "A", translation: "a"),
        .init(start: 3, end: 4, source: "B", translation: "b"),
        .init(start: 20, end: 22, source: "C", translation: nil),
    ], fingerprints: [0, 1, 0xFFFF_FFFF, 0xDEAD_BEEF])

    @Test func captionsAppearOnTimeAndLingerTogether() {
        #expect(session.captions(at: 0.5).isEmpty)
        #expect(session.captions(at: 0.95, lead: 0.1).map(\.source) == ["A"])
        #expect(session.captions(at: 3.5).map(\.source) == ["A", "B"])
        // B is still lingering; C has not started.
        #expect(session.captions(at: 8.9).map(\.source) == ["A", "B"])
        #expect(session.captions(at: 9.5).isEmpty)
        // C starts alone: the gap before it is longer than the linger time.
        #expect(session.captions(at: 20.1).map(\.source) == ["C"])
        #expect(session.captions(at: 30).isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("livesub-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        try store.save(session)
        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].captions == session.captions)
        #expect(loaded[0].fingerprints == session.fingerprints)
        #expect(loaded[0].targetLanguage == "en")
        try store.delete(id: session.id)
        #expect(store.loadAll().isEmpty)
    }
}

@Suite struct SessionMatcherTests {
    /// Deterministic pseudo-random fingerprints (never the silent value).
    private func noise(_ count: Int, seed: UInt64) -> [UInt32] {
        var x = seed
        return (0..<count).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: x >> 32) | 1
        }
    }

    /// Flip roughly `rate` of the bits, like re-encoded or re-aligned audio would.
    private func corrupt(_ frames: [UInt32], rate: Double, seed: UInt64) -> [UInt32] {
        var x = seed
        return frames.map { f in
            var out = f
            for bit in 0..<32 {
                x = x &* 6364136223846793005 &+ 1442695040888963407
                if Double(x >> 40) / Double(1 << 24) < rate { out ^= 1 << UInt32(bit) }
            }
            return out == 0 ? 1 : out
        }
    }

    @Test func locksOntoTheRightPlaceDespiteBitErrors() {
        let saved = noise(5000, seed: 1)
        var m = SessionMatcher(references: [.init(id: "a", fingerprints: saved), .init(id: "b", fingerprints: noise(5000, seed: 2))])
        let live = corrupt(Array(saved[2000..<2400]), rate: 0.12, seed: 9)
        m.append(live)
        #expect(m.state == .locked(id: "a", delta: 2000))
        #expect(m.position?.frame == 2400)
    }

    @Test func unknownAudioNeverLocks() {
        var m = SessionMatcher(references: [.init(id: "a", fingerprints: noise(5000, seed: 1))])
        m.append(noise(2000, seed: 77))
        #expect(m.state == .searching)
    }

    @Test func seekRelocksElsewhere() {
        let saved = noise(8000, seed: 3)
        var m = SessionMatcher(references: [.init(id: "a", fingerprints: saved)])
        m.append(Array(saved[1000..<1400]))
        #expect(m.state == .locked(id: "a", delta: 1000))
        // Jump to a different place: the lock is dropped and found again.
        m.append(Array(saved[6000..<6500]))
        #expect(m.position?.frame == 6500)
    }

    @Test func pauseFreezesAndResumeContinues() {
        let saved = noise(8000, seed: 4)
        var m = SessionMatcher(references: [.init(id: "a", fingerprints: saved)])
        m.append(Array(saved[1000..<1400]))
        // Playback pauses: silence arrives while the saved audio has sound.
        m.append([UInt32](repeating: AudioFingerprinter.silent, count: 300))
        #expect(m.state == .paused(id: "a", frame: 1400))
        #expect(m.position?.frame == 1400)
        // Resume from the same spot.
        m.append(Array(saved[1400..<1700]))
        #expect(m.position?.frame == 1700)
        if case .locked = m.state {} else { Issue.record("expected locked after resume, got \(m.state)") }
    }

    @Test func silenceInTheSavedAudioIsNotAPause() {
        var saved = noise(4000, seed: 5)
        for i in 1500..<1800 { saved[i] = AudioFingerprinter.silent }
        var m = SessionMatcher(references: [.init(id: "a", fingerprints: saved)])
        m.append(Array(saved[1000..<2200]))
        #expect(m.state == .locked(id: "a", delta: 1000))
    }

    @Test func lockIsDroppedAfterTheSessionEnds() {
        let saved = noise(1000, seed: 6)
        var m = SessionMatcher(references: [.init(id: "a", fingerprints: saved)])
        m.append(Array(saved[500..<1000]))
        #expect(m.state == .locked(id: "a", delta: 500))
        m.append(noise(600, seed: 50))
        #expect(m.state == .searching)
    }
}

@Suite struct PauseDetectorTests {
    /// Feed 100 ms chunks at the given levels; return the indices where a pause was reported.
    private func pauses(_ levels: [Float]) -> [Int] {
        var d = PauseDetector()
        return levels.enumerated().compactMap { d.note(levelDB: $1, duration: 0.1) ? $0 : nil }
    }

    @Test func reportsOncePerPauseAfterEnoughSpeech() {
        let speech = [Float](repeating: -20, count: 10), gap = [Float](repeating: -60, count: 8)
        // The pause is reported on its fourth quiet chunk (0.4 s), and only once.
        #expect(pauses(speech + gap + speech + gap) == [13, 31])
    }

    @Test func musicUnderSpeechStillCountsAsAPause() {
        // Speech at -18 dB over music at -36 dB: the drop is what matters, not silence.
        let speech = [Float](repeating: -18, count: 10), music = [Float](repeating: -36, count: 6)
        #expect(pauses(speech + music) == [13])
    }

    @Test func ignoresBlipsAndSteadyNoise() {
        // A 0.1 s dip is not a pause.
        #expect(pauses([-20, -20, -20, -20, -20, -20, -50, -20, -20, -20]).isEmpty)
        // Constant level: nothing to report.
        #expect(pauses([Float](repeating: -30, count: 40)).isEmpty)
        // Quiet before any speech: nothing to commit.
        #expect(pauses([Float](repeating: -70, count: 20)).isEmpty)
    }
}

@Suite struct RewindMatchingTests {
    private func noise(_ count: Int, seed: UInt64) -> [UInt32] {
        var x = seed
        return (0..<count).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: x >> 32) | 1
        }
    }

    private func corrupt(_ frames: [UInt32], rate: Double, seed: UInt64) -> [UInt32] {
        var x = seed
        return frames.map { f in
            var out = f
            for bit in 0..<32 {
                x = x &* 6364136223846793005 &+ 1442695040888963407
                if Double(x >> 40) / Double(1 << 24) < rate { out ^= 1 << UInt32(bit) }
            }
            return out == 0 ? 1 : out
        }
    }

    @Test func referencesCanGrowWhileMatching() {
        let audio = noise(3000, seed: 11)
        var m = SessionMatcher()
        // The current session becomes matchable piece by piece, as ReplaySync feeds it.
        m.extend(id: "now", with: Array(audio[0..<1000]))
        m.extend(id: "now", with: Array(audio[1000..<2000]))
        // The viewer skips back to frame 600 of what was just heard.
        m.append(Array(audio[600..<900]))
        #expect(m.state == .locked(id: "now", delta: 600))
    }

    @Test func noisyReplayStillLocksQuickly() {
        // 20% of bits wrong: almost no frame matches exactly, so plain index lookup finds
        // nothing; one-bit probing and the exhaustive pass must carry it.
        let saved = noise(6000, seed: 21)
        var m = SessionMatcher(references: [.init(id: "a", fingerprints: saved)])
        m.append(corrupt(Array(saved[4000..<4200]), rate: 0.20, seed: 5))
        #expect(m.state == .locked(id: "a", delta: 4000))
    }

    @Test func unrelatedAudioStillNeverLocksWithTolerantSearch() {
        var m = SessionMatcher(references: [.init(id: "a", fingerprints: noise(6000, seed: 21))])
        m.append(noise(1500, seed: 99))
        #expect(m.state == .searching)
    }
}
