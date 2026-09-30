import Foundation

/// One open Markdown file.
final class DocTab: Identifiable {
    let id = UUID()
    let url: URL
    private(set) var text = ""
    private(set) var error: String?
    var showSource = false
    /// Heading to jump to on the next render (from a link like `other.md#setup`).
    var pendingAnchor: String?
    /// Scroll position to restore on the next render (Back/Forward, reopened files).
    var pendingScroll: Double?
    /// Set when switching between rendered and source view, so the reader keeps their place.
    var syncOnNextDisplay = false
    private(set) var wordCount = 0
    private(set) var tasks = (done: 0, total: 0)
    private(set) var modified: Date?
    /// `title:` from the YAML front matter.
    private(set) var frontMatterTitle: String?
    /// Called after the file's contents change on disk.
    var onChange: (() -> Void)?
    private var watcher: FileWatcher?

    var fileName: String { url.lastPathComponent }
    /// The front matter title, or the file name.
    var title: String { frontMatterTitle ?? fileName }
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

    private func startWatching() {
        watcher = FileWatcher(url: url) { [weak self] in
            guard let self else { return }
            self.load()
            self.onChange?()
        }
    }

    /// UTF-8 first; UTF-16 only with a byte-order mark; then Windows-1252 / Latin-1 for old files.
    private static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
            let s = String(data: data, encoding: .utf16)
        {
            return s
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
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
            text = Self.decode(try Data(contentsOf: url))
            error = nil
            wordCount = Self.countWords(text)
            tasks = Self.countTasks(text)
            frontMatterTitle = Self.frontMatterTitle(text)
            modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                self.error = "\(url.path) was moved or deleted."
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}
