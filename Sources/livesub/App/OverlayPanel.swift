import AppKit
import LiveSubCore

/// The floating subtitle window: borderless, never takes focus, sits above full-screen video
/// on every Space. Transparent except for the subtitle pill, so clicks elsewhere pass through.
final class OverlayPanel: NSPanel {
    static let frameKey = "LiveSub.overlayFrame"
    let subtitleView: SubtitleView!

    init(style: SubtitleStyle) {
        subtitleView = SubtitleView(style: style)
        // Moving and resizing are handled by SubtitleView itself (see its mouse handling), so
        // the window is neither system-resizable nor movable by its background.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        // Above normal and full-screen windows, below menus and system alerts.
        // (Set after isFloatingPanel, which resets the level to .floating.)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = subtitleView
        applyHeight(for: style)
        restoreOrPlaceDefault()
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSWindow.didMoveNotification, object: self)
        subtitleView.onResize = { [weak self] frame in
            guard let self else { return }
            self.isUserResizing = true
            self.setFrame(frame, display: true)
            self.onLiveResize?(frame.size)
        }
        subtitleView.onResizeEnded = { [weak self] in
            guard let self else { return }
            self.onEndResize?()
            self.isUserResizing = false
            self.frameChanged()
        }
        subtitleView.sizeLimits = { [weak self] in (self?.contentMinSize ?? .zero, self?.contentMaxSize ?? NSSize(width: 10_000, height: 10_000)) }
    }

    // Never steal keyboard focus from the video player.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static let fontSizeRange: ClosedRange<CGFloat> = 12...96

    /// Window height that exactly fits the style's lines.
    static func height(for style: SubtitleStyle) -> CGFloat {
        style.contentHeight + style.padding.height * 2 + (style.fontSize * 0.14).rounded() + 8
    }

    /// The font size at which the style's lines fill a window of `height`: lets the user size
    /// the text by dragging the window taller or shorter.
    static func fontSize(forHeight height: CGFloat, style: SubtitleStyle) -> CGFloat {
        var lo = fontSizeRange.lowerBound, hi = fontSizeRange.upperBound
        var probe = style
        for _ in 0..<9 {
            let mid = (lo + hi) / 2
            probe.fontSize = mid
            if Self.height(for: probe) > height { hi = mid } else { lo = mid }
        }
        return ((lo + hi) / 2).rounded()
    }

    /// Called while the user drags the window's edge (argument: the new size).
    var onLiveResize: ((NSSize) -> Void)?
    /// Called when the drag ends.
    var onEndResize: (() -> Void)?

    /// Height follows the style (lines × line height). Width and position are the user's; so
    /// is height while they are dragging, which resizes the text instead.
    func applyHeight(for style: SubtitleStyle) {
        var smallest = style, largest = style
        smallest.fontSize = Self.fontSizeRange.lowerBound
        largest.fontSize = Self.fontSizeRange.upperBound
        contentMinSize = NSSize(width: 320, height: Self.height(for: smallest))
        contentMaxSize = NSSize(width: 10_000, height: Self.height(for: largest))
        guard !isUserResizing else { return }
        var f = frame
        f.size.height = Self.height(for: style)
        setFrame(f, display: true)
    }

    /// True while the user is dragging an edge.
    private(set) var isUserResizing = false

    private func restoreOrPlaceDefault() {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let rect = NSRectFromString(saved)
            // Only reuse a saved frame that is still on a connected screen.
            if rect.width >= 320, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                setFrame(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: frame.height), display: true)
                return
            }
        }
        placeDefault()
    }

    /// Bottom-center of the main screen, like movie subtitles.
    func placeDefault() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let width = min(max(area.width * 0.62, 480), 1400)
        let origin = NSPoint(x: area.midX - width / 2, y: area.minY + area.height * 0.09)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: frame.height)), display: true)
    }

    @objc private func frameChanged() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }

    var clickThrough: Bool {
        get { ignoresMouseEvents }
        set { ignoresMouseEvents = newValue }
    }
}

/// Draws the last lines of the transcript in a rounded pill hugging the text.
final class SubtitleView: NSView {
    var style: SubtitleStyle { didSet { needsDisplay = true } }

    /// One sentence as drawn: original text, how much of its end is still tentative, and its
    /// translation (nil while it is on its way).
    struct Row: Equatable {
        var source: String
        var tentativeCount = 0
        var translation: String?
        var isProvisional = false
    }

    private var rows: [Row] = []
    /// Shown instead of subtitles (status messages such as "Listening…").
    private var notice: String?
    /// Outline of the whole window, shown while hovering or repositioning.
    var showsFrame = false { didSet { needsDisplay = true } }
    /// Called after each draw with the stamp passed to `update` (for latency measurement).
    var onDrawn: ((UInt64) -> Void)?
    private var pendingStamp: UInt64?
    private var tracking: NSTrackingArea?

    init(style: SubtitleStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(rows: [Row], stamp: UInt64? = nil) {
        self.rows = rows
        notice = nil
        if let stamp { pendingStamp = stamp }
        needsDisplay = true
        // Draw now rather than at the next display cycle, which can lag ~100 ms for a
        // background app.
        displayIfNeeded()
    }

    func showNotice(_ text: String?) {
        notice = text
        needsDisplay = true
    }

    var isEmpty: Bool { rows.isEmpty && notice == nil }

    private func composed() -> NSAttributedString {
        if let notice {
            var attrs = style.attributes(.translation, dim: true)
            attrs[.font] = NSFont.systemFont(ofSize: max(14, style.fontSize * 0.6), weight: .medium)
            attrs[.foregroundColor] = style.textColor.withAlphaComponent(0.85)
            return NSAttributedString(string: notice, attributes: attrs)
        }
        return compose(rows)
    }

    /// Lays the rows out for the current display mode.
    func compose(_ rows: [Row]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func append(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        /// Original text with its still-changing ending dimmed.
        func appendOriginal(_ row: Row, dimAll: Bool = false, spacingBefore: CGFloat = 0) {
            let dim = dimAll ? row.source.count : min(row.tentativeCount, row.source.count)
            append(String(row.source.dropLast(dim)), style.attributes(.original, dim: false, spacingBefore: spacingBefore))
            append(String(row.source.suffix(dim)), style.attributes(.original, dim: true, spacingBefore: spacingBefore))
        }
        /// Space between sentences, except between CJK characters.
        func appendSeparator(before next: String, _ role: SubtitleStyle.Role) {
            guard let a = out.string.unicodeScalars.last, let b = next.unicodeScalars.first else { return }
            if !(SentenceSegmenter.isCJK(a) || SentenceSegmenter.isCJK(b)) { append(" ", style.attributes(role, dim: false)) }
        }
        switch style.mode {
        case .originalOnly:
            // One flowing paragraph.
            for row in rows {
                appendSeparator(before: row.source, .original)
                appendOriginal(row)
            }
        case .translationOnly:
            // One flowing paragraph of translations; a sentence that has no translation yet
            // shows its original text dimmed so nothing is ever missing.
            for row in rows {
                let text = row.translation ?? row.source
                appendSeparator(before: text, .translation)
                if let t = row.translation {
                    append(t, style.attributes(.translation, dim: row.isProvisional))
                } else {
                    appendOriginal(row, dimAll: true)
                }
            }
        case .both:
            // Each sentence: the original, small, with its translation directly beneath.
            for (i, row) in rows.enumerated() {
                if i > 0 { append("\n", style.attributes(.translation, dim: false)) }
                let gap = i > 0 ? style.pairSpacing : 0
                appendOriginal(row, spacingBefore: gap)
                append("\n", style.attributes(.original, dim: false, spacingBefore: gap))
                // The translation line is reserved with "…" so the layout does not jump when
                // the translation arrives.
                append(row.translation ?? "…", style.attributes(.translation, dim: row.translation == nil || row.isProvisional))
            }
        }
        return out
    }

    private var textWidth: CGFloat { bounds.width - style.padding.width * 2 - 8 }

    /// Whether `rows` fit in the subtitle area without dropping lines.
    func fits(_ rows: [Row]) -> Bool {
        TailFitter.layout(compose(rows), width: textWidth).lines.count <= style.lineBudget
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsFrame {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: style.cornerRadius, yRadius: style.cornerRadius)
            NSColor.black.withAlphaComponent(0.25).setFill()
            outline.fill()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            outline.lineWidth = 1.5
            outline.setLineDash([6, 4], count: 2, phase: 0)
            outline.stroke()
        }
        let available = textWidth
        if let fitted = TailFitter.fit(composed(), width: available, maxLines: style.lineBudget), !fitted.lines.isEmpty {
            if Log.verbose {
                var heights: [String] = []
                let glyphs = fitted.manager.glyphRange(for: fitted.container)
                fitted.manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in heights.append(String(format: "%.0f", rect.height)) }
                Log.debug("layout: lines \(heights.joined(separator: ",")) total \(fitted.size.height) in view \(bounds.height)")
            }
            // Pill hugs the text, centered, sitting on the bottom edge of the window.
            // With tight leading the first line's tall glyphs rise above its line box; give
            // them room at the top.
            let topInset = (style.fontSize * 0.14).rounded()
            let pillSize = NSSize(width: fitted.size.width + style.padding.width * 2,
                                  height: fitted.size.height + style.padding.height * 2 + topInset)
            let pill = NSRect(x: (bounds.width - pillSize.width) / 2, y: bounds.height - pillSize.height - 4,
                              width: pillSize.width, height: pillSize.height)
            style.backgroundColor.withAlphaComponent(style.backgroundOpacity).setFill()
            NSBezierPath(roundedRect: pill, xRadius: style.cornerRadius, yRadius: style.cornerRadius).fill()
            fitted.draw(at: NSPoint(x: (bounds.width - available) / 2, y: pill.minY + style.padding.height + topInset))
        }
        if let stamp = pendingStamp {
            pendingStamp = nil
            onDrawn?(stamp)
        }
    }

    // MARK: Hover shows the frame so the window can be found, dragged and resized.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    var hoverChanged: ((Bool) -> Void)?
    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) {
        hoverChanged?(false)
        if dragZone == nil { NSCursor.arrow.set() }
    }

    // MARK: Moving and resizing by hand
    //
    // Drag the middle to move. Drag the top or bottom edge to change the height, which resizes
    // the text to fit; drag the left or right edge to change the width (how soon lines wrap).

    /// Which part of the window a point is over.
    struct Zone: OptionSet {
        let rawValue: Int
        static let top = Zone(rawValue: 1), bottom = Zone(rawValue: 2), left = Zone(rawValue: 4), right = Zone(rawValue: 8)
        /// No edge: the middle, which moves the window.
        static let middle: Zone = []
    }

    /// Thickness of the edge strips that resize.
    static let edgeThickness: CGFloat = 12

    func zone(at point: NSPoint) -> Zone {
        var z: Zone = []
        let t = Self.edgeThickness
        // The view is flipped: y grows downward.
        if point.y <= t { z.insert(.top) } else if point.y >= bounds.height - t { z.insert(.bottom) }
        if point.x <= t { z.insert(.left) } else if point.x >= bounds.width - t { z.insert(.right) }
        return z
    }

    /// The window frame after dragging `zone` by (dx, dy) in screen coordinates (y up).
    static func resized(_ start: NSRect, zone: Zone, dx: CGFloat, dy: CGFloat, min: NSSize, max: NSSize) -> NSRect {
        var f = start
        if zone.contains(.right) { f.size.width = Swift.min(Swift.max(start.width + dx, min.width), max.width) }
        if zone.contains(.left) {
            f.size.width = Swift.min(Swift.max(start.width - dx, min.width), max.width)
            f.origin.x = start.maxX - f.width
        }
        if zone.contains(.top) { f.size.height = Swift.min(Swift.max(start.height + dy, min.height), max.height) }
        if zone.contains(.bottom) {
            f.size.height = Swift.min(Swift.max(start.height - dy, min.height), max.height)
            f.origin.y = start.maxY - f.height
        }
        return f
    }

    /// Asked to apply a new frame while an edge is dragged, and told when the drag ends.
    var onResize: ((NSRect) -> Void)?
    var onResizeEnded: (() -> Void)?
    var sizeLimits: (() -> (min: NSSize, max: NSSize))?

    private var dragZone: Zone?
    private var dragStartMouse = NSPoint.zero
    private var dragStartFrame = NSRect.zero

    override func mouseDown(with event: NSEvent) {
        let z = zone(at: convert(event.locationInWindow, from: nil))
        guard z != .middle, let window else {
            self.window?.performDrag(with: event)
            return
        }
        dragZone = z
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let z = dragZone else { return }
        let now = NSEvent.mouseLocation
        dragEdge(z, dx: now.x - dragStartMouse.x, dy: now.y - dragStartMouse.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragZone != nil else { return }
        dragZone = nil
        onResizeEnded?()
    }

    private func dragEdge(_ z: Zone, dx: CGFloat, dy: CGFloat) {
        let limits = sizeLimits?() ?? (min: NSSize(width: 320, height: 60), max: NSSize(width: 10_000, height: 1_000))
        onResize?(Self.resized(dragStartFrame, zone: z, dx: dx, dy: dy, min: limits.min, max: limits.max))
    }

    /// Performs an edge drag in code, exactly as the mouse would (used by the self-test).
    func simulateDrag(_ z: Zone, dx: CGFloat, dy: CGFloat) {
        guard let window else { return }
        dragStartFrame = window.frame
        dragEdge(z, dx: dx / 2, dy: dy / 2)
        dragEdge(z, dx: dx, dy: dy)
        onResizeEnded?()
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragZone == nil else { return }
        let z = zone(at: convert(event.locationInWindow, from: nil))
        if z == .middle {
            NSCursor.openHand.set()
        } else if z.isSubset(of: [.top, .bottom]) {
            NSCursor.resizeUpDown.set()
        } else if z.isSubset(of: [.left, .right]) {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    /// PNG of the current contents over a mid-gray backdrop (used for automated visual checks).
    func snapshotPNG() -> Data? {
        guard bounds.width > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
        bounds.fill()
        rep.draw(in: bounds)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return nil }
        return out.representation(using: .png, properties: [:])
    }
}
