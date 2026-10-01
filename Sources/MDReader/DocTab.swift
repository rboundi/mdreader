import Foundation

/// One open Markdown file.
final class DocTab: Identifiable {
    let id = UUID()
    private(set) var url: URL
    private(set) var text = ""
    private(set) var error: String?
    var showSource = false
    /// Heading to jump to on the next render (from a link like `other.md#setup`).
    var pendingAnchor: String?
    /// Scroll position to restore on the next render (Back/Forward, reopened files).
    var pendingScroll: Double?
    /// Set when switching between rendered and source view, so the reader keeps their place.
    var syncOnNextDisplay = false
    /// Character offset to show on the next render (coming back from the editor).
    var pendingOffset: Int?
    /// Being edited in MDReader's editor.
    var editing = false
    /// The view to return to when editing ends.
    var sourceBeforeEditing = false
    /// Edited text not yet saved; nil when there are no unsaved changes.
    var draft: String?
    var isDirty: Bool { draft != nil && draft != text }
    /// What the page shows: the unsaved draft while editing, so the outline follows the edits.
    var displayText: String { editing ? draft ?? text : text }
    /// The last load found different text than before (as opposed to the same save arriving back).
    private(set) var textChanged = false
    /// How the file was encoded, so saving keeps it.
    private(set) var encoding: String.Encoding = .utf8
    /// Byte-order mark the file started with, written back on save.
    private var bom = Data()
    /// The file used \r\n line endings; saving converts the editor's \n back.
    private var crlf = false
    /// False when the file's encoding wasn't recognized: saving would damage its text.
    private(set) var canEdit = true
    /// Cursor and scroll position in the editor, and undo history, kept while switching tabs.
    var editorSelection: NSRange?
    var editorScroll: NSPoint?
    let undoManager = UndoManager()
    private(set) var wordCount = 0
    private(set) var tasks = (done: 0, total: 0)
    private(set) var modified: Date?
    /// `title:` from the YAML front matter.
    private(set) var frontMatterTitle: String?
    /// Called after the file's contents change on disk.
    var onChange: (() -> Void)?
    private var watcher: FileWatcher?

    var fileName: String { url.lastPathComponent }
    /// The front matter title, or the file name ("Untitled" for a new document).
    var title: String { frontMatterTitle ?? (isUntitled ? url.deletingPathExtension().lastPathComponent : fileName) }

    /// New documents live here until they're saved somewhere.
    static let untitledFolder = MarkdownFiles.canonical(
        FileManager.default.temporaryDirectory.appendingPathComponent("MDReader/Untitled", isDirectory: true))
    var isUntitled: Bool { url.deletingLastPathComponent().path == Self.untitledFolder.path }
    /// The file changed on disk while another tab was showing.
    var changedInBackground = false
    /// Name for exported and printed copies.
    var documentName: String { frontMatterTitle ?? url.deletingPathExtension().lastPathComponent }

    init(url: URL) {
        self.url = url.standardizedFileURL
        load()
        startWatching()
    }

    func reload() {
        load()
        // The watcher gives up if the file stays missing; pick it up again once it's back.
        if error == nil, watcher?.isWatching != true { startWatching() }
        onChange?()
    }

    /// Points the tab at the file's new location (after a rename or a first save). The tab keeps
    /// its identity: scroll position, cursor, undo history and editing state.
    func move(to newURL: URL) {
        url = newURL.standardizedFileURL
        draft = nil
        load()
        textChanged = false
        startWatching()
    }

    private func startWatching() {
        watcher = FileWatcher(url: url) { [weak self] in
            guard let self else { return }
            self.load()
            self.onChange?()
        }
    }

    /// UTF-8 first; UTF-16 only with a byte-order mark; then Windows-1252 / Latin-1 for old files.
    private struct Decoded {
        let text: String
        let encoding: String.Encoding
        var bom = Data()
        var exact = true
    }

    private static func decode(_ data: Data) -> Decoded {
        for (mark, encoding) in [
            (Data([0xEF, 0xBB, 0xBF]), String.Encoding.utf8),
            (Data([0xFF, 0xFE]), .utf16LittleEndian),
            (Data([0xFE, 0xFF]), .utf16BigEndian),
        ] where data.starts(with: mark) {
            if let s = String(data: data.dropFirst(mark.count), encoding: encoding) {
                return Decoded(text: s, encoding: encoding, bom: mark)
            }
        }
        if let s = String(data: data, encoding: .utf8) { return Decoded(text: s, encoding: .utf8) }
        if let s = String(data: data, encoding: .windowsCP1252) { return Decoded(text: s, encoding: .windowsCP1252) }
        return Decoded(text: String(decoding: data, as: UTF8.self), encoding: .utf8, exact: false)
    }

    /// Writes the draft to disk in the file's encoding (UTF-8 if it can't hold the new text).
    /// Writes the draft in the file's encoding and line endings. A file that was Windows-1252 and
    /// now holds characters it can't store is saved as UTF-8.
    func save() throws {
        guard let draft else { return }
        var text = draft
        if crlf { text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") }
        let data = text.data(using: encoding).map { bom + $0 } ?? Data(text.utf8)
        // Through a symlink, write to the file it points to rather than replacing the link.
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
        self.draft = nil
        load()
    }

    /// The file was changed on disk after it was last read.
    var changedSinceLoad: Bool {
        guard let modified,
            let now = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        else { return false }
        return now.timeIntervalSince(modified) > 0.001
    }

    /// Words that contain a letter or digit, so Markdown punctuation (#, -, |, ```) isn't counted.
    private static func countWords(_ text: String) -> Int {
        var count = 0
        var wordHasText = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if wordHasText { count += 1 }
                wordHasText = false
            } else if !wordHasText, CharacterSet.alphanumerics.contains(scalar) {
                wordHasText = true
            }
        }
        return count + (wordHasText ? 1 : 0)
    }

    /// Checked and unchecked task list items, skipping fenced code blocks.
    private static func countTasks(_ text: String) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        var fence: Substring?
        text.enumerateLines { line, _ in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                return
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
                return
            }
            // "- [ ] ", "* [x] ", "1. [X] ", also inside quotes ("> - [ ] ").
            var rest = trimmed
            while rest.hasPrefix(">") { rest = rest.dropFirst().drop { $0 == " " } }
            if let first = rest.first, "-*+".contains(first) {
                rest = rest.dropFirst()
            } else {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard !digits.isEmpty, digits.count <= 9 else { return }
                rest = rest.dropFirst(digits.count)
                guard let mark = rest.first, mark == "." || mark == ")" else { return }
                rest = rest.dropFirst()
            }
            guard rest.first == " " || rest.first == "\t" else { return }
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard rest.count >= 3, rest.hasPrefix("["), rest.dropFirst(2).first == "]" else { return }
            let after = rest.dropFirst(3).first
            guard after == nil || after == " " || after == "\t" else { return }
            switch rest.dropFirst().first {
            case " ": total += 1
            case "x", "X": total += 1; done += 1
            default: break
            }
        }
        return (done, total)
    }

    /// The `title:` line of a YAML front matter block at the top of the file.
    private static func frontMatterTitle(_ text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        var lines = text.split(maxSplits: 200, omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        guard lines.removeFirst().trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var title: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { return title }
            guard title == nil, line.hasPrefix("title:") else { continue }
            var value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { title = value }
        }
        return nil  // no closing line: not front matter
    }

    private func load() {
        do {
            let old = text
            let decoded = Self.decode(try Data(contentsOf: url))
            text = decoded.text
            encoding = decoded.encoding
            bom = decoded.bom
            canEdit = decoded.exact
            crlf = text.contains("\r\n")
            textChanged = text != old
            error = nil
            wordCount = Self.countWords(text)
            tasks = Self.countTasks(text)
            frontMatterTitle = Self.frontMatterTitle(text)
            modified = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        } catch {
            textChanged = false
            if !FileManager.default.fileExists(atPath: url.path) {
                self.error = "\(url.path) was moved or deleted."
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}
