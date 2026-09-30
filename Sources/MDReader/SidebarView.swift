import SwiftUI

/// Left sidebar: the document outline, or the Markdown files in the same folder.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.sidebarPane) {
                Text("Outline").tag(SidebarPane.outline)
                Text("Files").tag(SidebarPane.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            switch state.sidebarPane {
            case .outline: OutlineView()
            case .files: FilesView()
            }
        }
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct FilesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.folderFiles.isEmpty {
            Text("No Markdown files")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(state.folderFiles, id: \.self) { url in
                        row(url)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
    }

    private func row(_ url: URL) -> some View {
        let current = url == state.selected?.url
        let open = state.tabs.contains { $0.url == url }
        return Button {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(current ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.lastPathComponent)
    }
}
