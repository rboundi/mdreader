import AppKit
import SwiftUI

/// The plain-text editor shown in place of the page while a tab is being edited. Like the web view,
/// one instance is shared by every tab.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: EditorTextView
    private(set) weak var tab: DocTab?
    /// Called when a tab gains or loses unsaved changes, and (with a pause) after typing.
    var onDirtyChange: (() -> Void)?
    var onTextChange: ((DocTab) -> Void)?
    /// Offset to scroll to and focus to take once the editor is in the window.
    private var pendingOffset: Int?
    private var pendingFocus = false
    private var textChangeWork: DispatchWorkItem?
    private var appliedTheme: AppearanceMode?

    override init() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // TextKit 1, for the line lookups in topOffset and scroll(toOffset:).
        textView = EditorTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        super.init()
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        scrollView.drawsBackground = true
        applyColors()
    }

    /// Page and text colors to match the reading theme.
    func applyColors() {
        appliedTheme = Prefs.appearanceMode
        scrollView.backgroundColor = Palette.page
        textView.backgroundColor = Palette.page
        textView.textColor = Palette.text
        textView.insertionPointColor = Palette.text
        textView.typingAttributes[.foregroundColor] = Palette.text
    }

    /// Recolors only when the theme changed (settings change for many other reasons).
    func themeMayHaveChanged() {
        if Prefs.appearanceMode != appliedTheme { applyColors() }
    }

    /// Shows `tab`'s draft (or its saved text), keeping each tab's cursor and scroll position.
    func show(_ tab: DocTab) {
        if self.tab === tab { return }
        if let current = self.tab { remember(current) }
        self.tab = tab
        setText(tab.draft ?? tab.text)
        let selection = tab.editorSelection ?? NSRange(location: 0, length: 0)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        if let scroll = tab.editorScroll {
            textView.layoutManager?.ensureLayout(forBoundingRect: NSRect(origin: scroll, size: scrollView.bounds.size),
                in: textView.textContainer!)
            scrollView.contentView.scroll(to: scroll)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        pendingFocus = true
    }

    func stopShowing(_ tab: DocTab) {
        guard self.tab === tab else { return }
        remember(tab)
        tab.undoManager.removeAllActions()
        self.tab = nil
    }

    private func remember(_ tab: DocTab) {
        tab.editorSelection = textView.selectedRange()
        tab.editorScroll = scrollView.contentView.bounds.origin
    }

    /// Scrolls to `offset` and takes focus once the editor is in the window (it may not be yet).
    func prepare(offset: Int?) {
        pendingOffset = offset
        pendingFocus = true
        DispatchQueue.main.async { self.applyPending() }
    }

    func applyPending() {
        guard textView.window != nil else { return }
        if let offset = pendingOffset {
            pendingOffset = nil
            scroll(toOffset: offset)
        }
        if pendingFocus {
            pendingFocus = false
            focus()
        }
    }

    /// Replaces the text (the file changed on disk), keeping the cursor where it was.
    func reload(from tab: DocTab) {
        guard self.tab === tab, textView.string != tab.text else { return }
        tab.undoManager.removeAllActions()
        let selection = textView.selectedRange()
        let visible = scrollView.contentView.bounds.origin
        setText(tab.text)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        scrollView.contentView.scroll(to: visible)
    }

    private func setText(_ text: String) {
        textView.string = text
        textView.setTextColor(Palette.text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// Character offset of the first line in view.
    var topOffset: Int {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        var point = scrollView.contentView.bounds.origin
        point.y -= textView.textContainerOrigin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(0, point.y) + 4), in: container)
        return layout.characterIndexForGlyph(at: glyph)
    }

    /// Scrolls so the line containing `offset` is at the top.
    func scroll(toOffset offset: Int) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let length = string.length
        var location = min(max(0, offset), length)
        // Not inside an emoji or between \r and \n.
        if location < length { location = string.rangeOfComposedCharacterSequence(at: location).location }
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(length, location + 1)))
        let glyph = layout.glyphIndexForCharacter(at: min(location, max(0, length - 1)))
        let line = length == 0 ? .zero : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = line.minY + textView.textContainerOrigin.y - 12
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if textView.selectedRange().location < location || textView.selectedRange().location > location + 2000 {
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    /// Runs one of the find bar actions (show, next, previous).
    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let tab else { return }
        let wasDirty = tab.isDirty
        tab.draft = textView.string
        if tab.isDirty != wasDirty { onDirtyChange?() }
        textChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            if let tab, self?.tab === tab { self?.onTextChange?(tab) }
        }
        textChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Each tab has its own undo history, so ⌘Z never changes another document.
    func undoManager(for view: NSTextView) -> UndoManager? {
        tab?.undoManager
    }
}

/// Keeps the text in a centered column as wide as the reading width. Dropped files open as tabs
/// instead of inserting their path; dragged tabs are ignored.
final class EditorTextView: NSTextView {
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            if pasteboard.string(forType: .string).flatMap(UUID.init(uuidString:)) == nil {
                MainActor.assumeIsolated { AppState.shared.open(urls) }
            }
            return true
        }
        return super.performDragOperation(sender)
    }

    override func layout() {
        super.layout()
        let width = Prefs.width.pixels > 0 ? CGFloat(Prefs.width.pixels) : .greatestFiniteMagnitude
        let horizontal = max(24, (bounds.width - width) / 2)
        if abs(textContainerInset.width - horizontal) > 0.5 {
            textContainerInset = NSSize(width: horizontal, height: 28)
        }
    }
}

struct EditorHost: NSViewRepresentable {
    let editor: EditorController
    func makeNSView(context: Context) -> NSScrollView {
        DispatchQueue.main.async { editor.applyPending() }
        return editor.scrollView
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        DispatchQueue.main.async { editor.applyPending() }
    }
}
