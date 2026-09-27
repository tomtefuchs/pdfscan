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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(documentCount == 1 ? "1 Dokument" : "\(documentCount) Dokumente")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(model.includedPageCount) von \(model.pages.count) Seiten")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 8) {
                    Button {
                        model.newDocument()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: Theme.iconSize, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .help("Alle Seiten verwerfen")
                    .disabled(model.pages.isEmpty)
                    Button {
                        model.autoSplit()
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: Theme.iconSize, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .help("Automatisch in Dokumente trennen (⇧⌘T) – überschreibt manuelle Trennstellen")
                    .disabled(model.pages.isEmpty)
                    Button {
                        model.clearDocumentMarkers()
                    } label: {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: Theme.iconSize, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .help("Alle Trennstellen entfernen – alles wird ein Dokument (⌥⌘T)")
                    .disabled(!model.hasDocumentMarkers)
                    Spacer()
                    Button {
                        model.save()
                    } label: {
                        IconLabel(documentCount > 1 ? "\(documentCount) PDFs speichern" : "PDF speichern",
                                  systemImage: "square.and.arrow.down.on.square.fill", size: Theme.smallIconSize)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pages.isEmpty || model.isSaving)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(14)

            Rectangle().fill(Theme.border).frame(height: 1)

            List(selection: $model.selection) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    PageRow(page: page, number: index + 1, document: documentNumbers[page.id],
                            startsNewDocument: index > 0 && page.startsDocument, reason: page.splitReason)
                        .tag(page.id)
                        .contextMenu {
                            PageActions(pageID: page.id, excluded: page.excluded, startsDocument: page.startsDocument)
                        }
                }
                .onMove { model.move(from: $0, to: $1) }
                .onDelete { offsets in model.delete(Set(offsets.map { model.pages[$0].id })) }
            }
            .scrollContentBackground(.hidden)
            .onDeleteCommand {
                if let id = model.selection { model.delete([id]) }
            }
            .overlay {
                if model.pages.isEmpty { EmptyState() }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(spacing: 0) {
                ToggleRow(title: "Beidseitig scannen", systemImage: "doc.on.doc", isOn: $duplex)
                Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 44)
                ToggleRow(title: "Nach jedem Scan speichern", systemImage: "bolt.fill", isOn: $autoSave)
                    .help("Stapelmodus: jeder Einzug wird ohne Rückfrage gespeichert")
            }
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(Theme.sidebar)
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Noch keine Seiten")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Blätter in den Einzug legen und „Scannen“ drücken – oder Bilder und PDFs hierher ziehen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
            Button {
                model.showImportPanel()
            } label: {
                IconLabel("Dateien importieren", systemImage: "square.and.arrow.down.fill", size: Theme.smallIconSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(24)
    }
}

private struct PageRow: View {
    @EnvironmentObject private var model: AppModel
    let page: ScanPage
    let number: Int
    let document: Int?
    let startsNewDocument: Bool
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if startsNewDocument {
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                        .font(.system(size: Theme.smallIconSize, weight: .semibold))
                    if let reason {
                        Text(reason).lineLimit(1)
                    }
                    Rectangle().frame(height: 1).opacity(0.6)
                }
                .foregroundStyle(Theme.accent)
                .font(.caption.weight(.medium))
                .padding(.top, 4)
                .help("Hier beginnt ein neues Dokument")
            }
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = page.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.raised)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: Theme.thumbnail.width, height: Theme.thumbnail.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                if let document {
                    Text("Dokument \(document)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text("Seite \(number)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                detail
                    .font(.caption)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !page.excluded },
                                     set: { model.setExcluded(page.id, !$0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Seite ins PDF übernehmen")
        }
        .padding(.vertical, 4)
        .opacity(page.excluded ? 0.45 : 1)
    }

    @ViewBuilder private var detail: some View {
        switch page.state {
        case .processing:
            Label("Texterkennung läuft…", systemImage: "hourglass")
                .foregroundStyle(Theme.warning)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
        case .done:
            if page.isBlank {
                Label("Leerseite", systemImage: "doc")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                HStack(spacing: 8) {
                    Label("\(page.wordCount) Wörter", systemImage: "text.alignleft")
                    if page.isHandwritten {
                        Label("Handschrift", systemImage: "scribble")
                            .help("Text teilweise aus dem Handschrift-Durchgang")
                    }
                }
                .foregroundStyle(Theme.textSecondary)
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
        Button("Handschrift erkennen") { model.recognizeHandwriting(pageID) }
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
                    Theme.window
                    if let image = preview ?? page.thumbnail {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                            .padding(24)
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

                VStack(alignment: .leading, spacing: 0) {
                    IconLabel("Erkannter Text", systemImage: "text.viewfinder", size: Theme.smallIconSize)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                    ScrollView {
                        Text(page.text.isEmpty ? "Kein Text erkannt." : page.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .foregroundStyle(page.text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    }
                }
                .frame(minHeight: 100, idealHeight: 200)
                .background(Theme.surface)
            }
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button { model.setStartsDocument(page.id, !page.startsDocument) } label: {
                        IconLabel(page.startsDocument ? "Trennung entfernen" : "Neues Dokument ab hier",
                                  systemImage: "scissors")
                    }
                    .keyboardShortcut("t")
                    .help("Mit dieser Seite beginnt ein neues Dokument (⌘T)")
                    Button { model.rotate(page.id, clockwise: 270) } label: {
                        IconLabel("Nach links drehen", systemImage: "rotate.left.fill")
                    }
                    Button { model.rotate(page.id, clockwise: 90) } label: {
                        IconLabel("Nach rechts drehen", systemImage: "rotate.right.fill")
                    }
                    Button { model.recognizeHandwriting(page.id) } label: {
                        IconLabel("Handschrift erkennen", systemImage: "scribble")
                    }
                    .help("Seite noch einmal mit Handschrift-Durchgang erkennen")
                    Button { model.delete([page.id]) } label: {
                        IconLabel("Seite löschen", systemImage: "trash.fill")
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
                Text("Keine Seite ausgewählt")
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.window)
        }
    }
}
