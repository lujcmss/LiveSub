import AppKit

/// A plain window with everything said so far, original and translation, as selectable text:
/// for copying a word, a phrase, or the whole conversation.
@MainActor
final class TranscriptWindow {
    struct Entry: Equatable {
        var source: String
        var translation: String?
    }

    private var window: NSWindow?
    private var textView: NSTextView?
    private var shown: [Entry] = []

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ entries: [Entry]) {
        if window == nil { build() }
        update(entries, force: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Refresh the text if it changed (call while visible).
    func update(_ entries: [Entry], force: Bool = false) {
        guard let textView, force || entries != shown else { return }
        // Don't disturb a selection the user is in the middle of making.
        if !force, textView.selectedRange().length > 0 { return }
        shown = entries
        let out = NSMutableAttributedString()
        let sourceAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor]
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        let translationAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        for e in entries {
            out.append(NSAttributedString(string: e.source + "\n", attributes: e.translation == nil ? sourceAttrs.merging([.paragraphStyle: paragraph]) { $1 } : sourceAttrs))
            if let t = e.translation { out.append(NSAttributedString(string: t + "\n", attributes: translationAttrs)) }
        }
        if entries.isEmpty {
            out.append(NSAttributedString(string: "Nothing has been said yet.", attributes: translationAttrs))
        }
        let atEnd = textView.visibleRect.maxY >= textView.bounds.maxY - 40
        textView.textStorage?.setAttributedString(out)
        if atEnd || force { textView.scrollToEndOfDocument(nil) }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "LiveSub Transcript"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("LiveSub.transcript")
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.backgroundColor = .textBackgroundColor
        w.contentView = scroll
        if !w.setFrameUsingName("LiveSub.transcript") { w.center() }
        window = w
        textView = tv
    }
}
