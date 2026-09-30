import AppKit
import UniformTypeIdentifiers

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
            reader.display(selected)
            persistTabs()
        }
    }
    @Published private(set) var recents: [URL] = []
    @Published var toast: Toast?
    @Published var findVisible = false
    @Published private(set) var outline: [OutlineItem] = []
    @Published private(set) var activeHeading: String?
    @Published var outlineVisible = UserDefaults.standard.bool(forKey: Prefs.outlineVisible) {
        didSet { UserDefaults.standard.set(outlineVisible, forKey: Prefs.outlineVisible) }
    }
    @Published var availableUpdate: UpdateChecker.Release?
    @Published private(set) var closedTabs: [URL] = []
    /// Bumped whenever the page is re-rendered, so the find bar can search the new content.
    @Published private(set) var renderGeneration = 0

    let reader = ReaderController()

    var selected: DocTab? { tabs.first { $0.id == selectedID } }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    private init() {
        recents = (UserDefaults.standard.stringArray(forKey: Prefs.recentFiles) ?? [])
            .map { URL(fileURLWithPath: $0) }
        reader.onOpenFile = { [weak self] url, anchor in self?.open([url], anchor: anchor) }
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
    func open(_ urls: [URL], remember: Bool = true, anchor: String? = nil) {
        var lastID: UUID?
        // New tabs go right after the current one, in the order they were given.
        var insertAt = selectedIndex.map { $0 + 1 } ?? tabs.count
        var skipped: [String] = []
        for raw in urls {
            let url = raw.standardizedFileURL
            guard MarkdownFiles.canOpen(url) else {
                if FileManager.default.fileExists(atPath: url.path) { skipped.append(url.lastPathComponent) }
                continue
            }
            if let existing = tabs.first(where: { $0.url == url }) {
                lastID = existing.id
                if let anchor, !anchor.isEmpty {
                    if existing.id == selectedID { reader.scrollToAnchor(anchor) } else { existing.pendingAnchor = anchor }
                }
            } else {
                let tab = DocTab(url: url)
                tab.pendingAnchor = anchor?.isEmpty == false ? anchor : nil
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
        if !skipped.isEmpty {
            show(Toast(message: "Can't open \(skipped.joined(separator: ", ")): not a text file"))
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MarkdownFiles.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if let dir = selected?.url.deletingLastPathComponent() { panel.directoryURL = dir }
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        reader.forget(tab)
        closedTabs.removeAll { $0 == tab.url }
        closedTabs.append(tab.url)
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
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
        objectWillChange.send()
        reader.display(tab)
    }

    func reloadSelected() {
        selected?.reload()
    }

    func toggleOutline() {
        outlineVisible.toggle()
    }

    func scrollToHeading(_ id: String) {
        if selected?.showSource == true { toggleSource() }
        reader.scrollToAnchor(id)
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
            do shell script "mkdir -p /usr/local/bin && cp " & quoted form of "\(literal)" & " /usr/local/bin/mdr && chmod 755 /usr/local/bin/mdr" with administrator privileges
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
            alert.informativeText = "Try: mdr README.md"
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
        UserDefaults.standard.removeObject(forKey: Prefs.recentFiles)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private var restoring = false

    func persistTabs() {
        guard !restoring else { return }
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
        persistTabs()
    }
}
