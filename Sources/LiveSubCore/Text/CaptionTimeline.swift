import Foundation

/// What the overlay shows: completed sentences plus the sentence still being spoken.
///
/// Fed with finalized text and the current volatile guess; splits finalized text into
/// sentences (each can later carry a translation) and tracks which of them are still on
/// screen. Pure value type so the display rules can be unit-tested without a window.
public struct CaptionTimeline: Sendable {
    public struct Caption: Sendable, Equatable, Identifiable {
        public let id: Int
        public var source: String
        public var translation: String?
    }

    /// Completed sentences, oldest first (bounded history, used for display and copying).
    public private(set) var captions: [Caption] = []
    /// Finalized text whose sentence has not ended yet.
    public private(set) var pendingFinal = ""
    /// The recognizer's current guess for audio it has not committed.
    public private(set) var volatile = ""
    private var stableVolatileCount = 0
    public var maxHistory = 200

    private var segmenter = SentenceSegmenter()
    private var nextID = 1
    /// Captions with id below this were cleared from the screen (after a pause in speech).
    private var firstVisibleID = 1

    public init() {}

    /// Add finalized text. Returns the sentences it completed.
    @discardableResult
    public mutating func finalize(_ text: String) -> [Caption] {
        var done: [Caption] = []
        for sentence in segmenter.append(text) { done.append(makeCaption(sentence)) }
        pendingFinal = segmenter.pending
        return done
    }

    public mutating func setVolatile(_ text: String) {
        // Characters that survived from the previous guess are considered stable; only the
        // newest addition (or a revised ending) is still tentative.
        stableVolatileCount = zip(volatile, text).prefix { $0 == $1 }.count
        volatile = text
    }

    /// The part of the volatile guess that the recognizer has repeated unchanged.
    public var stableVolatile: String { String(volatile.prefix(stableVolatileCount)) }
    /// The newest, still-changing end of the volatile guess.
    public var tentative: String { String(volatile.dropFirst(stableVolatileCount)) }

    /// Sentences to lay out, oldest first: completed ones still on screen, then the text in
    /// progress split at sentence ends (its last element may be an unfinished sentence).
    public var displayUnits: [String] {
        let live = TranscriptAssembler.join([pendingFinal, volatile])
        let (sentences, rest) = SentenceSegmenter.split(live)
        return visibleCaptions.map(\.source) + sentences + (rest.isEmpty ? [] : [rest])
    }

    /// Close the unfinished sentence (speech paused without punctuation).
    @discardableResult
    public mutating func flush() -> Caption? {
        let tail = segmenter.flush()
        pendingFinal = ""
        guard let tail else { return nil }
        return makeCaption(tail)
    }

    public mutating func setTranslation(_ text: String, for id: Int) {
        guard let i = captions.firstIndex(where: { $0.id == id }) else { return }
        captions[i].translation = text
    }

    /// Hide everything shown so far; the next speech starts on a clean overlay.
    public mutating func clearScreen() {
        flush()
        volatile = ""
        stableVolatileCount = 0
        firstVisibleID = nextID
    }

    /// Completed sentences still on screen, oldest first.
    public var visibleCaptions: [Caption] { captions.filter { $0.id >= firstVisibleID } }

    /// The sentence in progress: committed part and tentative part.
    public var live: (final: String, volatile: String) { (pendingFinal, volatile) }

    public var isScreenEmpty: Bool { visibleCaptions.isEmpty && pendingFinal.isEmpty && volatile.isEmpty }

    /// The most recent sentence worth copying: the one in progress if any, else the last completed.
    public var currentSentence: String? {
        let inProgress = TranscriptAssembler.join([pendingFinal, volatile])
        if !inProgress.isEmpty { return inProgress }
        return captions.last?.source
    }

    private mutating func makeCaption(_ source: String) -> Caption {
        let c = Caption(id: nextID, source: source, translation: nil)
        nextID += 1
        captions.append(c)
        if captions.count > maxHistory { captions.removeFirst(captions.count - maxHistory) }
        return c
    }
}

/// Chooses the first sentence to show so that subtitles always begin at a sentence start.
///
/// Sentences are dropped from the front, whole, when the text no longer fits; a dropped
/// sentence never comes back (no flicker). If the newest sentence alone does not fit, it is
/// shown anyway and the renderer keeps its last lines.
public struct SentenceWindow: Sendable {
    private var start = 0

    public init() {}

    public mutating func reset() { start = 0 }

    /// - Parameters:
    ///   - count: number of sentences available.
    ///   - fits: whether sentences `index...` fit in the subtitle area.
    /// - Returns: index of the first sentence to show.
    public mutating func firstVisible(count: Int, fits: (Int) -> Bool) -> Int {
        guard count > 0 else { start = 0; return 0 }
        start = min(start, count - 1)
        while start < count - 1, !fits(start) { start += 1 }
        return start
    }
}
