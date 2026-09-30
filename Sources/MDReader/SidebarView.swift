import SwiftUI

/// Left sidebar: the document outline, the Markdown files in the same folder, or search.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(Prefs.sidebarWidth) private var width = 230.0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.sidebarPane) {
                Text("Outline").tag(SidebarPane.outline)
                Text("Files").tag(SidebarPane.files)
                Text("Search").tag(SidebarPane.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            switch state.sidebarPane {
            case .outline: OutlineView()
            case .files: FilesView()
            case .search: SearchView(model: state.search)
            }
        }
        .frame(width: state.sidebarDragWidth ?? width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: Palette.chrome))
    }
}

struct FilesView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Prefs.filesSort) private var sort = "name"
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain)
                Menu {
                    Picker("Sort By", selection: $sort) {
                        Text("Name").tag("name")
                        Text("Date Modified").tag("date")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 10)

            if state.folderFiles.isEmpty && state.folderSubfolders.isEmpty {
                Text("No Markdown files")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(state.folderSubfolders, id: \.self) { folder in
                            FolderRow(folder: folder, depth: 0, filter: filter, sort: sort)
                        }
                        ForEach(matching(state.folderFiles), id: \.self) { url in
                            FileRow(url: url, depth: 0)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func matching(_ files: [URL]) -> [URL] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? files : files.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(q) }
    }
}

/// A subfolder; its contents are read only when it's expanded.
private struct FolderRow: View {
    let folder: URL
    let depth: Int
    let filter: String
    let sort: String
    @State private var expanded = false
    @State private var listing: (folders: [URL], files: [URL]) = ([], [])

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                expanded.toggle()
                if expanded { listing = AppState.listing(of: folder, sort: sort) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(folder.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 14 + 2)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folder.path)
            if expanded {
                ForEach(listing.folders, id: \.self) { sub in
                    FolderRow(folder: sub, depth: depth + 1, filter: filter, sort: sort)
                }
                let q = filter.trimmingCharacters(in: .whitespaces)
                ForEach(listing.files.filter { q.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(q) },
                    id: \.self) { url in
                    FileRow(url: url, depth: depth + 1)
                }
                if listing.folders.isEmpty && listing.files.isEmpty {
                    Text("No Markdown files")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(depth + 1) * 14 + 22)
                        .padding(.vertical, 2)
                }
            }
        }
        .onChange(of: sort) { _ in
            if expanded { listing = AppState.listing(of: folder, sort: sort) }
        }
    }
}

private struct FileRow: View {
    @EnvironmentObject private var state: AppState
    let url: URL
    let depth: Int

    var body: some View {
        let current = url == state.selected?.url
        let open = state.tabs.contains { $0.url == url }
        Button {
            state.open([url])
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(current ? Color.accentColor : .secondary)
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12, weight: open ? .medium : .regular))
                    .foregroundStyle(current ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14 + (depth > 0 ? 16 : 0))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(current ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.lastPathComponent)
    }
}
