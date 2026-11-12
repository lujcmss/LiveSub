import Foundation

/// Splits a growing stream of finalized text into complete sentences.
///
/// Feed text as it is finalized; complete sentences come back, and an unfinished tail is held
/// until more text (or `flush`) arrives. Translation works a sentence at a time, so this is
/// what decides when a translation can start. Pure value type.
public struct SentenceSegmenter: Sendable {
    /// Unfinished text waiting for its sentence end.
    public private(set) var pending = ""
    /// A tail longer than this is emitted even without punctuation (run-on speech, songs).
    public var maxPendingCharacters: Int

    public init(maxPendingCharacters: Int = 160) {
        self.maxPendingCharacters = maxPendingCharacters
    }

    /// Add finalized text; returns any sentences that are now complete.
    public mutating func append(_ text: String) -> [String] {
        pending = TranscriptAssembler.join([pending, text.trimmingCharacters(in: .whitespacesAndNewlines)])
        let (sentences, rest) = Self.split(pending)
        pending = rest
        var out = sentences
        if pending.count > maxPendingCharacters {
            let (head, tail) = Self.splitAtSoftBreak(pending, limit: maxPendingCharacters)
            out.append(head)
            pending = tail
        }
        return out
    }

    /// Emit whatever is pending (call after a pause in speech, or at the end).
    public mutating func flush() -> String? {
        let t = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return t.isEmpty ? nil : t
    }

    // MARK: Rules

    static let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "‼", "⁇", "।", "؟"]
    /// Characters that may trail a terminator and still belong to the sentence.
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "」", "』", "）", "»"]
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "inc", "ltd", "co", "no",
        "e.g", "i.e", "u.s", "u.k", "a.m", "p.m", "mt", "gen", "col", "lt", "sgt", "capt",
        "sra", "srta", "dra", "mme", "mlle", "hr", "fr", "bzw", "z.b",
    ]

    /// Splits `text` into complete sentences and an unfinished remainder.
    public static func split(_ text: String) -> (sentences: [String], remainder: String) {
        var sentences: [String] = []
        let chars = Array(text)
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard terminators.contains(c) else { i += 1; continue }
            // Swallow runs like "?!", "..." and trailing quotes/brackets.
            var end = i
            while end + 1 < chars.count, terminators.contains(chars[end + 1]) || closers.contains(chars[end + 1]) { end += 1 }
            let next: Character? = end + 1 < chars.count ? chars[end + 1] : nil
            let isWide = c.unicodeScalars.first.map(isCJK) ?? false || "。！？".contains(c)

            var isBoundary: Bool
            if isWide {
                isBoundary = true
            } else if let next {
                // Latin-style punctuation ends a sentence only when followed by whitespace.
                isBoundary = next.isWhitespace
            } else {
                // Terminator is the last character so far. A period might still be a decimal or
                // abbreviation in progress, but "?" and "!" are unambiguous.
                isBoundary = true
            }
            if isBoundary, c == ".", end == i {
                let word = precedingWord(chars, before: i)
                if abbreviations.contains(word.lowercased()) { isBoundary = false }
                // Single letters ("J. K. Rowling") and digits before a following digit ("3. 5").
                else if word.count == 1, word.first!.isLetter, word.first!.isUppercase { isBoundary = false }
            }
            if isBoundary {
                let s = String(chars[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                start = end + 1
            }
            i = end + 1
        }
        let rest = start < chars.count ? String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (sentences, rest)
    }

    static func precedingWord(_ chars: [Character], before index: Int) -> String {
        var j = index - 1
        var word: [Character] = []
        while j >= 0, !chars[j].isWhitespace {
            word.append(chars[j]); j -= 1
        }
        return String(word.reversed())
    }

    /// Break an over-long run at the last comma or space before `limit`.
    static func splitAtSoftBreak(_ text: String, limit: Int) -> (String, String) {
        let chars = Array(text)
        let window = chars.prefix(limit)
        let soft: Set<Character> = [",", ";", ":", "，", "、", "；", "："]
        var cut = window.lastIndex(where: { soft.contains($0) }).map { $0 + 1 }
        if cut == nil || cut! < limit / 2 { cut = window.lastIndex(where: { $0.isWhitespace }) ?? cut }
        let at = cut.map { $0 == 0 ? limit : $0 } ?? limit
        let head = String(chars[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(chars[at...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, tail)
    }

    /// Han, Hiragana, Katakana, Hangul and full-width punctuation: scripts written without spaces.
    public static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2E80...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }
}
