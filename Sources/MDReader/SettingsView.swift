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

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Reading font", selection: $font) {
                    ForEach(ReadingFont.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Text width", selection: $contentWidth) {
                    ForEach(ContentWidth.allCases) { Text($0.label).tag($0.rawValue) }
                }
                HStack {
                    Text("Text size")
                    Spacer()
                    Text("\(Int((zoom * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("", value: $zoom, in: 0.5...3.0, step: 0.1).labelsHidden()
                }
            }
            Section("PDF Export") {
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
            }
            Section("Tabs") {
                Toggle("Reopen tabs from last session", isOn: $restoreTabs)
            }
            Section("Other") {
                Toggle("Check for updates", isOn: $checkForUpdates)
                HStack {
                    Text("Command line tool")
                    Spacer()
                    Text("mdr file.md").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    Button("Install…") { AppState.shared.installCommandLineTool() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
