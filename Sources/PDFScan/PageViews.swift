import PDFScanCore
import SwiftUI

struct PageListView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.duplex) private var duplex = true
    @AppStorage(SettingsKey.autoSaveAfterScan) private var autoSave = false

    var body: some View {
        let documentNumbers = model.documentNumbers
        let documentCount = Set(documentNumbers.values).count
        VStack(spacing: 0) {
            HStack {
                Text("\(documentCount) \(documentCount == 1 ? "Dokument" : "Dokumente") · \(model.includedPageCount) von \(model.pages.count) Seiten")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Verwerfen") { model.newDocument() }
                    .disabled(model.pages.isEmpty)
                Button(documentCount > 1 ? "\(documentCount) PDFs speichern" : "PDF speichern") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pages.isEmpty || model.isSaving)
            }
            .padding(12)

            Divider()

            List(selection: $model.selection) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    PageRow(page: page, number: index + 1, document: documentNumbers[page.id],
                            startsNewDocument: index > 0 && page.startsDocument)
                        .tag(page.id)
                        .contextMenu {
                            PageActions(pageID: page.id, excluded: page.excluded, startsDocument: page.startsDocument)
                        }
                }
                .onMove { model.move(from: $0, to: $1) }
                .onDelete { offsets in model.delete(Set(offsets.map { model.pages[$0].id })) }
            }
            .onDeleteCommand {
                if let id = model.selection { model.delete([id]) }
            }
            .overlay {
                if model.pages.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.viewfinder")
                            .font(.system(size: 36))
                        Text("Blätter in den Einzug legen und „Scannen“ drücken – oder Bilder/PDFs hierher ziehen.")
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Beidseitig scannen (Duplex)", isOn: $duplex)
                Toggle("Nach jedem Scan automatisch als PDF speichern", isOn: $autoSave)
                    .help("Stapelmodus: jeder Einzug wird ein eigenes PDF")
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .padding(12)
        }
    }
}

private struct PageRow: View {
    @EnvironmentObject private var model: AppModel
    let page: ScanPage
    let number: Int
    let document: Int?
    let startsNewDocument: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if startsNewDocument {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                    Rectangle().frame(height: 1)
                }
                .foregroundStyle(Color.accentColor)
                .font(.caption)
                .help("Hier beginnt ein neues Dokument")
            }
            row
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = page.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 56, height: 72)
            .border(.separator)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.map { "Dokument \($0) · Seite \(number)" } ?? "Seite \(number)")
                    .fontWeight(.medium)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !page.excluded },
                                     set: { model.setExcluded(page.id, !$0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Seite ins PDF übernehmen")
        }
        .padding(.vertical, 2)
        .opacity(page.excluded ? 0.45 : 1)
    }

    @ViewBuilder private var detail: some View {
        switch page.state {
        case .processing:
            Text("Texterkennung läuft…")
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .done:
            if page.isBlank {
                Text("Leerseite")
            } else {
                Text("\(page.wordCount) Wörter erkannt")
            }
        }
    }
}

private struct PageActions: View {
    @EnvironmentObject private var model: AppModel
    let pageID: ScanPage.ID
    let excluded: Bool
    let startsDocument: Bool

    var body: some View {
        Button(startsDocument ? "Trennung entfernen" : "Neues Dokument ab dieser Seite") {
            model.setStartsDocument(pageID, !startsDocument)
        }
        Divider()
        Button("Nach links drehen") { model.rotate(pageID, clockwise: 270) }
        Button("Nach rechts drehen") { model.rotate(pageID, clockwise: 90) }
        Button("Um 180° drehen") { model.rotate(pageID, clockwise: 180) }
        Divider()
        Button(excluded ? "Ins PDF übernehmen" : "Nicht ins PDF übernehmen") {
            model.setExcluded(pageID, !excluded)
        }
        Button("Löschen", role: .destructive) { model.delete([pageID]) }
    }
}

struct PageDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var preview: NSImage?

    var body: some View {
        if let page = model.selectedPage {
            VSplitView {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let image = preview ?? page.thumbnail {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .shadow(radius: 3)
                            .padding(16)
                    }
                }
                .frame(minHeight: 250)
                .task(id: page.url) {
                    preview = nil
                    let url = page.url
                    let image = await Task.detached(priority: .userInitiated) {
                        ImageOps.thumbnail(at: url, maxPixelSize: 2000)
                    }.value
                    preview = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                }

                ScrollView {
                    Text(page.text.isEmpty ? "Kein Text erkannt." : page.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .foregroundStyle(page.text.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
                }
                .frame(minHeight: 80, idealHeight: 180)
            }
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button { model.setStartsDocument(page.id, !page.startsDocument) } label: {
                        Label(page.startsDocument ? "Trennung entfernen" : "Neues Dokument ab hier",
                              systemImage: "scissors")
                    }
                    .keyboardShortcut("t")
                    .help("Mit dieser Seite beginnt ein neues Dokument (⌘T)")
                    Button { model.rotate(page.id, clockwise: 270) } label: {
                        Label("Nach links drehen", systemImage: "rotate.left")
                    }
                    Button { model.rotate(page.id, clockwise: 90) } label: {
                        Label("Nach rechts drehen", systemImage: "rotate.right")
                    }
                    Button { model.delete([page.id]) } label: {
                        Label("Seite löschen", systemImage: "trash")
                    }
                }
            }
        } else {
            Text("Keine Seite ausgewählt")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
