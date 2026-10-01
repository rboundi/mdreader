import AppKit
import UniformTypeIdentifiers

enum SidebarPane: String {
    case outline, files, search
}

/// Asks the find bar to search for `query` and select its `index`th match.
struct FindRequest: Equatable {
    let id = UUID()
    let query: String
    let index: Int
}

struct Toast: Equatable {
    let id = UUID()
    let message: String
    var revealURL: URL?
}

@MainActor
final class ReadingStatus: ObservableObject {
    /// Words in the current selection.
    @Published var selectionWords = 0
    /// Reading time left; nil at the top or bottom of the page.
    @Published var minutesLeft: Int?
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var tabs: [DocTab] = []
    @Published var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            // While restoring, only the finally selected tab is rendered (see restoreTabs).
            if !restoring {
                reader.display(selected)
                selected?.changedInBackground = false
                status.selectionWords = 0
                status.minutesLeft = nil
                // A tab left in the editor follows the current preview setting.
                if let tab = selected, tab.editing, tab.showSource == previewWhileEditing {
                    tab.showSource = !previewWhileEditing
                    reader.display(tab)
                }
                if let tab = selected, tab.editing {
                    editor.show(tab)
                    editor.prepare(offset: nil)
                } else {
                    // After the editor (if the last tab was being edited) has left the window.
                    let wasEditing = tabs.first { $0.id == oldValue }?.editing == true
                    DispatchQueue.main.async { self.focusReader(force: wasEditing) }
                }
            }
            persistTabs()
            refreshFolder()
        }
    }
    @Published private(set) var recents: [URL] = []
    @Published var toast: Toast?
    @Published var findVisible = false
    @Published var findRequest: FindRequest?
    @Published private(set) var outline: [OutlineItem] = []
    @Published private(set) var activeHeading: String?
    @Published var sidebarVisible = UserDefaults.standard.bool(forKey: Prefs.outlineVisible) {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: Prefs.outlineVisible) }
    }
    @Published var sidebarPane =
        SidebarPane(rawValue: UserDefaults.standard.string(forKey: Prefs.sidebarPane) ?? "") ?? .outline
    {
        didSet { UserDefaults.standard.set(sidebarPane.rawValue, forKey: Prefs.sidebarPane) }
    }
    /// Markdown files in the current document's folder, for the Files sidebar and Quick Open.
    @Published private(set) var folderFiles: [URL] = []
    @Published var palette: PaletteMode?
    @Published var focusMode = false
    /// Sidebar width while its edge is being dragged.
    @Published var sidebarDragWidth: Double?
    /// Selection word count and time left. Kept apart so their frequent changes redraw only the
    /// title bar, not the menus and the whole window.
    let status = ReadingStatus()
    /// Subfolders of the current document's folder, for the Files sidebar.
    @Published private(set) var folderSubfolders: [URL] = []
    private var filesSort = UserDefaults.standard.string(forKey: Prefs.filesSort) ?? "name"
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var availableUpdate: UpdateChecker.Release?
    @Published private(set) var closedTabs: [URL] = []
    /// Bumped whenever the page is re-rendered, so the find bar can search the new content.
    @Published private(set) var renderGeneration = 0

    let reader = ReaderController()
    let search = SearchModel()
    let editor = EditorController()

    private struct Position {
        let url: URL
        let y: Double
    }
    private var backStack: [Position] = []
    private var forwardStack: [Position] = []
    private var folderWatcher: FileWatcher?
    private var watchedFolder: URL?
    /// Collapsed sections per file path, kept across launches.
    private var foldMemory = UserDefaults.standard.dictionary(forKey: Prefs.foldMemory) as? [String: [String]] ?? [:]
    /// Last scroll position per file path, kept across launches: path → [y, time saved].
    private var scrollMemory =
        UserDefaults.standard.dictionary(forKey: Prefs.scrollMemory) as? [String: [Double]] ?? [:]

    var selected: DocTab? { tabs.first { $0.id == selectedID } }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    private init() {
        recents = (UserDefaults.standard.stringArray(forKey: Prefs.recentFiles) ?? [])
            .map { URL(fileURLWithPath: $0) }
        reader.onOpenFile = { [weak self] url, anchor, y, background in
            guard let self else { return }
            // Back returns here after following a link, also for a ⌘-click that jumps within this file.
            let sameFile = MarkdownFiles.canonical(url) == self.selected?.url
            if !background || sameFile, MarkdownFiles.canOpen(url.standardizedFileURL) { self.recordPosition(y: y) }
            self.open([url], anchor: anchor, activate: !background)
        }
        reader.onToggleTask = { [weak self] path, index, shown in
            self?.toggleTask(index, shown: shown, path: path)
        }
        reader.onNavigate = { [weak self] y in self?.recordPosition(y: y) }
        reader.webView.onCopyHeadingLink = { [weak self] id in self?.copyLink(toHeading: id) }
        reader.webView.onSwipe = { [weak self] direction in
            if direction < 0 { self?.goBack() } else { self?.goForward() }
        }
        reader.webView.swipeDirections = { [weak self] in (self?.canGoBack ?? false, self?.canGoForward ?? false) }
        reader.onOutline = { [weak self] items in
            if self?.outline != items { self?.outline = items }
        }
        reader.onActiveHeading = { [weak self] id in
            if self?.activeHeading != id { self?.activeHeading = id }
        }
        reader.webView.onDropFiles = { [weak self] urls in self?.open(urls) }
        reader.onDisplay = { [weak self] in self?.renderGeneration += 1 }
        reader.foldsFor = { [weak self] url in self?.foldMemory[url.path] ?? [] }
        reader.onFolds = { [weak self] ids in self?.rememberFolds(ids) }
        reader.webView.onCopyDiagram = { [weak self] index in self?.reader.copyDiagram(index) }
        reader.webView.onSaveDiagram = { [weak self] index, svg in self?.reader.saveDiagram(index, asSVG: svg) }
        editor.onDirtyChange = { [weak self] in self?.objectWillChange.send() }
        reader.onProgress = { [weak self] progress in self?.updateTimeLeft(progress) }
        reader.diagramsInUse = { [weak self] in
            self?.tabs.contains { $0.displayText.contains("```mermaid") || $0.displayText.contains("~~~mermaid") } ?? false
        }
        reader.onSelectionWords = { [weak self] words in self?.setSelectionWords(words) }
        editor.onSelectionWords = { [weak self] words in self?.setSelectionWords(words) }
        reader.webView.onCopyTable = { [weak self] index, csv in self?.reader.copyTable(index, csv: csv) }
        // The preview beside the editor follows the editor's scrolling.
        editor.onScroll = { [weak self] offset in
            guard let self, self.selected?.editing == true, self.previewWhileEditing else { return }
            self.reader.showOffset(offset)
        }
        // Keeps the outline (drawn from the page underneath) in step with the draft.
        editor.onTextChange = { [weak self] tab in
            if tab.id == self?.selectedID { self?.reader.display(tab) }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.editor.themeMayHaveChanged()
                self?.filesSortMayHaveChanged()
            }
        }
    }

    // MARK: Opening & closing

    /// Opens files as tabs (or focuses them if already open). `anchor` jumps to a heading id.
    /// `scroll` restores a position (Back/Forward); otherwise new tabs reopen where you left the file.
    /// `activate` false (⌘-click) opens tabs without switching to them.
    func open(
        _ urls: [URL], remember: Bool = true, anchor: String? = nil, scroll: Double? = nil, activate: Bool = true
    ) {
        var lastID: UUID?
        // New tabs go right after the current one, in the order they were given.
        var insertAt = selectedIndex.map { $0 + 1 } ?? tabs.count
        var skipped: [String] = []
        var tooLarge: [String] = []
        var missing: [String] = []
        var emptyFolders: [String] = []
        for raw in urls {
            var url = MarkdownFiles.canonical(raw)
            if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard let first = Self.mainDocument(in: url) else {
                    emptyFolders.append(url.lastPathComponent)
                    continue
                }
                url = first
                focusMode = false
                sidebarPane = .files
                sidebarVisible = true
            }
            guard MarkdownFiles.canOpen(url) else {
                if MarkdownFiles.isTooLarge(url) {
                    tooLarge.append(url.lastPathComponent)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    skipped.append(url.lastPathComponent)
                } else {
                    missing.append(url.lastPathComponent)
                }
                continue
            }
            if let existing = tabs.first(where: { $0.url == url }) {
                lastID = existing.id
                if let anchor, !anchor.isEmpty {
                    if existing.showSource {
                        // Heading anchors only exist in the rendered view.
                        existing.showSource = false
                        existing.pendingAnchor = anchor
                        if existing.id == selectedID { reader.display(existing) }
                    } else if existing.id == selectedID {
                        reader.scrollToAnchor(anchor)
                    } else {
                        existing.pendingAnchor = anchor
                    }
                } else if let scroll {
                    if existing.showSource {
                        existing.showSource = false
                        existing.pendingScroll = scroll
                        if existing.id == selectedID { reader.display(existing) }
                    } else if existing.id == selectedID {
                        reader.scrollTo(scroll)
                    } else {
                        existing.pendingScroll = scroll
                    }
                }
            } else {
                let tab = makeTab(url)
                tab.pendingAnchor = anchor?.isEmpty == false ? anchor : nil
                if tab.pendingAnchor == nil { tab.pendingScroll = scroll ?? scrollMemory[url.path]?.first }
                tabs.insert(tab, at: min(insertAt, tabs.count))
                insertAt += 1
                lastID = tab.id
            }
            if remember { addRecent(url) }
        }
        if let lastID, activate || selectedID == nil { selectedID = lastID }
        persistTabs()
        if !tooLarge.isEmpty {
            show(Toast(message: "Can't open \(tooLarge.joined(separator: ", ")): larger than 20 MB"))
        } else if !skipped.isEmpty {
            show(Toast(message: "Can't open \(skipped.joined(separator: ", ")): not a text file"))
        } else if !missing.isEmpty, !restoring {
            show(Toast(message: "\(missing.joined(separator: ", ")) not found"))
        } else if !emptyFolders.isEmpty {
            show(Toast(message: "No Markdown files in \(emptyFolders.joined(separator: ", "))"))
        }
    }

    private func makeTab(_ url: URL) -> DocTab {
        let tab = DocTab(url: url)
        tab.onChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            if tab.id == self.selectedID {
                self.reader.display(tab)
            } else if tab.textChanged {
                tab.changedInBackground = true
            }
            if tab.editing { self.fileChangedWhileEditing(tab) }
            self.objectWillChange.send()
        }
        return tab
    }

    /// README, then index, then the first Markdown file by name.
    private static func mainDocument(in folder: URL) -> URL? {
        let files = markdownFiles(in: MarkdownFiles.canonical(folder))
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for name in ["readme", "index"] {
            if let match = files.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return match
            }
        }
        return files.first
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MarkdownFiles.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if let dir = selected?.url.deletingLastPathComponent() { panel.directoryURL = dir }
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard confirmClosing([tabs[index]]) else { return }
        let tab = tabs.remove(at: index)
        editor.stopShowing(tab)
        // A new document that was never saved anywhere leaves nothing behind.
        if tab.isUntitled { try? FileManager.default.removeItem(at: tab.url) }
        rememberScroll(of: tab)
        reader.forget(tab)
        closedTabs.removeAll { $0 == tab.url }
        if !tab.isUntitled { closedTabs.append(tab.url) }
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { focusMode = false }
        persistTabs()
    }

    func closeOthers(_ id: UUID) {
        let others = tabs.filter { $0.id != id }
        guard confirmClosing(others) else { return }
        selectedID = id  // select first so closing the rest doesn't re-render each neighbour
        others.forEach { close($0.id) }
    }

    func closeToRight(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let right = Array(tabs[(index + 1)...])
        guard confirmClosing(right) else { return }
        if let selected = selectedIndex, selected > index { selectedID = id }
        right.forEach { close($0.id) }
    }

    /// The last ten closed tabs, most recent first.
    var recentlyClosed: [URL] { Array(closedTabs.suffix(10).reversed()) }

    func reopen(_ url: URL) {
        closedTabs.removeAll { $0 == url }
        open([url])
    }

    /// ⇧⌘V: opens copied Markdown text in a new tab, or copied files.
    func openClipboard() {
        let pb = NSPasteboard.general
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !files.isEmpty
        {
            return open(files)
        }
        guard let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return show(Toast(message: "The clipboard has no text")) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MDReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("Clipboard.md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Clipboard \(n).md")
            n += 1
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            open([url], remember: false, scroll: 0)
        } catch {
            show(Toast(message: "Couldn't open the clipboard: \(error.localizedDescription)"))
        }
    }

    /// At quit: new documents that were never saved anywhere are thrown away.
    func discardUntitled() {
        for tab in tabs where tab.isUntitled { try? FileManager.default.removeItem(at: tab.url) }
    }

    /// Clears out clipboard files from earlier sessions that aren't open in a tab.
    func removeOldClipboardFiles() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MDReader", isDirectory: true)
        let open = Set(tabs.map(\.url.path))
        for dir in [folder, folder.appendingPathComponent("Untitled")] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for file in files where !open.contains(MarkdownFiles.canonical(file).path) {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: New, rename, duplicate

    /// ⌘N: an empty document in the editor; the first ⌘S asks where to save it.
    func newDocument() {
        let folder = DocTab.untitledFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("Untitled.md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || tabs.contains(where: { $0.url == url }) {
            url = folder.appendingPathComponent("Untitled \(n).md")
            n += 1
        }
        guard (try? Data().write(to: url)) != nil else { return NSSound.beep() }
        focusMode = false
        open([url], remember: false, scroll: 0)
        if let tab = selected, tab.url == MarkdownFiles.canonical(url) { startEditing(tab) }
    }

    /// Save panel for a new document. Returns false if cancelled or failed.
    private func saveAs(_ tab: DocTab) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = tab.fileName
        panel.message = "Save \(tab.title)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        let alert = NSAlert()
        if tabs.contains(where: { $0 !== tab && $0.url == MarkdownFiles.canonical(chosen) }) {
            alert.messageText = "\(chosen.lastPathComponent) is open in another tab"
            alert.informativeText = "Close that tab or choose another name."
            alert.runModal()
            return false
        }
        do {
            try (tab.draft ?? tab.text).write(to: chosen, atomically: true, encoding: .utf8)
        } catch {
            alert.messageText = "Couldn't save \(chosen.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
        let temporary = tab.url
        relocate(tab, to: chosen)
        try? FileManager.default.removeItem(at: temporary)
        return true
    }

    /// The tab's file is now at `url` (first save, or rename). Everything keyed by path follows.
    private func relocate(_ tab: DocTab, to url: URL) {
        let from = tab.url
        tab.move(to: MarkdownFiles.canonical(url))
        let to = tab.url
        scrollMemory[to.path] = scrollMemory[from.path]
        foldMemory[to.path] = foldMemory[from.path]
        backStack = backStack.map { $0.url == from ? Position(url: to, y: $0.y) : $0 }
        forwardStack = forwardStack.map { $0.url == from ? Position(url: to, y: $0.y) : $0 }
        recents.removeAll { $0 == from }
        addRecent(to)
        persistTabs()
        if tab.id == selectedID {
            refreshFolder()
            reader.display(tab)
        }
        objectWillChange.send()
    }

    func rename(_ tab: DocTab) {
        guard !tab.isUntitled else { return }
        // Unsaved edits go to the file first, so the renamed file has them.
        guard !tab.isDirty || save(tab) else { return }
        let field = NSTextField(string: tab.fileName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "Rename \(tab.fileName)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // Select the name without the extension, as Finder does.
        DispatchQueue.main.async {
            let base = (tab.fileName as NSString).deletingPathExtension as NSString
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: base.length)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != tab.fileName else { return }
        let target = tab.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: tab.url, to: target)
        } catch {
            return show(Toast(message: "Couldn't rename: \(error.localizedDescription)"))
        }
        relocate(tab, to: target)
    }

    func duplicate(_ tab: DocTab) {
        guard !tab.isUntitled else { return }
        let folder = tab.url.deletingLastPathComponent()
        let base = tab.url.deletingPathExtension().lastPathComponent
        let ext = tab.url.pathExtension
        var copy = folder.appendingPathComponent("\(base) copy").appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: copy.path) {
            copy = folder.appendingPathComponent("\(base) copy \(n)").appendingPathExtension(ext)
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: tab.url, to: copy)
            open([copy])
        } catch {
            show(Toast(message: "Couldn't duplicate: \(error.localizedDescription)"))
        }
    }

    /// Copies the rendered HTML as text, for a CMS or an email template.
    func copyHTML() {
        guard let tab = selected, !tab.editing else { return }
        ensureRendered()
        reader.renderedHTML { [weak self] page in
            guard let page else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(page.html, forType: .string)
            self?.show(Toast(message: "Copied HTML"))
        }
    }

    // MARK: Reading progress & selection

    private func updateTimeLeft(_ progress: Double) {
        var left: Int?
        if let tab = selected, !tab.showSource, !tab.editing, tab.wordCount > 0, progress > 0.02, progress < 0.99 {
            // Rounded like the total, and never more than it.
            let total = max(1, Int((Double(tab.wordCount) / 230).rounded()))
            left = min(total, max(1, Int((Double(tab.wordCount) * (1 - progress) / 230).rounded())))
        }
        if left != status.minutesLeft { status.minutesLeft = left }
    }

    private func setSelectionWords(_ words: Int) {
        if words != status.selectionWords { status.selectionWords = words }
    }

    var previewWhileEditing: Bool { UserDefaults.standard.bool(forKey: Prefs.editPreview) }

    /// Shows or hides the rendered page beside the editor.
    func setPreviewWhileEditing(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Prefs.editPreview)
        guard let tab = selected, tab.editing else { return objectWillChange.send() }
        tab.showSource = !on
        tab.pendingOffset = editor.topOffset
        reader.display(tab)
        objectWillChange.send()
    }

    /// ⇧⌘T: bring back the most recently closed tab that still exists on disk.
    func reopenClosedTab() {
        while let url = closedTabs.popLast() {
            if FileManager.default.fileExists(atPath: url.path) {
                open([url])
                return
            }
        }
        NSSound.beep()
    }

    /// ⌘W: close the current tab, or the window if nothing is open (or another window is key).
    func closeTabOrWindow() {
        if let key = NSApp.keyWindow, key !== reader.webView.window {
            key.performClose(nil)
        } else if let id = selectedID {
            close(id)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func selectTab(offset: Int) {
        guard let i = selectedIndex, !tabs.isEmpty else { return }
        selectedID = tabs[(i + offset + tabs.count) % tabs.count].id
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        // ⌘9 always jumps to the last tab, as in browsers.
        let i = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(i) { selectedID = tabs[i].id }
    }

    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
            let to = tabs.firstIndex(where: { $0.id == target })
        else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        persistTabs()
    }

    // MARK: Viewing

    func toggleSource() {
        guard let tab = selected, !tab.editing else { return }
        tab.showSource.toggle()
        tab.syncOnNextDisplay = true
        objectWillChange.send()
        reader.display(tab)
    }

    func reloadSelected() {
        selected?.reload()
    }

    // MARK: Editing & focus

    var editorURL: URL? {
        UserDefaults.standard.string(forKey: Prefs.editorApp).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    var editorName: String? {
        editorURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    /// The Edit button: edits in MDReader, or opens the external editor chosen in Settings.
    func edit() {
        guard let tab = selected else { return }
        if tab.editing {
            stopEditing(tab)
            return
        }
        guard let app = editorURL else { return startEditing(tab) }
        NSWorkspace.shared.open([tab.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            if let error {
                DispatchQueue.main.async { AppState.shared.show(Toast(message: error.localizedDescription)) }
            }
        }
    }

    private func startEditing(_ tab: DocTab) {
        guard tab.error == nil else { return NSSound.beep() }
        guard tab.canEdit else {
            return show(Toast(message: "Can't edit \(tab.fileName): its text encoding isn't supported"))
        }
        findVisible = false
        reader.placeOffset { [weak self] offset in
            guard let self, !tab.editing, tab.id == self.selectedID else { return }
            tab.sourceBeforeEditing = tab.showSource
            tab.editing = true
            // The page shows the rendered draft beside the editor, or (hidden) the source, so the
            // outline lists the Markdown headings either way.
            let source = !self.previewWhileEditing
            if tab.showSource != source {
                tab.showSource = source
                tab.pendingOffset = offset
            }
            self.reader.display(tab)
            self.objectWillChange.send()
            self.editor.show(tab)
            self.editor.prepare(offset: offset)
        }
    }

    /// Ends editing, asking first about unsaved changes. Returns false if cancelled.
    @discardableResult
    func stopEditing(_ tab: DocTab) -> Bool {
        guard confirmClosing([tab]) else { return false }
        status.selectionWords = 0
        let offset = editor.tab === tab ? editor.topOffset : nil
        editor.stopShowing(tab)
        tab.editing = false
        tab.draft = nil
        tab.showSource = tab.sourceBeforeEditing
        tab.pendingOffset = offset
        if tab.id == selectedID {
            reader.display(tab)
            DispatchQueue.main.async { self.focusReader(force: true) }
        }
        objectWillChange.send()
        return true
    }

    /// A task checkbox was clicked on the page: change [ ] to [x] (or back) in the file, or in
    /// the editor's text while editing. Nothing is written unless the page and the file agree.
    private func toggleTask(_ index: Int, shown: [DocTab.ShownTask], path: String) {
        guard let tab = selected, tab.error == nil, tab.url.path == path else {
            return reader.display(selected)  // puts the checkbox back
        }
        guard tab.editing || tab.canEdit else {
            show(Toast(message: "Can't edit \(tab.fileName): its text encoding isn't supported"))
            return reader.display(tab)
        }
        // Another app changed the file and the page hasn't caught up: show the new version instead.
        if !tab.editing, tab.changedSinceLoad { return tab.reload() }
        let source = tab.editing ? editor.textView.string : tab.text
        guard let change = DocTab.togglingTask(index, shown: shown, in: source) else {
            show(Toast(message: "Couldn't find that task in the file"))
            return reader.display(tab)
        }
        if tab.editing {
            editor.replaceText(in: change.mark, with: shown[index].checked ? " " : "x")
            return
        }
        tab.draft = change.text
        do {
            try tab.save()
        } catch {
            tab.draft = nil
            show(Toast(message: "Couldn't save \(tab.fileName): \(error.localizedDescription)"))
        }
        reader.display(tab)
        objectWillChange.send()
    }

    /// ⌘S
    func save() {
        guard let tab = selected, tab.isDirty else { return }
        save(tab)
    }

    @discardableResult
    private func save(_ tab: DocTab) -> Bool {
        if tab.isUntitled { return saveAs(tab) }
        // Changes a file watcher can miss (network volumes) shouldn't be overwritten silently.
        if tab.changedSinceLoad {
            let alert = NSAlert()
            alert.messageText = "\(tab.fileName) changed on disk"
            alert.informativeText = "Another app changed it. Save your version anyway?"
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        do {
            try tab.save()
            objectWillChange.send()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save \(tab.fileName)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    /// Asks what to do with unsaved changes in `tabs`: save, discard or cancel. True unless cancelled.
    func confirmClosing(_ tabs: [DocTab]) -> Bool {
        let dirty = tabs.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Save changes to \(dirty[0].fileName)?" : "Save changes to \(dirty.count) documents?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return dirty.allSatisfy { save($0) }
        case .alertThirdButtonReturn:
            dirty.forEach { $0.draft = nil }
            objectWillChange.send()
            return true
        default:
            return false
        }
    }

    /// The file changed on disk while being edited in MDReader.
    private func fileChangedWhileEditing(_ tab: DocTab) {
        guard tab.textChanged else { return }
        if !tab.isDirty {
            tab.draft = nil
            return editor.reload(from: tab)
        }
        let alert = NSAlert()
        alert.messageText = "\(tab.fileName) changed on disk"
        alert.informativeText = "Keep your edits, or load the version on disk?"
        alert.addButton(withTitle: "Keep My Edits")
        alert.addButton(withTitle: "Load from Disk")
        if alert.runModal() == .alertSecondButtonReturn {
            tab.draft = nil
            editor.reload(from: tab)
        }
    }

    func foldAll(_ collapsed: Bool) {
        reader.foldAll(collapsed)
    }

    private func rememberFolds(_ ids: [String]) {
        guard let tab = selected, !tab.showSource else { return }
        foldMemory[tab.url.path] = ids.isEmpty ? nil : ids
        if foldMemory.count > 300 {
            foldMemory.keys.filter { key in !tabs.contains { $0.url.path == key } }.prefix(foldMemory.count - 300)
                .forEach { foldMemory[$0] = nil }
        }
        UserDefaults.standard.set(foldMemory, forKey: Prefs.foldMemory)
    }

    @discardableResult
    func chooseEditor() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the app to edit Markdown files with"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return nil }
        UserDefaults.standard.set(app.path, forKey: Prefs.editorApp)
        objectWillChange.send()
        return app
    }

    /// Gives the page keyboard focus (for j/k and the other reading keys) unless something else has it.
    func focusReader(force: Bool = false) {
        guard let window = reader.webView.window, palette == nil else { return }
        if selected?.editing == true { return editor.focus() }
        if force { return _ = window.makeFirstResponder(reader.webView) }
        // A text field that has gone away can leave its field editor as first responder.
        let editor = window.firstResponder as? NSTextView
        let orphanedEditor = editor?.isFieldEditor == true && (editor?.delegate as? NSView)?.window == nil
        if window.firstResponder == nil || window.firstResponder === window || orphanedEditor {
            window.makeFirstResponder(reader.webView)
        }
    }

    func toggleFocusMode() {
        focusMode.toggle()
    }

    func toggleSidebar() {
        focusMode = false
        sidebarVisible.toggle()
    }

    /// Shows the sidebar on `pane`, or hides it if that pane is already showing.
    func showSidebar(_ pane: SidebarPane) {
        if focusMode {
            focusMode = false
            sidebarPane = pane
            sidebarVisible = true
        } else if sidebarVisible && sidebarPane == pane {
            sidebarVisible = false
        } else {
            sidebarPane = pane
            sidebarVisible = true
        }
    }

    func scrollToHeading(_ id: String) {
        if let tab = selected, tab.editing {
            return reader.headingOffset(id) { [weak self] offset in
                guard let offset, self?.selected === tab else { return }
                self?.editor.scroll(toOffset: offset)
            }
        }
        recordPosition()
        reader.scrollToAnchor(id)
    }

    func copyLink(toHeading id: String) {
        guard let tab = selected else { return }
        NSPasteboard.general.clearContents()
        // Percent-encode so the link still works in Markdown when the name has spaces.
        let name = tab.url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? tab.url.lastPathComponent
        let anchor = id.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? id
        NSPasteboard.general.setString("\(name)#\(anchor)", forType: .string)
        show(Toast(message: "Link copied"))
    }

    // MARK: Search

    /// The last search in the find bar, filled in again when it reopens.
    var lastFindQuery = ""

    /// Opens the find bar; `step` also moves to the next (1) or previous (-1) match.
    func showFind(step: Int? = nil) {
        if selected?.editing == true {
            return editor.find(step == nil ? .showFindInterface : step! > 0 ? .nextMatch : .previousMatch)
        }
        findVisible = true
        // After the bar exists, so it receives this.
        DispatchQueue.main.async { NotificationCenter.default.post(name: .findNext, object: step) }
    }

    /// Shows the Search pane and puts the cursor in its field.
    func showSearch() {
        focusMode = false
        sidebarPane = .search
        sidebarVisible = true
        search.focusToken = UUID()
    }

    /// Opens a file from the search results and selects the match with Find.
    func openSearchResult(_ url: URL, query: String, occurrence: Int) {
        open([url])
        findRequest = FindRequest(query: query, index: occurrence)
        findVisible = true
    }

    // MARK: Back & Forward

    /// Remembers where the reader is before following a link, so Back can return there.
    private func recordPosition(y: Double? = nil) {
        guard let tab = selected, !tab.showSource else { return }
        backStack.append(Position(url: tab.url, y: y ?? reader.lastScroll(for: tab) ?? 0))
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
        updateHistoryState()
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        if let here = currentPosition() { forwardStack.append(here) }
        go(to: target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let here = currentPosition() { backStack.append(here) }
        go(to: target)
    }

    private func currentPosition() -> Position? {
        guard let tab = selected else { return nil }
        return Position(url: tab.url, y: reader.lastScroll(for: tab) ?? 0)
    }

    private func go(to position: Position) {
        open([position.url], remember: false, scroll: position.y)
        updateHistoryState()
    }

    private func updateHistoryState() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    // MARK: Folder & Quick Open

    /// Lists the Markdown files next to the current document and keeps the list current.
    private func refreshFolder() {
        guard let tab = selected else {
            folderFiles = []
            folderSubfolders = []
            watchedFolder = nil
            folderWatcher = nil
            return
        }
        let folder = tab.url.deletingLastPathComponent()
        // Stay at the same top folder for files in its subfolders (opened from the tree) and for
        // new documents that aren't saved yet.
        if let root = watchedFolder {
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if tab.isUntitled || (tab.url.path.hasPrefix(prefix) && folder != root) { return listFolder() }
        }
        if folder != watchedFolder {
            watchedFolder = folder
            folderWatcher = FileWatcher(url: folder) { [weak self] in self?.listFolder() }
        }
        listFolder()
    }

    private func listFolder() {
        guard let folder = watchedFolder else { return }
        let (folders, files) = Self.listing(of: folder, sort: filesSort)
        if files != folderFiles { folderFiles = files }
        if folders != folderSubfolders { folderSubfolders = folders }
        // A file that was deleted and has come back (for example after switching git branches).
        for tab in tabs where tab.error != nil && tab.url.deletingLastPathComponent() == folder {
            if FileManager.default.fileExists(atPath: tab.url.path) { tab.reload() }
        }
    }

    /// Subfolders and Markdown files of a folder, for the Files sidebar. Hidden folders and
    /// node_modules are left out. `sort` is "name" or "date" (newest first, for files).
    static func listing(of folder: URL, sort: String) -> (folders: [URL], files: [URL]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var folders: [URL] = []
        var files: [URL] = []
        for name in names where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if name != "node_modules", !name.hasSuffix(".app") { folders.append(url) }
            } else if MarkdownFiles.isMarkdownDocument(url) {
                files.append(url)
            }
        }
        let byName: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        folders.sort(by: byName)
        if sort == "date" {
            let date = { (url: URL) in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            }
            let dates = Dictionary(uniqueKeysWithValues: files.map { ($0, date($0)) })
            files.sort { dates[$0]! > dates[$1]! }
        } else {
            files.sort(by: byName)
        }
        return (folders, files)
    }

    private func filesSortMayHaveChanged() {
        let sort = UserDefaults.standard.string(forKey: Prefs.filesSort) ?? "name"
        guard sort != filesSort else { return }
        filesSort = sort
        listFolder()
    }

    /// Markdown files in a folder, sorted by name. Works when the folder path is a symlink.
    private static func markdownFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0).standardizedFileURL }
            .filter(MarkdownFiles.isMarkdownDocument)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Open tabs first, then recent files, then the rest of the current folder.
    var quickOpenCandidates: [URL] {
        var seen = Set<String>()
        return (tabs.map(\.url) + recents + folderFiles).filter { seen.insert($0.path).inserted }
    }

    func zoom(by delta: Double?) {
        Prefs.zoomLevel = delta.map { Prefs.zoomLevel + $0 } ?? 1.0
    }

    func revealInFinder(_ tab: DocTab) {
        NSWorkspace.shared.activateFileViewerSelecting([tab.url])
    }

    func copyPath(_ tab: DocTab) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.url.path, forType: .string)
    }

    // MARK: Export

    func exportPDF() {
        guard let tab = selected, !tab.editing, let window = reader.webView.window else { return }
        let defaults = UserDefaults.standard
        let folder = URL(fileURLWithPath: defaults.string(forKey: Prefs.pdfFolder) ?? Prefs.defaultPDFFolder)
        let baseName = tab.url.deletingPathExtension().lastPathComponent

        if defaults.bool(forKey: Prefs.askWhereToSave) {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.directoryURL = folder
            panel.nameFieldStringValue = baseName + ".pdf"
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                // Let the sheet finish closing before the print operation attaches its own.
                DispatchQueue.main.async { self?.writePDF(to: url) }
            }
        } else {
            writePDF(to: uniqueURL(in: folder, baseName: baseName))
        }
    }

    func exportHTML() {
        guard let tab = selected, !tab.editing, let window = reader.webView.window else { return }
        ensureRendered()
        reader.renderedHTML { [weak self] page in
            guard let self else { return }
            guard let page else { return self.show(Toast(message: "Couldn't export HTML")) }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.directoryURL = URL(
                fileURLWithPath: UserDefaults.standard.string(forKey: Prefs.pdfFolder) ?? Prefs.defaultPDFFolder)
            panel.nameFieldStringValue = tab.url.deletingPathExtension().lastPathComponent + ".html"
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try HTMLExport.document(for: page).write(to: url, atomically: true, encoding: .utf8)
                    let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                    self?.show(Toast(message: "Exported \(url.lastPathComponent) to \(folder)", revealURL: url))
                } catch {
                    self?.show(Toast(message: "Couldn't export HTML: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Export as Word (.docx) or RTF.
    func exportDocument(word: Bool) {
        guard let tab = selected, !tab.editing, let window = reader.webView.window else { return }
        ensureRendered()
        reader.renderedHTML(plain: true) { [weak self] page in
            guard let self else { return }
            guard let page else { return self.show(Toast(message: "Couldn't export")) }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [
                word ? (UTType("org.openxmlformats.wordprocessingml.document") ?? .data) : .rtf
            ]
            panel.directoryURL = URL(
                fileURLWithPath: UserDefaults.standard.string(forKey: Prefs.pdfFolder) ?? Prefs.defaultPDFFolder)
            panel.nameFieldStringValue = tab.url.deletingPathExtension().lastPathComponent + (word ? ".docx" : ".rtf")
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    guard let data = HTMLExport.document(for: page, as: word ? .officeOpenXML : .rtf) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: url, options: .atomic)
                    let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                    self?.show(Toast(message: "Exported \(url.lastPathComponent) to \(folder)", revealURL: url))
                } catch {
                    self?.show(Toast(message: "Couldn't export: \(error.localizedDescription)"))
                }
            }
        }
    }

    func copyRichText() {
        guard let tab = selected, !tab.editing else { return }
        ensureRendered()
        reader.renderedHTML { [weak self] page in
            guard let page else { return }
            HTMLExport.copyRichText(page)
            self?.show(Toast(message: "Copied as rich text"))
        }
    }

    /// HTML export and rich-text copy need the rendered view, not the Markdown source.
    private func ensureRendered() {
        if selected?.showSource == true { toggleSource() }
    }

    func printDocument() {
        guard let tab = selected, !tab.editing else { return }
        reader.printDocument()
    }

    private func writePDF(to url: URL) {
        reader.exportPDF(to: url) { [weak self] success in
            let path = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            self?.show(
                success
                    ? Toast(message: "Exported \(url.lastPathComponent) to \(path)", revealURL: url)
                    : Toast(message: "Couldn't export the PDF"))
        }
    }

    private func uniqueURL(in folder: URL, baseName: String) -> URL {
        var url = folder.appendingPathComponent(baseName + ".pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName) \(n).pdf")
            n += 1
        }
        return url
    }

    func show(_ toast: Toast) {
        self.toast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    // MARK: Command line tool & updates

    func installCommandLineTool() {
        guard let script = Bundle.main.url(forResource: "mdr", withExtension: nil)?.path else { return }
        // Escape for an AppleScript string literal, then let `quoted form of` handle the shell.
        let literal = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            do shell script "mkdir -p /usr/local/bin && rm -f /usr/local/bin/mdr && cp " & quoted form of "\(literal)" & " /usr/local/bin/mdr && chmod 755 /usr/local/bin/mdr" with administrator privileges
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if (error?[NSAppleScript.errorNumber] as? Int) == -128 { return }  // password prompt cancelled
        let alert = NSAlert()
        if let error {
            alert.messageText = "Couldn't install the command line tool"
            alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? ""
        } else {
            alert.messageText = "The mdr command is installed"
            alert.informativeText = "Usage: mdr file.md"
        }
        alert.runModal()
    }

    func checkForUpdatesInBackground() {
        availableUpdate = UpdateChecker.knownUpdate
        UpdateChecker.checkIfDue { [weak self] release in self?.availableUpdate = release }
    }

    func checkForUpdatesNow() {
        UpdateChecker.check { [weak self] result in
            let alert = NSAlert()
            switch result {
            case .available(let release):
                self?.availableUpdate = release
                alert.messageText = "MDReader \(release.version) is available"
                alert.informativeText = "You have version \(UpdateChecker.currentVersion)."
                alert.addButton(withTitle: "View Release")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
                return
            case .upToDate:
                alert.messageText = "You're up to date"
                alert.informativeText = "MDReader \(UpdateChecker.currentVersion) is the latest version."
            case .failed(let message):
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = message
            }
            alert.runModal()
        }
    }

    // MARK: Persistence

    private func addRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(12))
        UserDefaults.standard.set(recents.map(\.path), forKey: Prefs.recentFiles)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func clearRecents() {
        recents = []
        scrollMemory = [:]
        UserDefaults.standard.removeObject(forKey: Prefs.recentFiles)
        UserDefaults.standard.removeObject(forKey: Prefs.scrollMemory)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private var restoring = false

    /// Saves where each open file is scrolled to, so it reopens there next time.
    func rememberScrollPositions() {
        tabs.forEach(rememberScroll(of:))
        let limit = 300
        if scrollMemory.count > limit {
            let oldest = scrollMemory.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }
            oldest.prefix(scrollMemory.count - limit).forEach { scrollMemory[$0.key] = nil }
        }
        UserDefaults.standard.set(scrollMemory, forKey: Prefs.scrollMemory)
    }

    private func rememberScroll(of tab: DocTab) {
        guard let y = reader.lastScroll(for: tab) else { return }
        scrollMemory[tab.url.path] = [y, Date().timeIntervalSince1970]
    }

    func persistTabs() {
        guard !restoring else { return }
        rememberScrollPositions()
        UserDefaults.standard.set(
            [
                "files": tabs.filter { !$0.isUntitled }.map(\.url.path),
                "selected": selected.flatMap { $0.isUntitled ? nil : $0.url.path } ?? "",
            ] as [String: Any],
            forKey: Prefs.openTabs)
    }

    func restoreTabs() {
        guard UserDefaults.standard.bool(forKey: Prefs.restoreTabs),
            let saved = UserDefaults.standard.dictionary(forKey: Prefs.openTabs),
            let files = saved["files"] as? [String]
        else { return }
        restoring = true
        open(files.map { URL(fileURLWithPath: $0) }, remember: false)
        if let sel = saved["selected"] as? String,
            let tab = tabs.first(where: { $0.url.path == sel })
        {
            selectedID = tab.id
        }
        restoring = false
        reader.display(selected)
        persistTabs()
    }
}
