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
    private var selectionWork: DispatchWorkItem?
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
        scheduleColoring()
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
        var range = textView.selectedRange()
        // A triple-click selects the line break too; keep it outside the markers.
        while range.length > 0, let last = UnicodeScalar(string.character(at: NSMaxRange(range) - 1)),
            CharacterSet.whitespacesAndNewlines.contains(last)
        {
            range.length -= 1
        }
        let m = (marker as NSString).length
        let selected = string.substring(with: range)
        // "*" must not mistake the stars of **bold** for italics.
        let star = marker == "*"
        let inner = selected.hasPrefix(marker) && selected.hasSuffix(marker) && (selected as NSString).length >= 2 * m
            && !(star && selected.hasPrefix("**") && !selected.hasPrefix("***"))
        let before = range.location >= m ? string.substring(with: NSRange(location: range.location - m, length: m)) : ""
        let after = NSMaxRange(range) + m <= string.length
            ? string.substring(with: NSRange(location: NSMaxRange(range), length: m)) : ""
        let doubled = star && range.location >= 2 && string.substring(with: NSRange(location: range.location - 2, length: 2)) == "**"
            && !(range.location >= 3 && string.substring(with: NSRange(location: range.location - 3, length: 3)) == "***")
        if inner {
            replace(range, with: String(selected.dropFirst(marker.count).dropLast(marker.count)))
            textView.setSelectedRange(NSRange(location: range.location, length: range.length - 2 * m))
        } else if before == marker, after == marker, !doubled {
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

    /// Changes part of the text from outside the editor (a task ticked in the preview), undoably.
    func replaceText(in range: NSRange, with text: String) {
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        let selection = textView.selectedRange()
        replace(range, with: text)
        textView.setSelectedRange(selection)
    }

    /// Replaces text as if typed, so it can be undone.
    private func replace(_ range: NSRange, with text: String) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.replaceCharacters(in: range, with: text)
        textView.didChangeText()
    }

    // MARK: Tables and lines

    /// Lines up the columns of the table the cursor is in. False when it isn't in one.
    func alignTable() -> Bool {
        let string = textView.string as NSString
        let cursor = textView.selectedRange().location
        // The run of lines around the cursor that have a pipe in them.
        var lines: [(text: String, terminator: String, start: Int)] = []
        func line(at location: Int) -> (text: String, terminator: String, start: Int, end: Int) {
            var start = 0, end = 0, contentsEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            return (
                string.substring(with: NSRange(location: start, length: contentsEnd - start)),
                string.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd)), start, end
            )
        }
        let here = line(at: cursor)
        guard here.text.contains("|") else { return false }
        lines.append((here.text, here.terminator, here.start))
        var start = here.start
        while start > 0 {
            let previous = line(at: start - 1)
            guard previous.text.contains("|") else { break }
            lines.insert((previous.text, previous.terminator, previous.start), at: 0)
            start = previous.start
        }
        var end = here.end
        while end < string.length {
            let next = line(at: end)
            guard next.text.contains("|"), next.end > end else { break }
            lines.append((next.text, next.terminator, next.start))
            end = next.end
        }
        // The table starts at the line above its delimiter row.
        guard let delimiter = lines.indices.dropFirst().first(where: { MarkdownTable.isDelimiter(lines[$0].text) }),
            let cursorLine = lines.lastIndex(where: { $0.start <= cursor }), cursorLine >= delimiter - 1
        else { return false }
        let table = Array(lines[(delimiter - 1)...])
        guard let aligned = MarkdownTable.aligned(table.map(\.text)) else { return false }
        let range = NSRange(location: table[0].start, length: end - table[0].start)
        let result = zip(aligned, table).map { $0 + $1.terminator }.joined()
        guard result != string.substring(with: range) else { return true }
        // The cursor stays on its row, at the same column where the row is still that long.
        let row = cursorLine - (delimiter - 1)
        let column = cursor - table[row].start
        replace(range, with: result)
        let rowStart = table[0].start
            + zip(aligned, table).prefix(row).reduce(0) { $0 + ($1.0 as NSString).length + ($1.1.terminator as NSString).length }
        textView.setSelectedRange(NSRange(location: rowStart + min(column, (aligned[row] as NSString).length), length: 0))
        return true
    }

    /// The range of line number `line` (from 1) without its line break; the last line when there
    /// are fewer.
    nonisolated static func range(ofLine line: Int, in string: NSString) -> NSRange {
        var location = 0
        var number = 1
        while number < line {
            let next = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            if next >= string.length {
                // Text ending in a line break has one more, empty, line.
                if next > location, string.length > 0, CharacterSet.newlines.contains(UnicodeScalar(string.character(at: string.length - 1)) ?? " ") {
                    location = next
                }
                break
            }
            location = next
            number += 1
        }
        var start = 0, end = 0, contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// Puts the cursor at the start of a line and shows it.
    func goToLine(_ line: Int) {
        let range = Self.range(ofLine: line, in: textView.string as NSString)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        if range.length > 0 { textView.showFindIndicator(for: range) }
        focus()
    }

    // MARK: Lists

    private static let listItem = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]?)*[ \t]*)([-*+]|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)

    /// Return inside a list item starts the next item; on an empty item it ends the list.
    private func continueList() -> Bool {
        let string = textView.string as NSString
        let cursor = textView.selectedRange()
        guard cursor.length == 0 else { return false }
        // The line without its terminator (\n or \r\n).
        var start = 0, end = 0, contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: cursor.location, length: 0))
        let line = NSRange(location: start, length: contentsEnd - start)
        let lineText = string.substring(with: line)
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
        if selector == #selector(NSResponder.insertTab(_:)) { return indentList(outdent: false) }
        if selector == #selector(NSResponder.insertBacktab(_:)) { return indentList(outdent: true) }
        return false
    }

    /// Tab and ⇧Tab move the list items in the selection one level in or out. Returns false (a normal
    /// Tab) when the cursor isn't in a list.
    private func indentList(outdent: Bool) -> Bool {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        let block = string.lineRange(for: selection)
        var result = ""
        var any = false
        var inList = false
        var firstDelta = 0
        var location = block.location
        while location < NSMaxRange(block) || (block.length == 0 && location == block.location) {
            var start = 0, end = 0, contentsEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            var line = string.substring(with: NSRange(location: start, length: contentsEnd - start))
            let terminator = string.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
            if let match = Self.listItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                // One level is the width of the item's marker and its space: 2 for "- ", 3 for "1. ".
                let width = match.range(at: 2).length + 1
                // In a quoted list the indentation sits after the last ">" and its space.
                let lead = (line as NSString).substring(with: match.range(at: 1)) as NSString
                var at = 0
                let quote = lead.range(of: ">", options: .backwards)
                if quote.location != NSNotFound {
                    at = NSMaxRange(quote)
                    if at < lead.length, lead.character(at: at) == 32 { at += 1 }
                }
                let indentation = lead.substring(from: at)
                let text = NSMutableString(string: line)
                var delta = 0
                if outdent {
                    if indentation.hasPrefix("\t") {
                        delta = -1
                    } else {
                        delta = -min(width, indentation.prefix { $0 == " " }.count)
                    }
                    text.deleteCharacters(in: NSRange(location: at, length: -delta))
                } else {
                    // Lists indented with tabs get another tab; otherwise spaces.
                    let unit = indentation.contains("\t") ? "\t" : String(repeating: " ", count: width)
                    text.insert(unit, at: at)
                    delta = (unit as NSString).length
                }
                line = text as String
                if !inList { firstDelta = delta }
                inList = true
                any = any || delta != 0
            }
            result += line + terminator
            if end <= location { break }
            location = end
        }
        // In a list but nothing to do (⇧Tab at the top level): swallow the key, change nothing.
        guard any else { return inList }
        replace(block, with: result)
        if selection.length == 0 {
            let moved = max(block.location, selection.location + firstDelta)
            textView.setSelectedRange(NSRange(location: moved, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: block.location, length: (result as NSString).length))
        }
        return true
    }

    // MARK: Syntax colors

    private static let rules: [(NSRegularExpression, KeyPath<EditorController, NSColor>)] = [
        (try! NSRegularExpression(pattern: #"^[ \t]{0,3}#{1,6}[ \t].*$"#, options: .anchorsMatchLines), \.headingColor),
        (try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])|^[ \t]*>+"#, options: .anchorsMatchLines), \.mutedColor),
        (try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)|<https?://[^>\s]+>"#), \.linkColor),
        (try! NSRegularExpression(pattern: #"`[^`\n]+`"#), \.codeColor),
    ]
    @objc private var headingColor: NSColor { .controlAccentColor }
    @objc private var mutedColor: NSColor { .secondaryLabelColor }
    @objc private var linkColor: NSColor { .linkColor }
    @objc private var codeColor: NSColor { .systemPink }

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

    /// Runs one of the find bar actions (show, replace, next, previous).
    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    // MARK: NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        guard tab != nil else { return }
        selectionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.tab != nil else { return }
            let range = self.textView.selectedRange()
            var words = 0
            if range.length > 0 {
                let selected = (self.textView.string as NSString).substring(with: range)
                selected.enumerateSubstrings(in: selected.startIndex..<selected.endIndex, options: .byWords) { _, _, _, _ in
                    words += 1
                }
            }
            self.onSelectionWords?(words)
        }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
    /// Pasting a web address over selected text makes a link of it: [text](address).
    override func paste(_ sender: Any?) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        if range.length > 0, selected.rangeOfCharacter(from: .newlines) == nil,
            !selected.contains("["), !selected.contains("]"), !Self.isWebAddress(selected),
            let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
            Self.isWebAddress(pasted)
        {
            // Angle brackets keep an address with parentheses in one piece.
            let address = pasted.contains("(") || pasted.contains(")") ? "<\(pasted)>" : pasted
            let link = "[\(selected)](\(address))"
            if shouldChangeText(in: range, replacementString: link) {
                replaceCharacters(in: range, with: link)
                didChangeText()
            }
            return
        }
        super.paste(sender)
    }

    private static func isWebAddress(_ text: String) -> Bool {
        (text.hasPrefix("http://") || text.hasPrefix("https://"))
            && !text.contains(where: \.isWhitespace) && URL(string: text) != nil
    }

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
