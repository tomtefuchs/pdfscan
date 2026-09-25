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

    var text: String { lines.map(\.text).joined(separator: "\n") }
    var wordCount: Int { lines.reduce(0) { $0 + $1.text.split(separator: " ").count } }
}

/// Hält das aktuelle Dokument (Seitenliste) und verbindet Scanner, Texterkennung und PDF-Export.
final class AppModel: ObservableObject {
    @Published var pages: [ScanPage] = []
    @Published var selection: ScanPage.ID?
    @Published var documentName = ""
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
        documentName = ""
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
        let included = snapshot.filter { !$0.excluded }
        guard !included.isEmpty else {
            isSaving = false
            status = "Keine Seiten zum Speichern (alle abgewählt oder leer)"
            return
        }

        let trimmed = documentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let title = trimmed.isEmpty ? "Scan \(Self.timeFormatter.string(from: now))" : trimmed
        let fileName = (settings.datePrefix && !trimmed.isEmpty ? "\(Self.dateFormatter.string(from: now)) " : "")
            + Self.sanitized(title)
        let folder = settings.outputFolder
        let sources = included.map { PDFPageSource(imageURL: $0.url, dpi: $0.dpi, lines: $0.lines) }
        let savedIDs = Set(snapshot.map(\.id))
        let temporary = workDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")

        status = "Erzeuge PDF mit \(included.count) Seiten…"
        queue.async { [weak self] in
            let outcome: Result<URL, Error> = Result {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try SearchablePDFWriter.write(sources, to: temporary, title: title, jpegQuality: settings.jpegQuality)
                let target = Self.uniqueURL(in: folder, baseName: fileName)
                try FileManager.default.moveItem(at: temporary, to: target)
                return target
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                switch outcome {
                case .success(let url):
                    self.delete(savedIDs)
                    self.documentName = ""
                    self.lastSavedURL = url
                    self.status = "Gespeichert: \(url.lastPathComponent)"
                case .failure(let error):
                    try? FileManager.default.removeItem(at: temporary)
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    private static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Scan" : cleaned
    }

    private static func uniqueURL(in folder: URL, baseName: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension("pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) (\(counter))").appendingPathExtension("pdf")
            counter += 1
        }
        return candidate
    }
}

/// Die eigentliche Seitenverarbeitung (läuft im Hintergrund).
enum PageProcessor {
    struct Result {
        var url: URL
        var lines: [RecognizedLine] = []
        var isBlank = false
        var thumbnail: NSImage?
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
            let characters = result.lines.reduce(0) { $0 + $1.text.count }
            result.isBlank = BlankPageDetector.isBlank(image, recognizedCharacters: characters)

            let thumb = ImageOps.scaled(image, maxDimension: 400)
            result.thumbnail = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
            return result
        }
    }
}
