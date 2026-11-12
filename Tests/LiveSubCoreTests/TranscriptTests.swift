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
