import SwiftUI

enum PaletteMode {
    /// ⌘P: open tabs, recent files and files in the current folder.
    case files
    /// ⇧⌘J: headings of the current document.
    case headings
}

/// Type-to-filter list for Quick Open and Jump to Heading.
struct PaletteView: View {
    @EnvironmentObject private var state: AppState
    let mode: PaletteMode
    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private struct Entry: Hashable {
        let id: String
        let title: String
        let detail: String
        let indent: Int
        let isOpen: Bool
    }

    private static let rowHeight: CGFloat = 30

    private var entries: [Entry] {
        switch mode {
        case .files:
            let open = Set(state.tabs.map(\.url.path))
            return state.quickOpenCandidates.map { url in
                Entry(
                    id: url.path, title: url.lastPathComponent,
                    detail: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                    indent: 0, isOpen: open.contains(url.path))
            }
        case .headings:
            let top = state.outline.map(\.level).min() ?? 1
            return state.outline.map {
                Entry(id: $0.id, title: $0.text, detail: "", indent: $0.level - top, isOpen: false)
            }
        }
    }

    private var results: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = entries
        guard !q.isEmpty else { return Array(all.prefix(mode == .files ? 50 : 500)) }
        return all.enumerated()
            .compactMap { index, entry -> (Entry, Int, Int)? in
                let folder = (entry.detail as NSString).lastPathComponent
                guard let score = Self.score(entry.title, q)
                    ?? (mode == .files ? Self.score("\(folder)/\(entry.title)", q).map { $0 - 10 } : nil)
                else { return nil }
                return (entry, score, index)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .prefix(50)
            .map(\.0)
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            TextField(mode == .files ? "Open file" : "Jump to heading", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(12)
                .focused($focused)
            Divider()
            if items.isEmpty {
                Text(mode == .headings && state.outline.isEmpty ? "No headings" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element) { index, entry in
                                row(entry, selected: index == selection)
                                    .onTapGesture { activate(entry) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(items.count) * Self.rowHeight + 12, 320))
                    .onChange(of: selection) { index in
                        if items.indices.contains(index) { proxy.scrollTo(items[index]) }
                    }
                }
            }
        }
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .onChange(of: query) { _ in selection = 0 }
        .onAppear {
            focused = true
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === state.reader.webView.window,
                    (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true
                else { return event }
                return handleKey(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            DispatchQueue.main.async { state.focusReader() }
        }
    }

    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mode == .headings ? "number" : entry.isOpen ? "doc.text.fill" : "doc.text")
                .foregroundStyle(selected ? .white : .secondary)
            Text(entry.title)
                .foregroundStyle(selected ? .white : .primary)
                .lineLimit(1)
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + CGFloat(min(entry.indent, 4)) * 14)
        .padding(.trailing, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    /// Arrow keys move the selection, Return opens, Escape closes.
    private func handleKey(_ event: NSEvent) -> Bool {
        let items = results
        switch event.keyCode {
        case 125:  // down
            if !items.isEmpty { selection = min(selection + 1, items.count - 1) }
        case 126:  // up
            selection = max(selection - 1, 0)
        case 36, 76:  // return, enter
            if items.indices.contains(selection) { activate(items[selection]) }
        case 53:  // escape
            state.palette = nil
        default:
            return false
        }
        return true
    }

    private func activate(_ entry: Entry) {
        state.palette = nil
        switch mode {
        case .files: state.open([URL(fileURLWithPath: entry.id)])
        case .headings: state.scrollToHeading(entry.id)
        }
    }

    /// Characters of `query` must appear in order in `text`; consecutive runs, word starts and a
    /// matching prefix score higher. Returns nil when it doesn't match.
    static func score(_ text: String, _ query: String) -> Int? {
        let t = Array(text.lowercased())
        let q = Array(query.lowercased())
        var score = 0
        var qi = 0
        var last = -2
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += i == last + 1 ? 5 : 1
            if i == 0 || " -_./".contains(t[i - 1]) { score += 4 }
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        if text.lowercased().hasPrefix(query.lowercased()) { score += 20 }
        return score - t.count / 8
    }
}
