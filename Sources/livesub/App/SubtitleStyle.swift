import AppKit

/// Everything about how subtitles look. Milestone 5 exposes these in Settings.
struct SubtitleStyle {
    /// A font family name (default Avenir Next: elegant, open letterforms that stay legible over
    /// video), or "system" (San Francisco) or "rounded" (San Francisco Rounded with rounded
    /// Japanese/Chinese faces). Japanese, Chinese and Korean always get a matching-weight face.
    var fontName = "Avenir Next"
    /// Size of the main line: the translation when one is shown, otherwise the original.
    var fontSize: CGFloat = 30
    var textColor: NSColor = .white
    /// How much dimmer still-changing text is drawn.
    var volatileOpacity: CGFloat = 0.55
    /// A translation of a sentence still being spoken: nearly full strength, because it is
    /// what the viewer reads while the sentence unfolds.
    var provisionalOpacity: CGFloat = 0.88
    var backgroundColor: NSColor = .black
    var backgroundOpacity: CGFloat = 0.62
    /// Lines for the main text (and, when both are shown, as many again for the original).
    var maxLines = 2
    /// Color of the original-language line when it is shown above its translation.
    var originalColor = NSColor(calibratedRed: 1.0, green: 0.87, blue: 0.52, alpha: 1)
    /// Size of the original-language line relative to the translation when both are shown.
    var originalScale: CGFloat = 0.7
    var mode: DisplayMode = .both
    var cornerRadius: CGFloat = 14
    var padding = NSSize(width: 22, height: 12)
    /// Language of each line ("ja", "ko", "zh-Hans", …), used to pick matching CJK glyphs.
    var originalLanguage = "ja"
    var translationLanguage = "en"

    enum DisplayMode: String { case originalOnly, both, translationOnly }

    /// Total lines the overlay may use in the current mode.
    var lineBudget: Int { mode == .both ? maxLines * 2 : maxLines }

    enum Role { case original, translation }

    /// Whether `role` is the small secondary line (only the original, and only in `.both`).
    private func isSecondary(_ role: Role) -> Bool { role == .original && mode == .both }

    func font(for role: Role) -> NSFont {
        let size = isSecondary(role) ? fontSize * originalScale : fontSize
        let language = role == .original ? originalLanguage : translationLanguage
        return Self.makeFont(name: fontName, size: size, language: language)
    }

    /// Builds the font with a fallback chain so CJK text uses a face that matches the Latin one
    /// and the right regional glyph shapes (Japanese kanji vs. Chinese hanzi).
    static func makeFont(name: String, size: CGFloat, language: String) -> NSFont {
        let base: NSFont
        // Clean sans faces at a weight that matches a demi-bold Latin font.
        var cjk: [String]
        switch language {
        case "ja": cjk = ["HiraginoSans-W6"]
        case "zh-Hant": cjk = ["PingFangTC-Semibold", "PingFangSC-Semibold"]
        case "zh-Hans": cjk = ["PingFangSC-Semibold", "PingFangTC-Semibold"]
        case "ko": cjk = ["AppleSDGothicNeo-SemiBold"]
        default: cjk = []
        }
        switch name {
        case "system":
            base = .systemFont(ofSize: size, weight: .semibold)
        case "rounded":
            let rounded = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.rounded)
            base = rounded.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size, weight: .semibold)
            switch language {
            case "ja": cjk = ["HiraMaruProN-W4"]
            case "zh-Hant": cjk = ["STYuanti-TC-Bold", "STYuanti-SC-Bold"]
            case "zh-Hans": cjk = ["STYuanti-SC-Bold", "STYuanti-TC-Bold"]
            default: break
            }
        default:
            // Weight 8 of 15 is demi-bold: sturdy enough over video without looking heavy.
            base = NSFontManager.shared.font(withFamily: name, traits: [], weight: 8, size: size)
                ?? NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        }
        guard !cjk.isEmpty else { return base }
        let cascade = cjk.map { NSFontDescriptor(name: $0, size: size) }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Line height as a multiple of the font size. Smaller = lines closer together.
    var lineSpacing: CGFloat = 1.12

    nonisolated(unsafe) private static let leadingCache = NSCache<NSString, NSNumber>()

    /// Factor that brings `role`'s font from its natural line height to `lineSpacing` em.
    private func leadingMultiple(for role: Role) -> CGFloat {
        let font = font(for: role)
        let language = role == .original ? originalLanguage : translationLanguage
        let key = "\(fontName)|\(font.pointSize)|\(language)" as NSString
        let natural: CGFloat
        if let cached = Self.leadingCache.object(forKey: key) {
            natural = CGFloat(cached.doubleValue)
        } else {
            let sample = NSAttributedString(string: Self.sample(for: language), attributes: [.font: font])
            natural = TailFitter.layout(sample, width: 2000).size.height
            Self.leadingCache.setObject(NSNumber(value: Double(natural)), forKey: key)
        }
        guard natural > 0 else { return 1 }
        return min(1, font.pointSize * lineSpacing / natural)
    }

    private static func sample(for language: String) -> String {
        switch language {
        case "ja": "あ漢g"
        case "zh-Hans", "zh-Hant": "汉g"
        case "ko": "한g"
        default: "Ag"
        }
    }

    /// Extra space above each sentence pair after the first, so pairs read as units.
    var pairSpacing: CGFloat { (fontSize * 0.45).rounded() }

    /// Measured height of one line of `role` text in its language (fonts differ a lot here).
    func lineHeight(for role: Role) -> CGFloat {
        let language = role == .original ? originalLanguage : translationLanguage
        let sample = Self.sample(for: language)
        let text = NSAttributedString(string: sample, attributes: attributes(role, dim: false))
        return TailFitter.layout(text, width: 2000).size.height
    }

    /// Height needed for the current mode's line budget.
    var contentHeight: CGFloat {
        switch mode {
        case .both:
            return CGFloat(maxLines) * (lineHeight(for: .original) + lineHeight(for: .translation))
                + CGFloat(max(0, maxLines - 1)) * pairSpacing
        case .originalOnly: return CGFloat(maxLines) * lineHeight(for: .original)
        case .translationOnly: return CGFloat(maxLines) * max(lineHeight(for: .translation), lineHeight(for: .original))
        }
    }

    /// Text attributes for a line. `dim` marks text that may still change.
    func attributes(_ role: Role, dim: Bool, provisional: Bool = false, spacingBefore: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // Prefer breaking Japanese/Korean lines between phrases rather than mid-word.
        paragraph.lineBreakStrategy = [.standard, .hangulWordPriority]
        // (No fixed line height: TextKit inflates Hiragino lines when one is set, so line
        // heights are measured instead; see `lineHeight(for:)`.)
        paragraph.paragraphSpacingBefore = spacingBefore
        // Fonts carry very different built-in leading (Hiragino 1.5 em, Avenir 1.37 em); scale
        // each line down to the same tight leading so a sentence and its translation sit together.
        paragraph.lineHeightMultiple = leadingMultiple(for: role)
        let color = isSecondary(role) ? originalColor : textColor
        return [
            .font: font(for: role),
            .foregroundColor: color.withAlphaComponent(dim ? volatileOpacity : provisional ? provisionalOpacity : 1),
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
