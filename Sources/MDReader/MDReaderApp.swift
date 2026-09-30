import SwiftUI

@main
struct MDReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("MDReader", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 920, height: 1000)
        .commands { AppCommands(state: state) }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.migrateFromOldBundleID()
        Prefs.register()
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.appearance = Prefs.appearanceMode.nsAppearance
        // Restore before any "open file" events arrive so those end up selected.
        MainActor.assumeIsolated { AppState.shared.restoreTabs() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Picks up a custom.css created (or recreated) while MDReader was in the background.
        MainActor.assumeIsolated { AppState.shared.reader.watchCustomCSS() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.checkForUpdatesInBackground()
            AppState.shared.removeOldClipboardFiles()
        }
        // Mouse side buttons go Back and Forward.
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
            let back = event.buttonNumber == 3
            let handled = MainActor.assumeIsolated { () -> Bool in
                let state = AppState.shared
                guard NSApp.keyWindow === state.reader.webView.window else { return false }
                if back { state.goBack() } else { state.goForward() }
                return true
            }
            return handled ? nil : event
        }
        // Escape leaves focus mode, unless it's closing something else first.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                let state = AppState.shared
                guard state.focusMode, !state.findVisible, state.palette == nil,
                    !state.reader.lightboxOpen, NSApp.keyWindow === state.reader.webView.window
                else { return false }
                state.focusMode = false
                return true
            }
            return handled ? nil : event
        }
        // The Zoom In item is ⌘+, which needs Shift on most layouts; accept ⌘= too, like browsers.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "="
            else { return event }
            MainActor.assumeIsolated { AppState.shared.zoom(by: 0.1) }
            return nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppState.shared.open(urls) }
    }

    /// Recent files in the Dock icon's menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let recents = MainActor.assumeIsolated { AppState.shared.recents.prefix(10) }
        guard !recents.isEmpty else { return nil }
        let menu = NSMenu()
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openFromDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated { AppState.shared.open([url]) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let state = AppState.shared
            return state.confirmClosing(state.tabs) ? .terminateNow : .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.rememberScrollPositions() }
    }
}

/// Asks about unsaved edits before the window's close button closes the window (and quits the app).
final class WindowCloseGuard: NSObject {
    static let shared = WindowCloseGuard()

    func install(on window: NSWindow) {
        guard let button = window.standardWindowButton(.closeButton), button.target !== self else { return }
        button.target = self
        button.action = #selector(closeClicked(_:))
    }

    @objc private func closeClicked(_ sender: NSButton) {
        let proceed = MainActor.assumeIsolated { AppState.shared.confirmClosing(AppState.shared.tabs) }
        // close() rather than performClose(_:), which would click this button again.
        if proceed { sender.window?.close() }
    }
}

/// The file name, plus its folder when another entry has the same name.
private func menuTitle(_ url: URL, among urls: [URL]) -> String {
    let name = url.lastPathComponent
    let clash = urls.contains { $0 != url && $0.lastPathComponent == name }
    return clash ? "\(name) — \(url.deletingLastPathComponent().lastPathComponent)" : name
}

private func open(_ link: String) {
    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(Prefs.contentWidth) private var contentWidth = ContentWidth.medium.rawValue
    @AppStorage(Prefs.lineNumbers) private var lineNumbers = false

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { state.checkForUpdatesNow() }
            Button("Install Command Line Tool…") { state.installCommandLineTool() }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open…") { state.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(state.recents, id: \.self) { url in
                    Button(menuTitle(url, among: state.recents)) { state.open([url]) }
                }
                Divider()
                Button("Clear Menu") { state.clearRecents() }
                    .disabled(state.recents.isEmpty)
            }
            Divider()
            Button(state.selected?.editing == true ? "Stop Editing" : state.editorName.map { "Edit in \($0)" } ?? "Edit") {
                state.edit()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(state.selected == nil)
            Button("Save") { state.save() }
                .keyboardShortcut("s")
                .disabled(state.selected?.isDirty != true)
            Divider()
            Button("Open Clipboard") { state.openClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Reopen Closed Tab") { state.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(state.closedTabs.isEmpty)
            Menu("Recently Closed") {
                ForEach(state.recentlyClosed, id: \.self) { url in
                    Button(menuTitle(url, among: state.recentlyClosed)) { state.reopen(url) }
                }
            }
            .disabled(state.closedTabs.isEmpty)
            Button("Close Tab") { state.closeTabOrWindow() }
                .keyboardShortcut("w")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export as PDF…") { state.exportPDF() }
                .keyboardShortcut("e")
                .disabled(state.selected == nil || state.selected?.editing == true)
            Button("Export as HTML…") { state.exportHTML() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(state.selected == nil || state.selected?.editing == true)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { state.printDocument() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(state.selected == nil || state.selected?.editing == true)
        }

        CommandMenu("Go") {
            Button("Back") { state.goBack() }
                .keyboardShortcut("[")
                .disabled(!state.canGoBack)
            Button("Forward") { state.goForward() }
                .keyboardShortcut("]")
                .disabled(!state.canGoForward)
            Divider()
            Button("Quick Open…") { state.palette = state.palette == .files ? nil : .files }
                .keyboardShortcut("p")
            Button("Jump to Heading…") { state.palette = state.palette == .headings ? nil : .headings }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(state.selected == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy as Rich Text") { state.copyRichText() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(state.selected == nil || state.selected?.editing == true)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { state.showFind() }
                .keyboardShortcut("f")
                .disabled(state.selected == nil)
            Button("Search in Files…") { state.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(state.selected == nil)
            Button("Find Next") { state.showFind(step: 1) }
                .keyboardShortcut("g")
                .disabled(state.selected == nil)
            Button("Find Previous") { state.showFind(step: -1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(state.selected == nil)
        }

        CommandGroup(before: .toolbar) {
            Button(state.focusMode ? "Exit Focus Mode" : "Enter Focus Mode") { state.toggleFocusMode() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(state.selected == nil && !state.focusMode)
            Button(state.sidebarVisible && state.sidebarPane == .outline ? "Hide Outline" : "Show Outline") {
                state.showSidebar(.outline)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(state.selected == nil)
            Button(state.sidebarVisible && state.sidebarPane == .files ? "Hide Files" : "Show Files") {
                state.showSidebar(.files)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(state.selected == nil)
            Button(state.selected?.showSource == true ? "Show Rendered" : "Show Markdown Source") {
                state.toggleSource()
            }
            .keyboardShortcut("/")
            .disabled(state.selected == nil)
            Toggle("Line Numbers in Markdown Source", isOn: $lineNumbers)
            Button("Collapse All Sections") { state.foldAll(true) }
                .disabled(state.selected == nil || state.selected?.showSource == true)
            Button("Expand All Sections") { state.foldAll(false) }
                .disabled(state.selected == nil || state.selected?.showSource == true)
            Button("Reload") { state.reloadSelected() }
                .keyboardShortcut("r")
                .disabled(state.selected == nil)
            Divider()
            Button("Actual Size") { state.zoom(by: nil) }
                .keyboardShortcut("0")
            Button("Zoom In") { state.zoom(by: 0.1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { state.zoom(by: -0.1) }
                .keyboardShortcut("-")
            Divider()
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Text Width", selection: $contentWidth) {
                ForEach(ContentWidth.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Divider()
        }

        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { state.selectTab(offset: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { state.selectTab(offset: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            // The open tabs by name, ⌘1–⌘8, and ⌘9 for the last one, as in browsers.
            ForEach(Array(state.tabs.prefix(8).enumerated()), id: \.element.id) { index, tab in
                Button(tab.title) { state.selectedID = tab.id }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            if state.tabs.count > 1 {
                Button("Show Last Tab") { state.selectTab(number: 9) }
                    .keyboardShortcut("9")
            }
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("MDReader Help") { open("https://github.com/rboundi/mdreader#readme") }
            Button("Keyboard Shortcuts") { open("https://github.com/rboundi/mdreader#keyboard-shortcuts") }
            Divider()
            Button("Report an Issue") { open("https://github.com/rboundi/mdreader/issues") }
        }
    }
}
