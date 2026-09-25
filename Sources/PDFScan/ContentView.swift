import ImageCaptureCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var scanner: ScannerService

    var body: some View {
        NavigationSplitView {
            PageListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            PageDetailView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ScannerPicker()
                if scanner.phase == .scanning {
                    Button {
                        scanner.cancelScan()
                    } label: {
                        IconLabel("Abbrechen", systemImage: "stop.circle.fill")
                    }
                    .tint(Theme.danger)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        model.startScan()
                    } label: {
                        IconLabel("Scannen", systemImage: "scanner.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(scanner.selectedScanner == nil || scanner.phase == .connecting)
                    .help("Alle Blätter im Einzug scannen und an das aktuelle Dokument anhängen (⌘R)")
                }
                Button {
                    model.showImportPanel()
                } label: {
                    IconLabel("Importieren", systemImage: "square.and.arrow.down.fill")
                }
                .help("Bilder oder PDFs importieren und per OCR durchsuchbar machen")
            }
        }
        .toolbarBackground(Theme.window, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar()
        }
        .alert("Fehler", isPresented: Binding(get: { model.errorMessage != nil },
                                              set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls)
            return true
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

private struct ScannerPicker: View {
    @EnvironmentObject private var scanner: ScannerService

    var body: some View {
        Picker(selection: Binding<ObjectIdentifier?>(
            get: { scanner.selectedScanner.map(ObjectIdentifier.init) },
            set: { id in scanner.select(scanner.scanners.first { ObjectIdentifier($0) == id }) }
        )) {
            if scanner.scanners.isEmpty {
                Text("Kein Scanner gefunden").tag(ObjectIdentifier?.none)
            }
            ForEach(scanner.scanners, id: \.self) { device in
                Text(scanner.name(of: device)).tag(Optional(ObjectIdentifier(device)))
            }
        } label: {
            IconLabel("Scanner", systemImage: "printer.fill")
        }
        .frame(minWidth: 220)
        .help("Scanner muss in der App „Digitalbilder“ sichtbar sein (Epson-ICA-Treiber)")
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var scanner: ScannerService

    var body: some View {
        HStack(spacing: 12) {
            scannerState
            if model.pendingJobs > 0 || model.isSaving {
                ProgressView().controlSize(.small)
            }
            Text(model.status)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Theme.textPrimary)
            if model.pendingJobs > 0 {
                Text("Texterkennung: \(model.pendingJobs) ausstehend")
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if model.lastSavedURL != nil {
                Button {
                    model.revealLastSaved()
                } label: {
                    IconLabel("Im Finder zeigen", systemImage: "folder.fill", size: Theme.smallIconSize)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.raised)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var scannerState: some View {
        switch scanner.phase {
        case .idle:
            StatusPill(text: scanner.selectedScanner == nil ? "Suche Scanner…" : "Nicht verbunden",
                       color: Theme.textSecondary)
        case .connecting:
            StatusPill(text: "Verbinde…", color: Theme.warning)
        case .ready:
            StatusPill(text: scanner.supportsDuplex ? "Bereit · Duplex" : "Bereit", color: Theme.success)
        case .scanning:
            StatusPill(text: "Scanne", color: Theme.accent)
        case .failed(let message):
            StatusPill(text: message, color: Theme.danger, systemImage: "exclamationmark.triangle.fill")
        }
    }
}
