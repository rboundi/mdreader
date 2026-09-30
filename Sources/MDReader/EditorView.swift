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
    /// The first line in view changed (for the preview beside the editor), and the selection's word count.
    var onScroll: ((Int) -> Void)?
    var onSelectionWords: ((Int) -> Void)?
    private var scrollWork: DispatchWorkItem?
    private var colorWork: DispatchWorkItem?
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        applyColors()
    }

    @objc private func didScroll() {
        scheduleColoring()
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.tab != nil else { return }
            self.onScroll?(self.topOffset)
        }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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
        scheduleColoring()
    }

    // MARK: Formatting

    /// ⌘B / ⌘I: wraps the selection in `marker`, or removes it if it's already there.
    func toggleWrap(_ marker: String) {
        let string = textView.string as NSString
        let range = textView.selectedRange()
        let m = (marker as NSString).length
        let selected = string.substring(with: range)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), (selected as NSString).length >= 2 * m {
            replace(range, with: String(selected.dropFirst(marker.count).dropLast(marker.count)))
            textView.setSelectedRange(NSRange(location: range.location, length: range.length - 2 * m))
        } else if range.location >= m, range.location + range.length + m <= string.length,
            string.substring(with: NSRange(location: range.location - m, length: m)) == marker,
            string.substring(with: NSRange(location: range.location + range.length, length: m)) == marker
        {
            replace(NSRange(location: range.location - m, length: range.length + 2 * m), with: selected)
            textView.setSelectedRange(NSRange(location: range.location - m, length: range.length))
        } else {
            replace(range, with: marker + selected + marker)
            textView.setSelectedRange(NSRange(location: range.location + m, length: range.length))
        }
    }

    /// ⌘K: turns the selection into a link and selects the address to type.
    func insertLink() {
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let isAddress = selected.hasPrefix("http://") || selected.hasPrefix("https://")
        let text = isAddress ? "[](\(selected))" : "[\(selected)](url)"
        replace(range, with: text)
        let location = range.location
        if isAddress {
            textView.setSelectedRange(NSRange(location: location + 1, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: location + (selected as NSString).length + 3, length: 3))
        }
    }

    /// Replaces text as if typed, so it can be undone.
    private func replace(_ range: NSRange, with text: String) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.replaceCharacters(in: range, with: text)
        textView.didChangeText()
    }

    // MARK: Lists

    private static let listItem = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]?)*)([-*+]|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)

    /// Return inside a list item starts the next item; on an empty item it ends the list.
    private func continueList() -> Bool {
        let string = textView.string as NSString
        let cursor = textView.selectedRange()
        guard cursor.length == 0 else { return false }
        let line = string.lineRange(for: NSRange(location: cursor.location, length: 0))
        var lineText = string.substring(with: line)
        if lineText.hasSuffix("\n") { lineText.removeLast() }
        if lineText.hasSuffix("\r") { lineText.removeLast() }
        let full = NSRange(location: 0, length: (lineText as NSString).length)
        guard let match = Self.listItem.firstMatch(in: lineText, range: full),
            cursor.location >= line.location + match.range.length
        else { return false }
        let text = lineText as NSString
        if match.range.length == text.length {
            // Empty item: remove the marker, leaving the indentation.
            let indent = text.substring(with: match.range(at: 1))
            replace(NSRange(location: line.location, length: text.length), with: indent)
            return true
        }
        var marker = text.substring(with: match.range(at: 2))
        if match.range(at: 3).location != NSNotFound, let n = Int(text.substring(with: match.range(at: 3))) {
            marker = "\(n + 1)" + text.substring(with: match.range(at: 4))
        }
        let task = match.range(at: 6).location != NSNotFound ? "[ ] " : ""
        let next = "\n" + text.substring(with: match.range(at: 1)) + marker + text.substring(with: match.range(at: 5)) + task
        replace(cursor, with: next)
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { return continueList() }
        return false
    }

    // MARK: Syntax colors

    private static let rules: [(NSRegularExpression, KeyPath<EditorController, NSColor>)] = [
        (try! NSRegularExpression(pattern: #"^[ \t]{0,3}#{1,6}[ \t].*$"#, options: .anchorsMatchLines), \.headingColor),
        (try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])|^[ \t]*>+"#, options: .anchorsMatchLines), \.mutedColor),
        (try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)|<https?://[^>\s]+>"#), \.linkColor),
        (try! NSRegularExpression(pattern: #"`[^`\n]+`"#), \.codeColor),
        (try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)[^\n]*?\S\1"#), \.strongColor),
    ]
    @objc private var headingColor: NSColor { .controlAccentColor }
    @objc private var mutedColor: NSColor { .secondaryLabelColor }
    @objc private var linkColor: NSColor { .linkColor }
    @objc private var codeColor: NSColor { .systemPink }
    @objc private var strongColor: NSColor { Palette.text }

    private func scheduleColoring() {
        colorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.colorVisibleText() }
        colorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Colors the Markdown syntax on screen (and a screen above and below), with temporary
    /// attributes: nothing is added to the text or the undo history.
    private func colorVisibleText() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        guard string.length > 0 else { return }
        var visible = scrollView.contentView.bounds
        visible.origin.y -= visible.height
        visible.size.height *= 3
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        var range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        range = string.lineRange(for: range)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        for (pattern, color) in Self.rules {
            let value = self[keyPath: color]
            pattern.enumerateMatches(in: string as String, range: range) { match, _, _ in
                if let match { layout.addTemporaryAttribute(.foregroundColor, value: value, forCharacterRange: match.range) }
            }
        }
        // Fenced code blocks: find which fences are open at the start of the range.
        let fence = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(```|~~~)"#, options: .anchorsMatchLines)
        var open: Int?
        for match in fence.matches(in: string as String, range: NSRange(location: 0, length: NSMaxRange(range))) {
            if let start = open {
                let block = NSRange(location: start, length: NSMaxRange(string.lineRange(for: match.range)) - start)
                if NSMaxRange(block) > range.location {
                    layout.addTemporaryAttribute(.foregroundColor, value: codeColor, forCharacterRange: block)
                }
                open = nil
            } else {
                open = match.range.location
            }
        }
        if let start = open {
            layout.addTemporaryAttribute(
                .foregroundColor, value: codeColor,
                forCharacterRange: NSRange(location: start, length: NSMaxRange(range) - start))
        }
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
        guard let layout = textView.layoutManager else { return }
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

    func textViewDidChangeSelection(_ notification: Notification) {
        let range = textView.selectedRange()
        guard tab != nil else { return }
        var words = 0
        if range.length > 0 {
            let selected = (textView.string as NSString).substring(with: range)
            selected.enumerateSubstrings(in: selected.startIndex..<selected.endIndex, options: .byWords) { _, _, _, _ in
                words += 1
            }
        }
        onSelectionWords?(words)
    }

    func textDidChange(_ notification: Notification) {
        scheduleColoring()
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
