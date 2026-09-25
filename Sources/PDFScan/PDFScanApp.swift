import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nötig, wenn die App per `swift run` ohne .app-Bundle gestartet wird.
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

    init() {
        AppSettings.registerDefaults()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        Window("PDFScan", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.scanner)
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
                Divider()
                Button("Automatisch in Dokumente trennen") { model.autoSplit() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.pages.isEmpty)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
