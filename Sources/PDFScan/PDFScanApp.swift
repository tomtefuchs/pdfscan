import AppKit
import PDFScanCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nötig, wenn die App per `swift run` ohne .app-Bundle gestartet wird.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PDFScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var profiles: ProfileStore

    init() {
        OCRComparison.runIfRequested()
        AppSettings.registerDefaults()
        let store = ProfileStore(keys: SettingsKey.profileKeys)
        _profiles = StateObject(wrappedValue: store)
        _model = StateObject(wrappedValue: AppModel())
        // Jede Änderung in den Einstellungen landet im aktiven Profil.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { _ in store.captureActive() }
    }

    var body: some Scene {
        Window("PDFScan", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.scanner)
                .environmentObject(profiles)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neues Dokument") { model.newDocument() }
                    .keyboardShortcut("n")
                Button("Importieren…") { model.showImportPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Als PDF speichern") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(model.pages.isEmpty || model.isSaving)
            }
            CommandMenu("Scanner") {
                Button("Scannen") { model.startScan() }
                    .keyboardShortcut("r")
                Button("Scan abbrechen") { model.scanner.cancelScan() }
                    .keyboardShortcut(".")
                Button("Neu verbinden") { model.scanner.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Scanner-Info…") { model.showScannerInfo() }
                Divider()
                Button("Automatisch in Dokumente trennen") { model.autoSplit() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.pages.isEmpty)
                Button("Alle Trennstellen entfernen") { model.clearDocumentMarkers() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(!model.hasDocumentMarkers)
                Button("Trenn-Diagnose exportieren…") { model.exportSplitDiagnostics() }
                    .disabled(model.pages.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(profiles)
        }
    }
}
