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
    private(set) var wordCount = 0
    /// Called after the file's contents change on disk.
    var onChange: (() -> Void)?
    private var watcher: FileWatcher?

    var title: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url.standardizedFileURL
        load()
        watcher = FileWatcher(url: self.url) { [weak self] in
            self?.load()
            self?.onChange?()
        }
    }

    func reload() {
        load()
        onChange?()
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
            let data = try Data(contentsOf: url)
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(decoding: data, as: UTF8.self)
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
