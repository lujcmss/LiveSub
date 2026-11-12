import Foundation

/// Merges a stream of volatile (partial) and final recognizer results into a stable transcript.
///
/// The recognizer keeps re-sending a volatile guess for the audio it has not committed yet,
/// then sends a final result for that stretch and moves on. This keeps exactly one volatile
/// tail and an append-only list of finalized segments. Pure value type; no audio needed.
public struct TranscriptAssembler: Sendable {
    public struct Segment: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double
    }

    public enum Change: Sendable, Equatable {
        /// Nothing visible changed (stale or empty result).
        case none
        /// The volatile tail was replaced.
        case volatileUpdated
        /// A segment was finalized (the associated value is that segment).
        case finalized(Segment)
    }

    public private(set) var finalized: [Segment] = []
    public private(set) var volatile: Segment?

    private static let epsilon = 0.01

    public init() {}

    /// End time of the last finalized audio.
    public var finalizedEnd: Double { finalized.last?.end ?? 0 }

    @discardableResult
    public mutating func apply(_ r: ASRResult) -> Change {
        // Music and sound effects make the recognizer emit stray punctuation (", , , ,").
        // Text without a single letter or digit is treated as silence.
        var text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { text = "" }
        let segment = Segment(text: text, start: r.audioStart, end: r.audioEnd)

        if r.isFinal {
            // A final result supersedes any volatile guess that overlaps it.
            if let v = volatile, v.start < r.audioEnd - Self.epsilon { volatile = nil }
            guard !text.isEmpty else { return .none }
            if let last = finalized.last, abs(last.start - r.audioStart) < Self.epsilon {
                // Same stretch finalized twice: keep the newer wording.
                finalized[finalized.count - 1] = segment
                return last == segment ? .none : .finalized(segment)
            }
            // Out-of-order final for audio we already committed: ignore.
            if r.audioEnd <= finalizedEnd + Self.epsilon, !finalized.isEmpty { return .none }
            finalized.append(segment)
            return .finalized(segment)
        }

        // Volatile guess for audio that has since been finalized: stale.
        if !finalized.isEmpty, r.audioEnd <= finalizedEnd + Self.epsilon { return .none }
        if text.isEmpty {
            guard volatile != nil else { return .none }
            volatile = nil
            return .volatileUpdated
        }
        guard volatile != segment else { return .none }
        volatile = segment
        return .volatileUpdated
    }

    /// All finalized text joined for reading.
    public var finalizedText: String { Self.join(finalized.map(\.text)) }
    public var volatileText: String { volatile?.text ?? "" }

    /// Joins fragments with a space, except between CJK characters, which take none.
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts where !part.isEmpty {
            if let a = out.unicodeScalars.last, let b = part.unicodeScalars.first,
               !(SentenceSegmenter.isCJK(a) || SentenceSegmenter.isCJK(b)),
               !CharacterSet.whitespaces.contains(a) {
                out += " "
            }
            out += part
        }
        return out
    }

    /// Drop finalized segments older than `seconds` before the newest one, to bound memory.
    public mutating func trim(keepingLast seconds: Double) {
        let cutoff = finalizedEnd - seconds
        finalized.removeAll { $0.end < cutoff }
    }
}
