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
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var tabs: [DocTab] = []
    @Published var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            // While restoring, only the finally selected tab is rendered (see restoreTabs).
            if !restoring {
                reader.display(selected)
                focusReader()
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
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var availableUpdate: UpdateChecker.Release?
    @Published private(set) var closedTabs: [URL] = []
    /// Bumped whenever the page is re-rendered, so the find bar can search the new content.
    @Published private(set) var renderGeneration = 0

    let reader = ReaderController()
    let search = SearchModel()

    private struct Position {
        let url: URL
        let y: Double
    }
    private var backStack: [Position] = []
    private var forwardStack: [Position] = []
    private var folderWatcher: FileWatcher?
    private var watchedFolder: URL?
    /// Last scroll position per file path, kept across launches: path → [y, time saved].
    private var scrollMemory =
        UserDefaults.standard.dictionary(forKey: Prefs.scrollMemory) as? [String: [Double]] ?? [:]

    var selected: DocTab? { tabs.first { $0.id == selectedID } }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    private init() {
        recents = (UserDefaults.standard.stringArray(forKey: Prefs.recentFiles) ?? [])
            .map { URL(fileURLWithPath: $0) }
        reader.onOpenFile = { [weak self] url, anchor, y in
            guard let self else { return }
            if MarkdownFiles.canOpen(url.standardizedFileURL) { self.recordPosition(y: y) }
            self.open([url], anchor: anchor)
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
    }

    // MARK: Opening & closing

    /// Opens files as tabs (or focuses them if already open). `anchor` jumps to a heading id.
    /// `scroll` restores a position (Back/Forward); otherwise new tabs reopen where you left the file.
    func open(_ urls: [URL], remember: Bool = true, anchor: String? = nil, scroll: Double? = nil) {
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
                let tab = DocTab(url: url)
                tab.pendingAnchor = anchor?.isEmpty == false ? anchor : nil
                if tab.pendingAnchor == nil { tab.pendingScroll = scroll ?? scrollMemory[url.path]?.first }
                tab.onChange = { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    if tab.id == self.selectedID { self.reader.display(tab) }
                    self.objectWillChange.send()
                }
                tabs.insert(tab, at: min(insertAt, tabs.count))
                insertAt += 1
                lastID = tab.id
            }
            if remember { addRecent(url) }
        }
        if let lastID { selectedID = lastID }
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
        let tab = tabs.remove(at: index)
        rememberScroll(of: tab)
        reader.forget(tab)
        closedTabs.removeAll { $0 == tab.url }
        closedTabs.append(tab.url)
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { focusMode = false }
        persistTabs()
    }

    func closeOthers(_ id: UUID) {
        selectedID = id  // select first so closing the rest doesn't re-render each neighbour
        tabs.filter { $0.id != id }.forEach { close($0.id) }
    }

    func closeToRight(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let selected = selectedIndex, selected > index { selectedID = id }
        tabs[(index + 1)...].forEach { close($0.id) }
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

    /// Clears out clipboard files from earlier sessions that aren't open in a tab.
    func removeOldClipboardFiles() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MDReader", isDirectory: true)
        let open = Set(tabs.map(\.url.path))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !open.contains(file.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: file)
        }
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
        guard let tab = selected else { return }
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
        UserDefaults.standard.string(forKey: Prefs.editorApp).map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    var editorName: String? {
        editorURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    /// Opens the current file in the chosen editor; asks for one the first time.
    func editInEditor() {
        guard let tab = selected else { return }
        guard let editor = editorURL ?? chooseEditor() else { return }
        NSWorkspace.shared.open([tab.url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            if let error {
                DispatchQueue.main.async { AppState.shared.show(Toast(message: error.localizedDescription)) }
            }
        }
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
    func focusReader() {
        guard let window = reader.webView.window, palette == nil else { return }
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
        guard let folder = selected?.url.deletingLastPathComponent() else {
            folderFiles = []
            watchedFolder = nil
            folderWatcher = nil
            return
        }
        if folder != watchedFolder {
            watchedFolder = folder
            folderWatcher = FileWatcher(url: folder) { [weak self] in self?.listFolder() }
        }
        listFolder()
    }

    private func listFolder() {
        guard let folder = watchedFolder else { return }
        let files = Self.markdownFiles(in: folder)
        if files != folderFiles { folderFiles = files }
        // A file that was deleted and has come back (for example after switching git branches).
        for tab in tabs where tab.error != nil && tab.url.deletingLastPathComponent() == folder {
            if FileManager.default.fileExists(atPath: tab.url.path) { tab.reload() }
        }
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
        guard let tab = selected, let window = reader.webView.window else { return }
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
        guard let tab = selected, let window = reader.webView.window else { return }
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

    func copyRichText() {
        guard selected != nil else { return }
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
        guard selected != nil else { return }
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
            ["files": tabs.map(\.url.path), "selected": selected?.url.path ?? ""] as [String: Any],
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
