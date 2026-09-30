import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, sepia, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light, .sepia: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum ReadingFont: String, CaseIterable, Identifiable {
    case sans, serif
    var id: String { rawValue }
    var label: String { self == .sans ? "Sans-serif" : "Serif" }
}

enum ContentWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide, full
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Max text column width in CSS pixels; 0 means use the whole window.
    var pixels: Int {
        switch self {
        case .narrow: return 680
        case .medium: return 860
        case .wide: return 1100
        case .full: return 0
        }
    }
}

/// UserDefaults keys and helpers. Everything the app remembers lives here.
enum Prefs {
    static let appearance = "appearance"
    static let readingFont = "readingFont"
    static let zoom = "zoom"
    static let pdfFolder = "pdfFolder"
    static let askWhereToSave = "askWhereToSave"
    static let restoreTabs = "restoreTabs"
    static let openTabs = "openTabs"
    static let recentFiles = "recentFiles"
    static let contentWidth = "contentWidth"
    static let printHeaderFooter = "printHeaderFooter"
    static let outlineVisible = "outlineVisible"
    static let checkForUpdates = "checkForUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let latestVersion = "latestVersion"
    static let latestVersionURL = "latestVersionURL"
    static let sidebarPane = "sidebarPane"
    static let scrollMemory = "scrollMemory"
    static let editorApp = "editorApp"
    static let wrapCode = "wrapCode"
    static let numberHeadings = "numberHeadings"
    static let followEdits = "followEdits"
    static let lineNumbers = "lineNumbers"
    static let searchScope = "searchScope"
    static let foldMemory = "foldMemory"
    static let sidebarWidth = "sidebarWidth"

    static var defaultPDFFolder: String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Desktop"
    }

    /// Copies settings saved under the pre-1.0.2 bundle ID, once. Must run before `register()`,
    /// because registered defaults make every key look already set.
    static func migrateFromOldBundleID() {
        let defaults = UserDefaults.standard
        let marker = "migratedFromOldBundleID"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        guard let old = UserDefaults(suiteName: "io.github.rboundi.mdreader") else { return }
        let keys = [
            appearance, readingFont, zoom, pdfFolder, askWhereToSave, restoreTabs, openTabs,
            recentFiles, contentWidth, printHeaderFooter, outlineVisible, checkForUpdates,
        ]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            appearance: AppearanceMode.system.rawValue,
            readingFont: ReadingFont.sans.rawValue,
            zoom: 1.0,
            pdfFolder: defaultPDFFolder,
            askWhereToSave: true,
            restoreTabs: true,
            contentWidth: ContentWidth.medium.rawValue,
            printHeaderFooter: true,
            outlineVisible: false,
            checkForUpdates: true,
            wrapCode: false,
            numberHeadings: false,
            followEdits: true,
            lineNumbers: false,
        ])
    }

    static var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: appearance) ?? "") ?? .system
    }

    static var font: ReadingFont {
        ReadingFont(rawValue: UserDefaults.standard.string(forKey: readingFont) ?? "") ?? .sans
    }

    static var width: ContentWidth {
        ContentWidth(rawValue: UserDefaults.standard.string(forKey: contentWidth) ?? "") ?? .medium
    }

    static var zoomLevel: Double {
        get { UserDefaults.standard.double(forKey: zoom) }
        set { UserDefaults.standard.set(min(max(newValue, 0.5), 3.0), forKey: zoom) }
    }
}

/// custom.css in Application Support, applied on top of the built-in styles.
enum CustomCSS {
    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("MDReader/custom.css")
    }

    static func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Creates the file if needed and opens it in the chosen editor, or TextEdit.
    @MainActor static func edit() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
                /* Styles here apply on top of MDReader's own. Changes show when you save. For example:

                .markdown-body { font-size: 18px; }
                .markdown-body h1, .markdown-body h2 { border: 0; }
                */

                """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        AppState.shared.reader.watchCustomCSS()
        // The Markdown editor only if it handles CSS files; otherwise TextEdit.
        let editor = AppState.shared.editorURL.flatMap { editor in
            NSWorkspace.shared.urlsForApplications(toOpen: url).contains { $0.standardizedFileURL == editor.standardizedFileURL }
                ? editor : nil
        }
        let app = editor ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Colors shared between the native chrome and the rendered page (keep in sync with style.css).
/// Computed on each use: macOS only re-resolves dynamic colors between light and dark, and Light and
/// Sepia are both light, so a cached dynamic color would keep the old theme.
enum Palette {
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A color that follows light and dark mode.
    private static func lightDark(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    private static var sepia: Bool { Prefs.appearanceMode == .sepia }

    static var page: NSColor { sepia ? rgb(0xF7F0E3) : lightDark(.white, rgb(0x1C1C1E)) }

    /// Body text, for the editor.
    static var text: NSColor { sepia ? rgb(0x3D3326) : lightDark(rgb(0x1F2328), rgb(0xE6E6E8)) }

    /// Tab bar, sidebar and toolbar: the system window color, or a darker sepia.
    static var chrome: NSColor { sepia ? rgb(0xECE2CF) : .windowBackgroundColor }
}
