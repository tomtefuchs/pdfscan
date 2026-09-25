import ImageCaptureCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var scanner: ScannerService

    var body: some View {
        NavigationSplitView {
            PageListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
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
                        Label("Abbrechen", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        model.startScan()
                    } label: {
                        Label("Scannen", systemImage: "scanner")
                    }
                    .disabled(scanner.selectedScanner == nil || scanner.phase == .connecting)
                    .help("Alle Blätter im Einzug scannen und an das aktuelle Dokument anhängen (⌘R)")
                }
                Button {
                    model.showImportPanel()
                } label: {
                    Label("Importieren", systemImage: "square.and.arrow.down")
                }
                .help("Bilder oder PDFs importieren und per OCR durchsuchbar machen")
            }
        }
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
    }
}

private struct ScannerPicker: View {
    @EnvironmentObject private var scanner: ScannerService

    var body: some View {
        Picker("Scanner", selection: Binding<ObjectIdentifier?>(
            get: { scanner.selectedScanner.map(ObjectIdentifier.init) },
            set: { id in scanner.select(scanner.scanners.first { ObjectIdentifier($0) == id }) }
        )) {
            if scanner.scanners.isEmpty {
                Text("Kein Scanner gefunden").tag(ObjectIdentifier?.none)
            }
            ForEach(scanner.scanners, id: \.self) { device in
                Text(scanner.name(of: device)).tag(Optional(ObjectIdentifier(device)))
            }
        }
        .frame(minWidth: 200)
        .help("Scanner muss in der App „Digitalbilder“ sichtbar sein (Epson-ICA-Treiber)")
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var scanner: ScannerService

    var body: some View {
        HStack(spacing: 10) {
            scannerState
            Divider().frame(height: 14)
            if model.pendingJobs > 0 || model.isSaving {
                ProgressView().controlSize(.small)
            }
            Text(model.status)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.pendingJobs > 0 {
                Text("· Texterkennung: \(model.pendingJobs) ausstehend")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.lastSavedURL != nil {
                Button("Im Finder zeigen") { model.revealLastSaved() }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder private var scannerState: some View {
        switch scanner.phase {
        case .idle:
            Label(scanner.selectedScanner == nil ? "Suche Scanner…" : "Nicht verbunden", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .connecting:
            Label("Verbinde…", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .ready:
            Label(scanner.supportsDuplex ? "Bereit (Duplex möglich)" : "Bereit", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .scanning:
            Label("Scanne", systemImage: "circle.fill")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}
