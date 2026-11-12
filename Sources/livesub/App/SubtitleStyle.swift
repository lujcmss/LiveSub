import AppKit

/// Everything about how subtitles look. Milestone 5 exposes these in Settings.
struct SubtitleStyle {
    var fontName: String? = nil          // nil = system font
    var fontSize: CGFloat = 30
    var textColor: NSColor = .white
    /// How much dimmer not-yet-final text is drawn.
    var volatileOpacity: CGFloat = 0.6
    var backgroundColor: NSColor = .black
    var backgroundOpacity: CGFloat = 0.62
    /// Lines of original text (and, when both are shown, as many again for the translation).
    var maxLines = 2
    var translationColor = NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.45, alpha: 1)
    /// Translation size relative to the original when both are shown.
    var translationScale: CGFloat = 0.92
    var mode: DisplayMode = .both

    enum DisplayMode: String { case originalOnly, both, translationOnly }

    /// Total lines the overlay may use in the current mode.
    var lineBudget: Int { mode == .both ? maxLines * 2 : maxLines }
    var cornerRadius: CGFloat = 14
    var padding = NSSize(width: 22, height: 12)

    var font: NSFont {
        if let fontName, let f = NSFont(name: fontName, size: fontSize) { return f }
        return .systemFont(ofSize: fontSize, weight: .semibold)
    }

    var lineHeight: CGFloat {
        let lm = NSLayoutManager()
        return ceil(lm.defaultLineHeight(for: font))
    }

    func translationAttributes(provisional: Bool, primary: Bool) -> [NSAttributedString.Key: Any] {
        var attrs = attributes(volatile: provisional)
        let size = primary ? fontSize : fontSize * translationScale
        attrs[.font] = fontName.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: .semibold)
        attrs[.foregroundColor] = (primary ? textColor : translationColor).withAlphaComponent(provisional ? volatileOpacity : 1)
        return attrs
    }

    func attributes(volatile: Bool) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // Prefer breaking Japanese/Korean lines between phrases rather than mid-word.
        paragraph.lineBreakStrategy = [.standard, .hangulWordPriority]
        return [
            .font: font,
            .foregroundColor: textColor.withAlphaComponent(volatile ? volatileOpacity : 1),
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ]
    }
}

/// Keeps only the last lines of a growing text.
enum TailFitter {
    /// A finished text layout that can be measured and then drawn exactly as measured.
    /// (Drawing with NSAttributedString.draw re-lays the text out and can disagree about line
    /// heights when CJK fallback fonts are involved, clipping the last line.)
    struct Layout {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
        /// Character range of each line.
        let lines: [NSRange]
        /// Size the text occupies (width of the widest line).
        let size: NSSize

        func draw(at origin: NSPoint) {
            let glyphs = manager.glyphRange(for: container)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
    }

    /// The suffix of `text` that fills at most `maxLines` lines at `width`, cut at a line start
    /// so earlier lines scroll away whole instead of the text reflowing.
    static func fit(_ text: NSAttributedString, width: CGFloat, maxLines: Int) -> Layout? {
        guard text.length > 0, width > 10 else { return nil }
        var current = text
        // Cutting the head can re-wrap the remainder once in rare cases; a few passes settle it.
        for _ in 0..<3 {
            let result = layout(current, width: width)
            if result.lines.count <= maxLines { return result }
            let start = result.lines[result.lines.count - maxLines].location
            let tail = NSMutableAttributedString(attributedString: current.attributedSubstring(from: NSRange(location: start, length: current.length - start)))
            while tail.length > 0, tail.string.first!.isWhitespace { tail.deleteCharacters(in: NSRange(location: 0, length: 1)) }
            current = tail
        }
        return layout(current, width: width)
    }

    static func layout(_ text: NSAttributedString, width: CGFloat) -> Layout {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var ranges: [NSRange] = []
        var maxWidth: CGFloat = 0
        let glyphs = manager.glyphRange(for: container)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, glyphRange, _ in
            ranges.append(manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil))
            maxWidth = max(maxWidth, used.width)
        }
        let used = manager.usedRect(for: container)
        return Layout(storage: storage, manager: manager, container: container, lines: ranges,
                      size: NSSize(width: ceil(maxWidth), height: ceil(used.height)))
    }
}
