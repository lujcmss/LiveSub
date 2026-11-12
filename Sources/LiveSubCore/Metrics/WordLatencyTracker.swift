import Foundation

/// Measures "word spoken → word first visible" without trusting the timing on partial results.
///
/// Partial results carry rough word timing, so instead we remember *when* the transcript first
/// reached N tokens, and once the recognizer finalizes the phrase (with accurate per-word
/// timing) we compare each word's true end time with the moment it first appeared.
public struct WordLatencyTracker: Sendable {
    /// `firstSeen[i]` = host time when the current phrase first showed at least i+1 tokens.
    private var firstSeen: [UInt64] = []

    public init() {}

    /// Number of display tokens: words for spaced scripts, characters for CJK.
    public static func tokenCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if SentenceSegmenter.isCJK(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    public mutating func sawPartial(_ text: String, at hostTime: UInt64) {
        let n = Self.tokenCount(text)
        while firstSeen.count < n { firstSeen.append(hostTime) }
    }

    /// Call when the phrase is finalized. Returns one latency (ms) per timed run, using
    /// `captureTime` to turn a stream position into the host time that audio was played.
    public mutating func finalized(runs: [ASRResult.TimedRun], at hostTime: UInt64,
                                   captureTime: (Double) -> UInt64?) -> [Double] {
        defer { firstSeen.removeAll(keepingCapacity: true) }
        var latencies: [Double] = []
        var tokens = 0
        for run in runs {
            let n = Self.tokenCount(run.text)
            guard n > 0 else { continue }
            tokens += n
            guard let spoken = captureTime(run.end) else { continue }
            // If no partial ever reached this many tokens, the word first appeared with the final.
            let seen = tokens <= firstSeen.count ? firstSeen[tokens - 1] : hostTime
            latencies.append(HostClock.ms(from: spoken, to: seen))
        }
        return latencies
    }
}
