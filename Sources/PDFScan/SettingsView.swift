import AppKit
import PDFScanCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.resolution) private var resolution = 300
    @AppStorage(SettingsKey.grayscale) private var grayscale = false
    @AppStorage(SettingsKey.duplex) private var duplex = true
    @AppStorage(SettingsKey.autoRotate) private var autoRotate = true
    @AppStorage(SettingsKey.skipBlankPages) private var skipBlankPages = true
    @AppStorage(SettingsKey.jpegQuality) private var jpegQuality = 0.7
    @AppStorage(SettingsKey.languages) private var languages = "de-DE,en-US"
    @AppStorage(SettingsKey.outputFolder) private var outputFolder = AppSettings.defaultOutputFolder
    @AppStorage(SettingsKey.filePrefix) private var filePrefix = "Scan_"
    @AppStorage(SettingsKey.autoSaveAfterScan) private var autoSave = false
    @AppStorage(SettingsKey.autoSplit) private var autoSplit = true
    @AppStorage(SettingsKey.paperFormat) private var paperFormat = PaperFormat.auto

    var body: some View {
        Form {
            Section("Scannen") {
                Picker("Auflösung", selection: $resolution) {
                    Text("200 dpi").tag(200)
                    Text("300 dpi (empfohlen)").tag(300)
                    Text("400 dpi (kleine Schrift)").tag(400)
                    Text("600 dpi").tag(600)
                }
                Picker("Farbe", selection: $grayscale) {
                    Text("Farbe").tag(false)
                    Text("Graustufen (kleinere Dateien)").tag(true)
                }
                Picker("Papierformat", selection: $paperFormat) {
                    ForEach(PaperFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .help("Automatisch: der Scanner erkennt die Blattgröße selbst. Feste Formate: kleinere Blätter mit Rand, größere abgeschnitten")
                Toggle("Beidseitig scannen (Duplex)", isOn: $duplex)
            }

            Section("Verarbeitung") {
                Picker("Texterkennung", selection: $languages) {
                    ForEach(AppSettings.languagePresets, id: \.value) { preset in
                        Text(preset.label).tag(preset.value)
                    }
                }
                Toggle("Seiten automatisch aufrecht drehen", isOn: $autoRotate)
                Toggle("Leerseiten automatisch weglassen", isOn: $skipBlankPages)
                Toggle("Automatisch in einzelne Dokumente trennen", isOn: $autoSplit)
                    .help("Zähler (1/3, Seite 1), Vorgangskennungen im Blattrand, Anschrift mit Anrede")
                LabeledContent("JPEG-Qualität") {
                    HStack {
                        Slider(value: $jpegQuality, in: 0.3...0.95, step: 0.05)
                        Text("\(Int(jpegQuality * 100)) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Speichern") {
                LabeledContent("Zielordner") {
                    HStack {
                        Text((outputFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Auswählen…", action: chooseFolder)
                    }
                }
                TextField("Präfix", text: $filePrefix)
                LabeledContent("Beispiel") {
                    Text(DocumentNaming(prefix: DocumentNaming.sanitizedPrefix(filePrefix))
                        .fileName(date: Date(), batch: 1, document: 1))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Toggle("Nach jedem Scan automatisch speichern (Stapelmodus)", isOn: $autoSave)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.window)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url.path
        }
    }
}
