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
    /// Warum die automatische Trennung hier geschnitten hat.
    var splitReason: String?
    /// Aufbereiteter Text für die automatische Trennung.
    var pageText: PageText?

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
    /// Trennstellen wurden von Hand geändert – dann nicht mehr automatisch überschreiben.
    @Published private(set) var markersEditedManually = false

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
        afterNewPages(thenSave: AppSettings.current.autoSaveAfterScan)
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
                self.afterNewPages(thenSave: false)
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
        pages[index].splitReason = starts ? "manuell" : nil
        markersEditedManually = true
    }

    // MARK: - Automatisch trennen

    /// Nach Scan oder Import: sobald die Texterkennung fertig ist, automatisch trennen (sofern
    /// eingeschaltet und nicht von Hand nachgearbeitet), danach optional speichern.
    private func afterNewPages(thenSave: Bool) {
        jobs.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if AppSettings.current.autoSplit {
                if self.markersEditedManually {
                    self.status += " – automatische Trennung übersprungen (Trennstellen von Hand geändert)"
                } else {
                    self.applyAutoSplit()
                }
            }
            if thenSave, !self.pages.isEmpty { self.save() }
        }
    }

    /// Trennstellen neu berechnen (überschreibt manuelle Änderungen).
    func autoSplit() {
        status = "Warte auf Texterkennung…"
        jobs.notify(queue: .main) { [weak self] in self?.applyAutoSplit() }
    }

    /// Wendet die Trennlogik auf die übernommenen Seiten an. Leerseiten bleiben außen vor, sonst
    /// würden Duplex-Rückseiten als Einschübe gelten. Einschübe werden hinter ihr Dokument gestellt,
    /// damit jedes Dokument zusammenhängend in der Liste steht (die Seitenfolge in den PDFs
    /// entspricht damit genau dem Original-Skript).
    private func applyAutoSplit() {
        let included = pages.indices.filter { !pages[$0].excluded }
        guard !included.isEmpty else { return }
        let texts = included.map { pages[$0].pageText ?? PageText(body: "", margin: "") }
        let result = DocumentBoundaryDetector.split(texts)

        // Weggelassene Seiten bleiben hinter der übernommenen Seite, der sie folgten.
        var leading: [ScanPage] = []
        var followers: [Int: [ScanPage]] = [:]
        var lastIncluded: Int?
        for index in pages.indices {
            if !pages[index].excluded {
                lastIncluded = index
            } else if let lastIncluded {
                followers[lastIncluded, default: []].append(pages[index])
            } else {
                leading.append(pages[index])
            }
        }

        var reordered = leading
        for (number, document) in result.documents.enumerated() {
            for (position, localIndex) in document.enumerated() {
                let original = included[localIndex]
                var page = pages[original]
                let isStart = position == 0 && number > 0
                page.startsDocument = isStart
                page.splitReason = isStart ? result.reasons[number].description : nil
                reordered.append(page)
                for var follower in followers[original] ?? [] {
                    follower.startsDocument = false
                    follower.splitReason = nil
                    reordered.append(follower)
                }
            }
        }
        pages = reordered
        markersEditedManually = false
        let inserts = result.reasons.filter { $0 == .insert }.count
        status = "Automatisch getrennt: \(result.documents.count) Dokumente"
            + (inserts > 0 ? " (\(inserts) Einschub/Einschübe herausgelöst)" : "")
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
        markersEditedManually = true
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
        markersEditedManually = false
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
                self.pages[index].pageText = result.pageText
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
                    if self.pages.isEmpty { self.markersEditedManually = false }
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

/// Die eigentliche Seitenverarbeitung (läuft im Hintergrund).
enum PageProcessor {
    struct Result {
        var url: URL
        var lines: [RecognizedLine] = []
        var isBlank = false
        var thumbnail: NSImage?
        var pageText: PageText?
        var error: String?
    }

    static func run(url: URL, dpi: Double, rotation: Int, detectOrientation: Bool, languages: [String]) -> Result {
        autoreleasepool { () -> Result in
            guard var image = ImageOps.loadImage(at: url) else {
                return Result(url: url, error: "Bild nicht lesbar")
            }
            var result = Result(url: url)

            var degrees = rotation
            if detectOrientation {
                degrees += TextRecognizer.uprightRotation(for: image)
            }
            if degrees % 360 != 0, let rotated = ImageOps.rotated(image, clockwiseDegrees: degrees) {
                let target = url.deletingLastPathComponent()
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                if (try? ImageOps.writePNG(rotated, to: target, dpi: dpi)) != nil {
                    try? FileManager.default.removeItem(at: url)
                    image = rotated
                    result.url = target
                }
            }

            do {
                result.lines = try TextRecognizer.recognize(image, languages: languages)
            } catch {
                result.error = "Texterkennung fehlgeschlagen: \(error.localizedDescription)"
            }
            let pageSize = CGSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            result.pageText = PageTextBuilder.make(lines: result.lines, pageSize: pageSize,
                                                   verticalMarginLines: MarginReader.verticalLines(in: image, dpi: dpi))

            let characters = result.lines.reduce(0) { $0 + $1.text.count }
            result.isBlank = BlankPageDetector.isBlank(image, recognizedCharacters: characters)

            let thumb = ImageOps.scaled(image, maxDimension: 400)
            result.thumbnail = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
            return result
        }
    }
}
