import SwiftUI
import UniformTypeIdentifiers

/// Editor-style tab strip: click to switch, drag to reorder, right-click for more.
struct TabBar: View {
    @EnvironmentObject private var state: AppState
    // Redraw the sepia or system background when the theme changes.
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(state.tabs) { tab in
                        TabItem(
                            tab: tab,
                            detail: disambiguation(for: tab),
                            isSelected: tab.id == state.selectedID,
                            isMissing: tab.error != nil
                        )
                        .id(tab.id)
                    }
                }
            }
            .onChange(of: state.selectedID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .frame(height: 34)
        .background(Color(nsColor: Palette.chrome))
    }

    /// When two tabs share a name, show the parent folder (or the file name, for two front matter
    /// titles in one folder) so they can be told apart.
    private func disambiguation(for tab: DocTab) -> String? {
        let folder = tab.url.deletingLastPathComponent()
        let clashes = state.tabs.filter { $0.id != tab.id && $0.title == tab.title }
        guard !clashes.isEmpty else { return nil }
        if tab.frontMatterTitle != nil, clashes.contains(where: { $0.url.deletingLastPathComponent() == folder }) {
            return tab.fileName
        }
        return folder.lastPathComponent
    }
}

private struct TabItem: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue
    let tab: DocTab
    let detail: String?
    let isSelected: Bool
    let isMissing: Bool
    @State private var hovering = false
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.showSource && !tab.editing ? "chevron.left.forwardslash.chevron.right" : "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .overlay(alignment: .topTrailing) {
                    // The file changed on disk while another tab was showing.
                    if tab.changedInBackground {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 3, y: -2)
                    }
                }
            Text(tab.title)
                .strikethrough(isMissing)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
            if let detail {
                Text(detail).lineLimit(1).foregroundStyle(.tertiary)
            }
            CloseButton(dirty: tab.isDirty) { state.close(tab.id) }
                .opacity(hovering || isSelected || tab.isDirty ? 1 : 0)
        }
        .font(.system(size: 12))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 110, maxWidth: 240, minHeight: 34, maxHeight: 34)
        .background(background)
        .overlay(alignment: .top) {
            if isSelected { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay {
            if dropTarget { Rectangle().fill(Color.accentColor.opacity(0.12)) }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.selectedID = tab.id }
        .overlay { MiddleClick { state.close(tab.id) } }
        .help(tab.url.path)
        .onDrag {
            // The file itself for Finder, Mail and other apps; the tab id for reordering here.
            let provider = NSItemProvider(contentsOf: tab.url) ?? NSItemProvider()
            provider.suggestedName = tab.fileName
            provider.registerObject(tab.id.uuidString as NSString, visibility: .ownProcess)
            return provider
        }
        .onDrop(of: [.text], isTargeted: $dropTarget) { providers in
            _ = providers.first?.loadObject(ofClass: NSString.self) { value, _ in
                guard let s = value as? String, let id = UUID(uuidString: s) else { return }
                DispatchQueue.main.async { state.moveTab(id, before: tab.id) }
            }
            return true
        }
        .contextMenu {
            Button("Close Tab") { state.close(tab.id) }
            Button("Close Other Tabs") { state.closeOthers(tab.id) }
                .disabled(state.tabs.count < 2)
            Button("Close Tabs to the Right") { state.closeToRight(tab.id) }
                .disabled(state.tabs.last?.id == tab.id)
            Divider()
            Button("Rename…") { state.rename(tab) }
                .disabled(tab.isUntitled)
            Button("Duplicate") { state.duplicate(tab) }
                .disabled(tab.isUntitled)
            Button("Reveal in Finder") { state.revealInFinder(tab) }
            Button("Copy Path") { state.copyPath(tab) }
        }
    }

    private var background: Color {
        if isSelected { return Color(nsColor: Palette.page) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}

/// Catches middle clicks (to close the tab) and lets every other click through.
private struct MiddleClick: NSViewRepresentable {
    let action: () -> Void

    final class View: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            let type = NSApp.currentEvent?.type
            return type == .otherMouseDown || type == .otherMouseUp ? super.hitTest(point) : nil
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.action = action
        return view
    }

    func updateNSView(_ view: View, context: Context) { view.action = action }
}

private struct CloseButton: View {
    /// Unsaved changes: a dot, which turns into the close button on hover.
    var dirty = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: dirty && !hovering ? "circle.fill" : "xmark")
                .font(.system(size: dirty && !hovering ? 7 : 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(dirty ? "Unsaved changes. Close Tab (⌘W)" : "Close Tab (⌘W)")
    }
}
