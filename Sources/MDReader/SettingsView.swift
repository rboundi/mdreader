import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(Prefs.readingFont) private var font = ReadingFont.sans.rawValue
    @AppStorage(Prefs.zoom) private var zoom = 1.0
    @AppStorage(Prefs.pdfFolder) private var pdfFolder = Prefs.defaultPDFFolder
    @AppStorage(Prefs.askWhereToSave) private var askWhereToSave = true
    @AppStorage(Prefs.restoreTabs) private var restoreTabs = true
    @AppStorage(Prefs.contentWidth) private var contentWidth = ContentWidth.medium.rawValue
    @AppStorage(Prefs.printHeaderFooter) private var printHeaderFooter = true
    @AppStorage(Prefs.checkForUpdates) private var checkForUpdates = true
    @AppStorage(Prefs.editorApp) private var editorPath = ""
    @AppStorage(Prefs.numberHeadings) private var numberHeadings = false
    @AppStorage(Prefs.wrapCode) private var wrapCode = false
    @AppStorage(Prefs.followEdits) private var followEdits = true
    @AppStorage(Prefs.lineNumbers) private var lineNumbers = false
    @AppStorage(Prefs.codeLineNumbers) private var codeLineNumbers = false
    @AppStorage(Prefs.smartPunctuation) private var smartPunctuation = false
    @AppStorage(Prefs.justify) private var justify = false
    @AppStorage(Prefs.lineHeight) private var lineHeight = "normal"
    @AppStorage(Prefs.paperSize) private var paperSize = PaperSize.system.rawValue
    @AppStorage(Prefs.margins) private var margins = PageMargins.normal.rawValue
    @AppStorage(Prefs.editPreview) private var editPreview = true

    private var editorName: String? {
        editorPath.isEmpty ? nil
            : FileManager.default.displayName(atPath: editorPath).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        // One short page per tab, so the window fits any screen.
        TabView {
            page { general }.tabItem { Label("General", systemImage: "gearshape") }
            page { appearancePage }.tabItem { Label("Appearance", systemImage: "textformat.size") }
            page { markdown }.tabItem { Label("Markdown", systemImage: "number") }
            page { editing }.tabItem { Label("Editing", systemImage: "pencil") }
            page { export }.tabItem { Label("Export", systemImage: "arrow.down.doc") }
        }
        .frame(width: 480)
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var general: some View {
        Section {
            Toggle("Reopen tabs from last session", isOn: $restoreTabs)
            Toggle("Scroll to edits when a file changes", isOn: $followEdits)
        }
        Section {
            Toggle("Check for updates", isOn: $checkForUpdates)
            HStack {
                Text("Command line tool")
                Spacer()
                Text("mdr file.md").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                Button("Install…") { AppState.shared.installCommandLineTool() }
            }
        }
    }

    @ViewBuilder
    private var appearancePage: some View {
        Section {
            Picker("Theme", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
        Section {
            Picker("Reading font", selection: $font) {
                ForEach(ReadingFont.allCases) { Text($0.label).tag($0.rawValue) }
            }
            HStack {
                Text("Text size")
                Spacer()
                Text("\(Int((zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: $zoom, in: 0.5...3.0, step: 0.1).labelsHidden()
            }
            Picker("Text width", selection: $contentWidth) {
                ForEach(ContentWidth.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Line spacing", selection: $lineHeight) {
                Text("Compact").tag("compact")
                Text("Normal").tag("normal")
                Text("Relaxed").tag("relaxed")
            }
            Toggle("Justify text", isOn: $justify)
        }
        Section {
            HStack {
                Text("Custom CSS")
                Spacer()
                Button("Edit…") { CustomCSS.edit() }
            }
        }
    }

    @ViewBuilder
    private var markdown: some View {
        Section {
            Toggle("Smart quotes and dashes", isOn: $smartPunctuation)
            Toggle("Number headings", isOn: $numberHeadings)
        }
        Section("Code") {
            Toggle("Wrap long lines in code blocks", isOn: $wrapCode)
            Toggle("Line numbers in code blocks", isOn: $codeLineNumbers)
            Toggle("Line numbers in Markdown source", isOn: $lineNumbers)
        }
    }

    @ViewBuilder
    private var editing: some View {
        Section {
            HStack {
                Text("Edit with")
                Spacer()
                Text(editorName ?? "MDReader").foregroundStyle(.secondary)
                if editorName != nil {
                    Button("Use MDReader") {
                        UserDefaults.standard.removeObject(forKey: Prefs.editorApp)
                        editorPath = ""
                    }
                }
                Button("Choose…") {
                    AppState.shared.chooseEditor()
                    editorPath = UserDefaults.standard.string(forKey: Prefs.editorApp) ?? ""
                }
            }
            Toggle("Show preview while editing", isOn: Binding(
                get: { editPreview }, set: { AppState.shared.setPreviewWhileEditing($0) }))
        }
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Neutrino")
                    Text("A code editor with regex find and replace, for longer edits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let neutrino = AppState.shared.neutrinoURL {
                    if editorPath == neutrino.path {
                        Text("In use").foregroundStyle(.secondary)
                    } else {
                        Button("Use Neutrino") {
                            AppState.shared.useNeutrinoAsEditor()
                            editorPath = neutrino.path
                        }
                    }
                } else {
                    Button("Get Neutrino") { NSWorkspace.shared.open(AppState.neutrinoPage) }
                }
            }
        }
    }

    @ViewBuilder
    private var export: some View {
        Section("PDF") {
            HStack {
                Text("Default folder")
                Spacer()
                Text((pdfFolder as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…", action: chooseFolder)
            }
            Toggle("Ask where to save each time", isOn: $askWhereToSave)
            Toggle("Add header and page numbers", isOn: $printHeaderFooter)
            Picker("Paper size", selection: $paperSize) {
                ForEach(PaperSize.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Margins", selection: $margins) {
                ForEach(PageMargins.allCases) { Text($0.label).tag($0.rawValue) }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: pdfFolder)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { pdfFolder = url.path }
    }
}
