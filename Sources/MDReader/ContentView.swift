import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var status = AppState.shared.status
    // Redraw page-coloured chrome when switching between Light and Sepia (same system appearance).
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(Prefs.checkForUpdates) private var checkForUpdates = true
    @AppStorage(Prefs.editPreview) private var editPreview = true

    var body: some View {
        VStack(spacing: 0) {
            if !state.tabs.isEmpty && !state.focusMode {
                TabBar()
                Divider()
            }
            HStack(spacing: 0) {
                if state.sidebarVisible && !state.tabs.isEmpty && !state.focusMode {
                    SidebarView()
                        .transition(.move(edge: .leading))
                    SidebarResizer()
                }
                reader
            }
            .animation(.easeOut(duration: 0.18), value: state.sidebarVisible)
        }
        .overlay(alignment: .top) {
            if let mode = state.palette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { state.palette = nil }
                    PaletteView(mode: mode).id(mode).padding(.top, 50)
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
        .toolbar(state.focusMode ? .hidden : .visible, for: .windowToolbar)
        .toolbarBackground(Color(nsColor: Palette.chrome), for: .windowToolbar)
        .toolbarBackground(appearance == AppearanceMode.sepia.rawValue ? .visible : .automatic, for: .windowToolbar)
        .animation(.easeOut(duration: 0.18), value: state.focusMode)
    }

    private var reader: some View {
        GeometryReader { geo in
            // While editing with the preview on: editor on the left, rendered page on the right.
            let split = editing && editPreview
            let half = (geo.size.width / 2).rounded()
            ZStack(alignment: .topLeading) {
                Color(nsColor: Palette.page)
                WebViewHost(webView: state.reader.webView)
                    .opacity(state.tabs.isEmpty ? 0 : 1)
                    .frame(width: split ? geo.size.width - half : geo.size.width, height: geo.size.height)
                    .offset(x: split ? half : 0)
                if editing {
                    EditorHost(editor: state.editor)
                        .frame(width: split ? half : geo.size.width, height: geo.size.height)
                    if split {
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: 1, height: geo.size.height)
                            .offset(x: half)
                    }
                }
                overlays
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

    @ViewBuilder
    private var overlays: some View {
        ZStack(alignment: .top) {
            Color.clear
            if state.tabs.isEmpty {
                EmptyStateView()
            }
            if state.findVisible && !state.tabs.isEmpty && state.selected?.editing != true {
                HStack {
                    Spacer()
                    FindBar()
                }
                .padding(10)
            }
        }
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
            if let update = state.availableUpdate, checkForUpdates {
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
            .disabled(state.selected == nil || editing)

            Menu {
                Button("Find in Document") { state.showFind() }
                Button("Search Open Tabs") { state.search.scope = .tabs; state.showSearch() }
                Button("Search This Folder") { state.search.scope = .folder; state.showSearch() }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            } primaryAction: {
                state.showFind()
            }
            .help("Find (⌘F). Click and hold to search open tabs or the folder.")
            .disabled(state.selected == nil)

            Button {
                state.edit()
            } label: {
                if editing {
                    Label("Done", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Edit", systemImage: "pencil")
                }
            }
            .help(editing ? "Stop editing (⌥⌘O)" : state.editorName.map { "Edit in \($0) (⌥⌘O)" } ?? "Edit (⌥⌘O)")
            .disabled(state.selected == nil)

            if let url = state.selected?.url {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share")
            }

            Menu {
                Button("Export as PDF…") { state.exportPDF() }
                Button("Export as HTML…") { state.exportHTML() }
                Button("Export as Word…") { state.exportDocument(word: true) }
                Button("Export as RTF…") { state.exportDocument(word: false) }
                Button("Copy as Rich Text") { state.copyRichText() }
                Divider()
                Button("Print…") { state.printDocument() }
            } label: {
                Label("Export", systemImage: "arrow.down.doc")
            } primaryAction: {
                state.exportPDF()
            }
            .help("Export as PDF (⌘E)")
            .disabled(state.selected == nil || editing)
        }
    }

    private var showingSource: Bool { state.selected?.showSource ?? false }
    private var editing: Bool { state.selected?.editing ?? false }

    private static func modifiedText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Modified \(date.formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInYesterday(date) { return "Modified yesterday" }
        let thisYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return "Modified " + date.formatted(thisYear ? .dateTime.day().month() : .dateTime.day().month().year())
    }

    private var subtitle: String {
        guard let tab = state.selected else { return "" }
        // A new document lives in a temporary folder until it's saved; don't show that path.
        let folder = tab.isUntitled
            ? "Not saved yet" : (tab.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let selection = status.selectionWords > 0
            ? "\(status.selectionWords.formatted()) \(status.selectionWords == 1 ? "word" : "words") selected" : nil
        if tab.editing {
            return "\(folder) — Editing" + (tab.isDirty ? ", not saved" : "") + (selection.map { " · \($0)" } ?? "")
        }
        if tab.showSource { return "\(folder) — Markdown" }
        guard tab.error == nil else { return folder }
        var parts = [folder]
        if let selection {
            parts.append(selection)
        } else if tab.wordCount > 0 {
            let minutes = max(1, Int((Double(tab.wordCount) / 230).rounded()))
            parts.append("\(tab.wordCount.formatted()) words")
            parts.append(status.minutesLeft.map { "\($0) min left" } ?? "\(minutes) min read")
        }
        if tab.tasks.total > 0 { parts.append("\(tab.tasks.done) of \(tab.tasks.total) tasks done") }
        if let modified = tab.modified { parts.append(Self.modifiedText(modified)) }
        return parts.joined(separator: " · ")
    }
}

/// The sidebar's right edge; drag it to change the sidebar's width.
struct SidebarResizer: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Prefs.sidebarWidth) private var width = 230.0
    @State private var startWidth: Double?
    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        updateCursor()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = startWidth ?? width
                                startWidth = start
                                // Saved when the drag ends; writing settings on every frame is slow.
                                state.sidebarDragWidth = min(max(start + drag.translation.width, 170), 480)
                                updateCursor()
                            }
                            .onEnded { _ in
                                if let dragged = state.sidebarDragWidth { width = dragged }
                                state.sidebarDragWidth = nil
                                startWidth = nil
                                updateCursor()
                            }
                    )
            }
            .onDisappear {
                hovering = false
                startWidth = nil
                updateCursor()
            }
    }

    /// One push while hovering or dragging, one pop after.
    private func updateCursor() {
        let want = hovering || startWidth != nil
        if want && !cursorPushed { NSCursor.resizeLeftRight.push() }
        if !want && cursorPushed { NSCursor.pop() }
        cursorPushed = want
    }
}

/// Hosts the long-lived web view owned by `ReaderController`.
struct WebViewHost: NSViewRepresentable {
    let webView: ReaderWebView
    func makeNSView(context: Context) -> ReaderWebView {
        DispatchQueue.main.async {
            AppState.shared.focusReader()
            if let window = webView.window { WindowCloseGuard.shared.install(on: window) }
        }
        return webView
    }
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
    /// Set while a search result is shown, so the query change and re-render don't reset the match.
    @State private var requestedQuery: String?
    @State private var requestGeneration = -1

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onChange(of: query) { q in
                    state.lastFindQuery = q
                    if q == requestedQuery { return requestedQuery = nil }
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
        .onAppear {
            if state.findRequest != nil {
                apply(state.findRequest)
            } else {
                focused = true
                if query.isEmpty { query = state.lastFindQuery }
            }
        }
        .onChange(of: state.findRequest) { apply($0) }
        .onReceive(NotificationCenter.default.publisher(for: .findNext)) { note in
            focused = true
            if let dir = note.object as? Int { step(dir) }
        }
        .onChange(of: state.renderGeneration) { generation in
            // The page was re-rendered (tab switch, reload, source toggle); search the new content.
            guard generation != requestGeneration else { return }
            state.reader.find(query, scroll: false) { c, t in current = c; total = t }
        }
    }

    private func apply(_ request: FindRequest?) {
        guard let request else { return }
        state.findRequest = nil
        requestGeneration = state.renderGeneration
        if query != request.query { requestedQuery = request.query }
        query = request.query
        state.reader.find(request.query, index: request.index) { c, t in current = c; total = t }
    }

    private func step(_ direction: Int) {
        state.reader.findStep(direction) { c, t in current = c; total = t }
    }

    private func close() {
        state.reader.clearFind()
        state.findVisible = false
        DispatchQueue.main.async { state.focusReader() }
    }
}

extension Notification.Name {
    static let findNext = Notification.Name("MDReaderFindNext")
}
