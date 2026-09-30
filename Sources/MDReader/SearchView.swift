import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case tabs, folder
    var id: String { rawValue }
    var label: String { self == .tabs ? "Open Tabs" : "This Folder" }
}

struct SearchHit: Identifiable {
    let id: Int
    /// Which match in the file this is, counting from 0, for jumping to it with Find.
    let occurrence: Int
    let before: String
    let match: String
    let after: String
}

struct SearchGroup: Identifiable {
    let url: URL
    let hits: [SearchHit]
    /// Matches left out of `hits`.
    let more: Int
    var id: URL { url }
    var total: Int { hits.count + more }
}

/// Text search across open tabs or the Markdown files in the current folder.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { run() } }
    }
    @Published var scope = SearchScope(rawValue: UserDefaults.standard.string(forKey: Prefs.searchScope) ?? "") ?? .tabs {
        didSet {
            UserDefaults.standard.set(scope.rawValue, forKey: Prefs.searchScope)
            if scope != oldValue { run(delay: 0) }
        }
    }
    @Published private(set) var groups: [SearchGroup] = []
    @Published private(set) var searching = false
    /// Changed to move keyboard focus to the search field.
    @Published var focusToken = UUID()

    private var task: Task<Void, Never>?
    nonisolated private static let perFile = 100
    nonisolated private static let totalLimit = 1000

    func run(delay: Double = 0.2) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            groups = []
            searching = false
            return
        }
        let state = AppState.shared
        // Open tabs are searched as they are in memory; folder files are read from disk.
        let sources: [(URL, String?)] = scope == .tabs
            ? state.tabs.map { ($0.url, $0.text) }
            : state.folderFiles.map { url in (url, state.tabs.first { $0.url == url }?.text) }
        task = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            searching = true
            let result = await Task.detached(priority: .userInitiated) { Self.search(q, in: sources) }.value
            guard !Task.isCancelled else { return }
            groups = result
            searching = false
        }
    }

    nonisolated private static func search(_ query: String, in sources: [(URL, String?)]) -> [SearchGroup] {
        var groups: [SearchGroup] = []
        var total = 0
        for (url, loaded) in sources {
            if Task.isCancelled { return [] }
            guard let text = loaded ?? read(url) else { continue }
            var hits: [SearchHit] = []
            var count = 0
            text.enumerateLines { line, _ in
                var from = line.startIndex
                while let range = line.range(of: query, options: .caseInsensitive, range: from..<line.endIndex) {
                    if hits.count < perFile && total < totalLimit {
                        hits.append(snippet(line, range, id: count))
                        total += 1
                    }
                    count += 1
                    from = range.upperBound
                }
            }
            if count > 0 { groups.append(SearchGroup(url: url, hits: hits, more: count - hits.count)) }
        }
        return groups
    }

    nonisolated private static func read(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            (values.fileSize ?? 0) <= MarkdownFiles.maxFileSize,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func snippet(_ line: String, _ range: Range<String.Index>, id: Int) -> SearchHit {
        var before = line[line.startIndex..<range.lowerBound].drop { $0 == " " || $0 == "\t" }
        if before.count > 40 { before = "…" + before.suffix(40) }
        var after = line[range.upperBound...]
        if after.count > 100 { after = after.prefix(100) + "…" }
        return SearchHit(id: id, occurrence: id, before: String(before), match: String(line[range]), after: String(after))
    }
}

struct SearchView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 10)

            Picker("", selection: $model.scope) {
                ForEach(SearchScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 10)

            results
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            focused = true
            model.run(delay: 0)
        }
        .onChange(of: model.focusToken) { _ in focused = true }
    }

    @ViewBuilder
    private var results: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if model.groups.isEmpty {
            Text(model.searching ? "Searching…" : "No results")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
        } else {
            let total = model.groups.reduce(0) { $0 + $1.total }
            Text("\(total) \(total == 1 ? "result" : "results") in \(model.groups.count) \(model.groups.count == 1 ? "file" : "files")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            ScrollView {
                // Not lazy: rows vary in height, and a lazy stack leaves gaps while it measures them.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.groups) { group in
                        header(group)
                        ForEach(group.hits) { hit in row(hit, in: group) }
                        if group.more > 0 {
                            Text("\(group.more) more")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 22)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
    }

    private func header(_ group: SearchGroup) -> some View {
        Button {
            state.open([group.url])
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(group.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(group.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.url.path)
    }

    private func row(_ hit: SearchHit, in group: SearchGroup) -> some View {
        Button {
            state.openSearchResult(group.url, query: model.query, occurrence: hit.occurrence)
        } label: {
            (Text(hit.before) + Text(hit.match).bold().foregroundColor(.primary) + Text(hit.after))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 22)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
