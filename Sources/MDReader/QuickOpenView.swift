import SwiftUI

/// ⌘P: type part of a file name to jump to an open tab, a recent file or a file in the current folder.
struct QuickOpenView: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private var results: [URL] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let candidates = state.quickOpenCandidates
        guard !q.isEmpty else { return Array(candidates.prefix(50)) }
        return candidates.enumerated()
            .compactMap { index, url -> (URL, Int, Int)? in
                let name = url.lastPathComponent
                let folder = url.deletingLastPathComponent().lastPathComponent
                guard let score = Self.score(name, q) ?? Self.score("\(folder)/\(name)", q).map({ $0 - 10 })
                else { return nil }
                return (url, score, index)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .prefix(50)
            .map(\.0)
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            TextField("Open file", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(12)
                .focused($focused)
            Divider()
            if items.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element) { index, url in
                                row(url, selected: index == selection)
                                    .onTapGesture { open(url) }
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
        }
    }

    private static let rowHeight: CGFloat = 30

    private func row(_ url: URL, selected: Bool) -> some View {
        let isOpen = state.tabs.contains { $0.url == url }
        return HStack(spacing: 8) {
            Image(systemName: isOpen ? "doc.text.fill" : "doc.text")
                .foregroundStyle(selected ? .white : .secondary)
            Text(url.lastPathComponent)
                .foregroundStyle(selected ? .white : .primary)
                .lineLimit(1)
            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    /// Arrow keys move the selection, Return opens, Escape closes.
    private func handleKey(_ event: NSEvent) -> Bool {
        let count = results.count
        switch event.keyCode {
        case 125:  // down
            if count > 0 { selection = min(selection + 1, count - 1) }
        case 126:  // up
            selection = max(selection - 1, 0)
        case 36, 76:  // return, enter
            let items = results
            if items.indices.contains(selection) { open(items[selection]) }
        case 53:  // escape
            state.quickOpenVisible = false
        default:
            return false
        }
        return true
    }

    private func open(_ url: URL) {
        state.quickOpenVisible = false
        state.open([url])
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
