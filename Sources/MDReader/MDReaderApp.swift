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

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.checkForUpdatesInBackground() }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.rememberScrollPositions() }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(Prefs.contentWidth) private var contentWidth = ContentWidth.medium.rawValue

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
                    Button(url.lastPathComponent) { state.open([url]) }
                }
                Divider()
                Button("Clear Menu") { state.clearRecents() }
                    .disabled(state.recents.isEmpty)
            }
            Divider()
            Button("Reopen Closed Tab") { state.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(state.closedTabs.isEmpty)
            Button("Close Tab") { state.closeTabOrWindow() }
                .keyboardShortcut("w")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export as PDF…") { state.exportPDF() }
                .keyboardShortcut("e")
                .disabled(state.selected == nil)
            Button("Export as HTML…") { state.exportHTML() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(state.selected == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { state.printDocument() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(state.selected == nil)
        }

        CommandMenu("Go") {
            Button("Back") { state.goBack() }
                .keyboardShortcut("[")
                .disabled(!state.canGoBack)
            Button("Forward") { state.goForward() }
                .keyboardShortcut("]")
                .disabled(!state.canGoForward)
            Divider()
            Button("Quick Open…") { state.quickOpenVisible.toggle() }
                .keyboardShortcut("p")
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy as Rich Text") { state.copyRichText() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(state.selected == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { state.findVisible = true; NotificationCenter.default.post(name: .findNext, object: nil) }
                .keyboardShortcut("f")
                .disabled(state.selected == nil)
            Button("Find Next") { state.findVisible = true; NotificationCenter.default.post(name: .findNext, object: 1) }
                .keyboardShortcut("g")
                .disabled(state.selected == nil)
            Button("Find Previous") { state.findVisible = true; NotificationCenter.default.post(name: .findNext, object: -1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(state.selected == nil)
        }

        CommandGroup(before: .toolbar) {
            Button(state.sidebarVisible && state.sidebarPane == .outline ? "Hide Outline" : "Show Outline") {
                state.showSidebar(.outline)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Button(state.sidebarVisible && state.sidebarPane == .files ? "Hide Files" : "Show Files") {
                state.showSidebar(.files)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Button(state.selected?.showSource == true ? "Show Rendered" : "Show Markdown Source") {
                state.toggleSource()
            }
            .keyboardShortcut("/")
            .disabled(state.selected == nil)
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
            ForEach(1..<10) { n in
                Button(n == 9 ? "Show Last Tab" : "Show Tab \(n)") { state.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
            Divider()
        }
    }
}
