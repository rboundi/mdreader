import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
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

/// Colors shared between the native chrome and the rendered page (keep in sync with style.css).
enum Palette {
    static let page = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1)
            : NSColor.white
    }
}
