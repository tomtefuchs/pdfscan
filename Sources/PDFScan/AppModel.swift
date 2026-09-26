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
    /// Name der importierten Ursprungsdatei (ohne Endung); `nil` bei gescannten Seiten.
    var sourceName: String?
    /// Ordner der Ursprungsdatei – importierte Dokumente werden daneben gespeichert.
    var sourceFolder: URL?

    var text: String { lines.map(\.text).joined(separator: "\n") }
    var wordCount: Int { lines.reduce(0) { $0 + $1.text.split(separator: " ").count } }
}

/// Hält das aktuelle Dokument (Seitenliste) und verbindet Scanner, Texterkennung und PDF-Export.
final class AppModel: ObservableObject {
    @Published var pages: [ScanPage] = []
    @Published var selection: ScanPage.ID?
    /// Meldung in der Statusleiste; leer = nichts anzeigen (den Scannerzustand zeigt die Kapsel).
    @Published var status = ""
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

        // Für automatische Tests und Screenshots: Dateien beim Start importieren (durch „:“ getrennt).
        if let paths = ProcessInfo.processInfo.environment["PDFSCAN_IMPORT"], !paths.isEmpty {
            let urls = paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.async { [weak self] in self?.importFiles(urls) }
        }
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
                                duplex: settings.duplex,
                                paperFormat: settings.paperFormat))
        if let format = scanner.activeFormatDescription {
            status = "Scanne (Format \(format))…"
        }
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
            var imported: [(URL, Double, String, URL)] = []
            var failures: [String] = []
            func store(_ image: CGImage, dpi: Double, source: String, folder: URL) {
                let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                if (try? ImageOps.writePNG(image, to: target, dpi: dpi)) != nil {
                    imported.append((target, dpi, source, folder))
                }
            }
            for url in urls {
                let before = imported.count
                let source = url.deletingPathExtension().lastPathComponent
                let folder = url.deletingLastPathComponent()
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                    ImageOps.renderPDFPages(at: url, dpi: 300) { store($0, dpi: 300, source: source, folder: folder) }
                } else {
                    let dpi = ImageOps.dpi(at: url) ?? fallbackDPI
                    for image in ImageOps.loadImages(at: url) { store(image, dpi: dpi, source: source, folder: folder) }
                }
                if imported.count == before { failures.append(url.lastPathComponent) }
            }
            let pagesFound = imported
            let unreadable = failures
            DispatchQueue.main.async {
                guard let self else { return }
                pagesFound.forEach { self.addPage(url: $0.0, dpi: $0.1, sourceName: $0.2, sourceFolder: $0.3) }
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

    private func addPage(url: URL, dpi: Double, sourceName: String? = nil, sourceFolder: URL? = nil) {
        var page = ScanPage(url: url, dpi: dpi)
        page.sourceName = sourceName
        page.sourceFolder = sourceFolder
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
                    let note = "Automatische Trennung übersprungen (Trennstellen von Hand geändert)"
                    self.status = self.status.isEmpty ? note : self.status + " – " + note
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

        // Importierte Dokumente heißen wie ihre Ursprungsdatei plus „_ocr“ (maßgeblich ist die erste Seite).
        let sources = groups.map { snapshot[$0[0]].sourceName }
        // Importierte Dokumente landen neben dem Original, gescannte im Zielordner.
        let outputFolder = settings.outputFolder
        var folders: [URL] = []
        var blocked: [URL: [Int]] = [:]
        for (index, group) in groups.enumerated() {
            let first = snapshot[group[0]]
            guard first.sourceName != nil, let folder = first.sourceFolder else {
                folders.append(outputFolder)
                continue
            }
            folders.append(folder)
            if !FileManager.default.isWritableFile(atPath: folder.path) {
                blocked[folder, default: []].append(index)
            }
        }
        // Ordner des Originals nicht beschreibbar: nachfragen statt ausweichen.
        var explicitTargets: [Int: URL] = [:]
        for (folder, indices) in blocked.sorted(by: { $0.key.path < $1.key.path }) {
            guard let choice = askForTarget(blockedFolder: folder, suggestedName:
                    indices.count == 1 ? DocumentNaming.ocrFileName(sourceName: sources[indices[0]] ?? "") : nil,
                    documentCount: indices.count, directory: outputFolder)
            else {
                isSaving = false
                status = "Speichern abgebrochen"
                return
            }
            switch choice {
            case .file(let url):
                explicitTargets[indices[0]] = url
                folders[indices[0]] = url.deletingLastPathComponent()
            case .folder(let url):
                for index in indices { folders[index] = url }
            }
        }
        let documents = groups.map { group in
            group.map { PDFPageSource(imageURL: snapshot[$0].url, dpi: snapshot[$0].dpi, lines: snapshot[$0].lines) }
        }
        let naming = DocumentNaming(prefix: settings.filePrefix)
        let savedIDs = Set(snapshot.map(\.id))
        let workDirectory = self.workDirectory
        let now = Date()

        status = documents.count == 1
            ? "Erzeuge PDF mit \(documents[0].count) Seiten…"
            : "Erzeuge \(documents.count) PDFs…"
        let targetFolders = folders
        let chosenTargets = explicitTargets
        queue.async { [weak self] in
            var temporaries: [URL] = []
            let outcome: Result<[URL], Error> = Result {
                for folder in Set(targetFolders) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                for (index, pages) in documents.enumerated() {
                    let temporary = workDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
                    temporaries.append(temporary)
                    let title = sources[index] ?? "Scan \(Self.titleFormatter.string(from: now))"
                    try SearchablePDFWriter.write(pages, to: temporary, title: title, profile: settings.fileSize.profile)
                }
                // Erst wenn alle PDFs fertig sind, mit einer freien Batch-Nummer in den Zielordner verschieben.
                func exists(_ name: String, in folder: URL) -> Bool {
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
                }
                var batch = naming.nextBatch(in: outputFolder, date: now)
                var names = naming.fileNames(sources: sources, batch: batch, date: now)
                // Gescannte Dokumente: nächste Batch-Nummer, falls eine schon vergeben ist.
                while zip(sources, names).contains(where: { $0.0 == nil && exists($0.1, in: outputFolder) }) {
                    batch += 1
                    names = naming.fileNames(sources: sources, batch: batch, date: now)
                }
                // Importierte Dokumente: vorhandene Dateien nie überschreiben.
                var used = Set<URL>()
                let targets = try names.indices.map { index -> URL in
                    if let explicit = chosenTargets[index] {
                        // Im Speichern-Dialog gewählt – Überschreiben hat der Dialog bereits bestätigt.
                        if FileManager.default.fileExists(atPath: explicit.path) {
                            try FileManager.default.removeItem(at: explicit)
                        }
                        used.insert(explicit)
                        return explicit
                    }
                    let folder = targetFolders[index]
                    guard sources[index] != nil else { return folder.appendingPathComponent(names[index]) }
                    let unique = DocumentNaming.unique(names[index]) {
                        exists($0, in: folder) || used.contains(folder.appendingPathComponent($0))
                    }
                    let target = folder.appendingPathComponent(unique)
                    used.insert(target)
                    return target
                }
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

    private enum TargetChoice {
        case file(URL)
        case folder(URL)
    }

    /// Speichern-Dialog (ein Dokument) bzw. Ordnerauswahl (mehrere Dokumente) für einen
    /// schreibgeschützten Ursprungsordner. `nil` = abgebrochen.
    private func askForTarget(blockedFolder: URL, suggestedName: String?, documentCount: Int,
                              directory: URL) -> TargetChoice? {
        let location = (blockedFolder.path as NSString).abbreviatingWithTildeInPath
        if let suggestedName {
            let panel = NSSavePanel()
            panel.title = "Durchsuchbares PDF speichern"
            panel.message = "In „\(location)“ kann nicht gespeichert werden. Wohin soll das Dokument?"
            panel.nameFieldStringValue = suggestedName
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            panel.directoryURL = directory
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return .file(url)
        }
        let panel = NSOpenPanel()
        panel.title = "Ordner für durchsuchbare PDFs wählen"
        panel.message = "In „\(location)“ kann nicht gespeichert werden. Wohin sollen die \(documentCount) Dokumente?"
        panel.prompt = "Hier speichern"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return .folder(url)
    }

    func showScannerInfo() {
        let text = scanner.diagnostics()
        let alert = NSAlert()
        alert.messageText = "Scanner-Info"
        alert.informativeText = "Diese Angaben helfen bei Problemen mit Format oder Treiber."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = text
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Kopieren")
        alert.addButton(withTitle: "Schließen")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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
