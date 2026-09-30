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
    /// Called after the file's contents change on disk.
    var onChange: (() -> Void)?
    private var watcher: FileWatcher?

    var title: String { url.lastPathComponent }

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

    private func load() {
        do {
            text = Self.decode(try Data(contentsOf: url))
            error = nil
            wordCount = Self.countWords(text)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                self.error = "\(url.path) was moved or deleted."
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}
