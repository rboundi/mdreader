import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    // Redraw page-coloured chrome when switching between Light and Sepia (same system appearance).
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            if !state.tabs.isEmpty {
                TabBar()
                Divider()
            }
            HStack(spacing: 0) {
                if state.sidebarVisible && !state.tabs.isEmpty {
                    SidebarView()
                        .transition(.move(edge: .leading))
                    Divider()
                }
                reader
            }
            .animation(.easeOut(duration: 0.18), value: state.sidebarVisible)
        }
        .overlay(alignment: .top) {
            if state.quickOpenVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { state.quickOpenVisible = false }
                    QuickOpenView().padding(.top, 50)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { state.open([url]) } }
                }
            }
            return true
        }
        .navigationTitle(state.selected?.title ?? "MDReader")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    private var reader: some View {
        ZStack(alignment: .top) {
            Color(nsColor: Palette.page)
            WebViewHost(webView: state.reader.webView)
                .opacity(state.tabs.isEmpty ? 0 : 1)
            if state.tabs.isEmpty {
                EmptyStateView()
            }
            if state.findVisible && !state.tabs.isEmpty {
                HStack {
                    Spacer()
                    FindBar()
                }
                .padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(toast: toast).padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.toast)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                state.toggleSidebar()
            } label: {
                Label("Sidebar", systemImage: "sidebar.left")
            }
            .help("Sidebar")
            .disabled(state.selected == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let update = state.availableUpdate {
                Button {
                    NSWorkspace.shared.open(update.url)
                } label: {
                    Text("Update available")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("MDReader \(update.version) is available")
            }

            Button {
                state.toggleSource()
            } label: {
                Label(
                    showingSource ? "Show Rendered" : "Show Markdown",
                    systemImage: showingSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
            }
            .help(showingSource ? "Show rendered view (⌘/)" : "Show Markdown source (⌘/)")
            .disabled(state.selected == nil)

            Menu {
                Button("Export as PDF…") { state.exportPDF() }
                Button("Export as HTML…") { state.exportHTML() }
                Button("Copy as Rich Text") { state.copyRichText() }
                Divider()
                Button("Print…") { state.printDocument() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            } primaryAction: {
                state.exportPDF()
            }
            .help("Export as PDF (⌘E)")
            .disabled(state.selected == nil)
        }
    }

    private var showingSource: Bool { state.selected?.showSource ?? false }

    private var subtitle: String {
        guard let tab = state.selected else { return "" }
        let folder = (tab.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        if tab.showSource { return "\(folder) — Markdown" }
        guard tab.error == nil, tab.wordCount > 0 else { return folder }
        let words = tab.wordCount.formatted()
        let minutes = max(1, Int((Double(tab.wordCount) / 230).rounded()))
        return "\(folder) · \(words) words · \(minutes) min read"
    }
}

/// Hosts the long-lived web view owned by `ReaderController`.
struct WebViewHost: NSViewRepresentable {
    let webView: ReaderWebView
    func makeNSView(context: Context) -> ReaderWebView { webView }
    func updateNSView(_ nsView: ReaderWebView, context: Context) {}
}

struct EmptyStateView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Drop a Markdown file here")
                .font(.title3.weight(.medium))
            Text("or press ⌘O to open one")
                .foregroundStyle(.secondary)
            Button("Open…") { state.showOpenPanel() }
                .controlSize(.large)
                .padding(.top, 4)
            if !state.recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.recents.prefix(5), id: \.self) { url in
                        Button {
                            state.open([url])
                        } label: {
                            Label(url.lastPathComponent, systemImage: "doc.text")
                        }
                        .buttonStyle(.link)
                        .help(url.path)
                    }
                }
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ToastView: View {
    @EnvironmentObject private var state: AppState
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message).lineLimit(1)
            if let url = toast.revealURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    state.toast = nil
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

struct FindBar: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var current = 0
    @State private var total = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onChange(of: query) { q in
                    state.reader.find(q) { c, t in current = c; total = t }
                }
            Text(query.isEmpty ? "" : total == 0 ? "No results" : "\(current) of \(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(total == 0)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(total == 0)
            Button { close() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .findNext)) { note in
            focused = true
            if let dir = note.object as? Int { step(dir) }
        }
        .onChange(of: state.renderGeneration) { _ in
            // The page was re-rendered (tab switch, reload, source toggle); search the new content.
            state.reader.find(query) { c, t in current = c; total = t }
        }
    }

    private func step(_ direction: Int) {
        state.reader.findStep(direction) { c, t in current = c; total = t }
    }

    private func close() {
        state.reader.clearFind()
        state.findVisible = false
    }
}

extension Notification.Name {
    static let findNext = Notification.Name("MDReaderFindNext")
}
