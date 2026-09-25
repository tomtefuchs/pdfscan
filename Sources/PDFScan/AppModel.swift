import AppKit
import Foundation
import PDFScanCore
import UniformTypeIdentifiers

struct ScanPage: Identifiable {
    enum State: Equatable {
        case processing
        case done
        case failed(String)
    }

    let id = UUID()
    var url: URL
    var dpi: Double
    var thumbnail: NSImage?
    var lines: [RecognizedLine] = []
    var state: State = .processing
    var isBlank = false
    /// Nicht ins PDF übernehmen (automatisch bei Leerseiten, oder vom Nutzer abgewählt).
    var excluded = false
    /// Mit dieser Seite beginnt ein neues Dokument (Trennstelle).
    var startsDocument = false

    var text: String { lines.map(\.text).joined(separator: "\n") }
    var wordCount: Int { lines.reduce(0) { $0 + $1.text.split(separator: " ").count } }
}

/// Hält das aktuelle Dokument (Seitenliste) und verbindet Scanner, Texterkennung und PDF-Export.
final class AppModel: ObservableObject {
    @Published var pages: [ScanPage] = []
    @Published var selection: ScanPage.ID?
    @Published var status = "Bereit"
    @Published var errorMessage: String?
    @Published private(set) var pendingJobs = 0
    @Published private(set) var isSaving = false
    @Published private(set) var lastSavedURL: URL?

    let scanner: ScannerService

    private let workDirectory: URL
    private let pagesDirectory: URL
    /// Seriell: Vision nutzt intern ohnehin mehrere Kerne, so bleibt der Speicherbedarf klein.
    private let queue = DispatchQueue(label: "pdfscan.processing", qos: .userInitiated)
    private let jobs = DispatchGroup()

    init() {
        let fm = FileManager.default
        workDirectory = fm.temporaryDirectory.appendingPathComponent("PDFScan", isDirectory: true)
        pagesDirectory = workDirectory.appendingPathComponent("pages", isDirectory: true)
        let incoming = workDirectory.appendingPathComponent("incoming", isDirectory: true)
        try? fm.removeItem(at: workDirectory)
        try? fm.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: incoming, withIntermediateDirectories: true)

        scanner = ScannerService(downloadDirectory: incoming)
        scanner.onPageScanned = { [weak self] url, dpi in self?.addScannedFile(url, dpi: dpi) }
        scanner.onScanFinished = { [weak self] error in self?.scanFinished(error) }
    }

    var selectedPage: ScanPage? {
        pages.first { $0.id == selection }
    }

    var includedPageCount: Int {
        pages.filter { !$0.excluded }.count
    }

    // MARK: - Scannen

    func startScan() {
        let settings = AppSettings.current
        status = "Scanne…"
        scanner.startScan(.init(resolution: settings.resolution,
                                grayscale: settings.grayscale,
                                duplex: settings.duplex))
    }

    private func addScannedFile(_ url: URL, dpi: Double) {
        let destination = pagesDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "png" : url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            status = "Seite konnte nicht übernommen werden: \(error.localizedDescription)"
            return
        }
        addPage(url: destination, dpi: ImageOps.dpi(at: destination) ?? dpi)
        status = "\(pages.count) Seiten gescannt…"
    }

    private func scanFinished(_ error: Error?) {
        if let error {
            status = "Scan beendet: \(error.localizedDescription)"
        } else {
            status = "Scan abgeschlossen – \(pages.count) Seiten"
        }
        if AppSettings.current.autoSaveAfterScan, !pages.isEmpty {
            save()
        }
    }

    // MARK: - Import

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Bilder oder PDFs importieren (z. B. aus Epson ScanSmart oder alte Scans ohne Texterkennung)"
        if panel.runModal() == .OK {
            importFiles(panel.urls)
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fallbackDPI = Double(AppSettings.current.resolution)
        let directory = pagesDirectory
        status = "Importiere \(urls.count) Datei(en)…"
        pendingJobs += 1
        jobs.enter()
        queue.async { [weak self] in
            var imported: [(URL, Double)] = []
            var failures: [String] = []
            func store(_ image: CGImage, dpi: Double) {
                let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                if (try? ImageOps.writePNG(image, to: target, dpi: dpi)) != nil {
                    imported.append((target, dpi))
                }
            }
            for url in urls {
                let before = imported.count
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                    ImageOps.renderPDFPages(at: url, dpi: 300) { store($0, dpi: 300) }
                } else {
                    let dpi = ImageOps.dpi(at: url) ?? fallbackDPI
                    for image in ImageOps.loadImages(at: url) { store(image, dpi: dpi) }
                }
                if imported.count == before { failures.append(url.lastPathComponent) }
            }
            let pagesFound = imported
            let unreadable = failures
            DispatchQueue.main.async {
                guard let self else { return }
                pagesFound.forEach { self.addPage(url: $0.0, dpi: $0.1) }
                self.status = unreadable.isEmpty
                    ? "\(pagesFound.count) Seiten importiert"
                    : "Nicht lesbar: \(unreadable.joined(separator: ", "))"
                self.pendingJobs -= 1
                self.jobs.leave()
            }
        }
    }

    // MARK: - Seiten bearbeiten

    private func addPage(url: URL, dpi: Double) {
        let page = ScanPage(url: url, dpi: dpi)
        pages.append(page)
        if selection == nil { selection = page.id }
        process(page.id, rotation: 0, detectOrientation: AppSettings.current.autoRotate, isInitial: true)
    }

    func rotate(_ id: ScanPage.ID, clockwise degrees: Int) {
        process(id, rotation: degrees, detectOrientation: false, isInitial: false)
    }

    func setExcluded(_ id: ScanPage.ID, _ excluded: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].excluded = excluded
    }

    func setStartsDocument(_ id: ScanPage.ID, _ starts: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].startsDocument = starts
    }

    /// Aufteilung der übernommenen Seiten in Dokumente (Seitenindizes je Dokument).
    var documentGroups: [[Int]] {
        DocumentSplitter.group(startsDocument: pages.map(\.startsDocument), excluded: pages.map(\.excluded))
    }

    /// Dokumentnummer (ab 1) je übernommener Seite, für die Anzeige.
    var documentNumbers: [ScanPage.ID: Int] {
        var numbers: [ScanPage.ID: Int] = [:]
        for (number, group) in documentGroups.enumerated() {
            for index in group { numbers[pages[index].id] = number + 1 }
        }
        return numbers
    }

    func delete(_ ids: Set<ScanPage.ID>) {
        for page in pages where ids.contains(page.id) {
            try? FileManager.default.removeItem(at: page.url)
        }
        pages.removeAll { ids.contains($0.id) }
        if let selection, ids.contains(selection) { self.selection = pages.first?.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    func newDocument() {
        if !pages.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Aktuelles Dokument verwerfen?"
            alert.informativeText = "\(pages.count) Seiten wurden noch nicht gespeichert."
            alert.addButton(withTitle: "Verwerfen")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        delete(Set(pages.map(\.id)))
        status = "Neues Dokument"
    }

    /// Drehen (optional automatisch), Texterkennung, Leerseiten-Erkennung und Vorschaubild – im Hintergrund.
    private func process(_ id: ScanPage.ID, rotation: Int, detectOrientation: Bool, isInitial: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].state = .processing
        let url = pages[index].url
        let dpi = pages[index].dpi
        let settings = AppSettings.current
        pendingJobs += 1
        jobs.enter()
        queue.async { [weak self, jobs] in
            let result = PageProcessor.run(url: url, dpi: dpi, rotation: rotation,
                                           detectOrientation: detectOrientation, languages: settings.languages)
            DispatchQueue.main.async {
                defer { jobs.leave() }
                guard let self else { return }
                self.pendingJobs -= 1
                guard let index = self.pages.firstIndex(where: { $0.id == id }) else {
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }
                self.pages[index].url = result.url
                self.pages[index].lines = result.lines
                self.pages[index].isBlank = result.isBlank
                if let thumbnail = result.thumbnail { self.pages[index].thumbnail = thumbnail }
                self.pages[index].state = result.error.map { ScanPage.State.failed($0) } ?? .done
                if isInitial, settings.skipBlankPages, result.isBlank {
                    self.pages[index].excluded = true
                }
            }
        }
    }

    // MARK: - Speichern

    func save() {
        guard !pages.isEmpty, !isSaving else { return }
        isSaving = true
        if pendingJobs > 0 { status = "Warte auf Texterkennung…" }
        jobs.notify(queue: .main) { [weak self] in self?.writePDF() }
    }

    private func writePDF() {
        let settings = AppSettings.current
        let snapshot = pages.filter { $0.state != .processing }
        let groups = DocumentSplitter.group(startsDocument: snapshot.map(\.startsDocument),
                                            excluded: snapshot.map(\.excluded))
        guard !groups.isEmpty else {
            isSaving = false
            status = "Keine Seiten zum Speichern (alle abgewählt oder leer)"
            return
        }

        let documents = groups.map { group in
            group.map { PDFPageSource(imageURL: snapshot[$0].url, dpi: snapshot[$0].dpi, lines: snapshot[$0].lines) }
        }
        let naming = DocumentNaming(prefix: settings.filePrefix)
        let folder = settings.outputFolder
        let savedIDs = Set(snapshot.map(\.id))
        let workDirectory = self.workDirectory
        let now = Date()

        status = documents.count == 1
            ? "Erzeuge PDF mit \(documents[0].count) Seiten…"
            : "Erzeuge \(documents.count) PDFs…"
        queue.async { [weak self] in
            var temporaries: [URL] = []
            let outcome: Result<[URL], Error> = Result {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for pages in documents {
                    let temporary = workDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
                    temporaries.append(temporary)
                    let title = "Scan \(Self.titleFormatter.string(from: now))"
                    try SearchablePDFWriter.write(pages, to: temporary, title: title, jpegQuality: settings.jpegQuality)
                }
                // Erst wenn alle PDFs fertig sind, mit einer freien Batch-Nummer in den Zielordner verschieben.
                var batch = naming.nextBatch(in: folder, date: now)
                var targets: [URL] = []
                repeat {
                    targets = documents.indices.map {
                        folder.appendingPathComponent(naming.fileName(date: now, batch: batch, document: $0 + 1))
                    }
                    if targets.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        batch += 1
                        targets = []
                    }
                } while targets.isEmpty
                for (temporary, target) in zip(temporaries, targets) {
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
                return targets
            }
            let written = temporaries
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                switch outcome {
                case .success(let urls):
                    self.delete(savedIDs)
                    self.lastSavedURL = urls.first
                    self.status = urls.count == 1
                        ? "Gespeichert: \(urls[0].lastPathComponent)"
                        : "\(urls.count) Dokumente gespeichert: \(urls[0].lastPathComponent) … \(urls[urls.count - 1].lastPathComponent)"
                case .failure(let error):
                    written.forEach { try? FileManager.default.removeItem(at: $0) }
                    self.errorMessage = error.localizedDescription
                    self.status = "Speichern fehlgeschlagen"
                }
            }
        }
    }

    func revealLastSaved() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
