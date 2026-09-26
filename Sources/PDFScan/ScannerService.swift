import AppKit
import Foundation
import ImageCaptureCore
import PDFScanCore
import UniformTypeIdentifiers

/// Findet Scanner (USB, WLAN/Bonjour, freigegeben) über ImageCaptureCore und steuert den Einzug.
/// Funktioniert mit jedem Scanner, der in der App „Digitalbilder“ auftaucht – beim Epson FF-680W
/// über den Epson-ICA-Treiber (Epson Scan 2).
final class ScannerService: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle, connecting, ready, scanning
        case failed(String)
    }

    struct Options {
        var resolution: Int
        var grayscale: Bool
        var duplex: Bool
        var paperFormat: PaperFormat
    }

    @Published private(set) var scanners: [ICScannerDevice] = []
    @Published private(set) var selectedScanner: ICScannerDevice?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var supportsDuplex = false
    @Published private(set) var usesFeeder = false
    /// Tatsächlich eingestelltes Papierformat des letzten Scans, für die Statusanzeige.
    @Published private(set) var activeFormatDescription: String?

    /// Wird pro gescannter Seite (Datei) aufgerufen – auf dem Main-Thread.
    var onPageScanned: ((URL, Double) -> Void)?
    /// Wird nach Ende eines Einzugs aufgerufen – auf dem Main-Thread.
    var onScanFinished: ((Error?) -> Void)?

    private let browser = ICDeviceBrowser()
    private let downloadDirectory: URL
    private var pendingScan: Options?
    private var activeResolution: Double = 300
    /// Der Nutzer hat selbst einen Scanner gewählt – dann nicht mehr automatisch wechseln.
    private var userPicked = false
    /// Verbindungsversuche seit dem letzten Erfolg (für automatische Wiederholung).
    private var connectAttempts = 0
    private static let maxConnectAttempts = 3

    init(downloadDirectory: URL) {
        self.downloadDirectory = downloadDirectory
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
        // Sitzung beim Beenden schließen, sonst bleibt der Scanner für die nächste Verbindung belegt.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.closeSession()
        }
    }

    /// Name mit Verbindungsart, damit doppelt gefundene Geräte (USB und WLAN) unterscheidbar sind.
    func name(of scanner: ICScannerDevice) -> String {
        let base = scanner.name ?? "Scanner"
        let sameName = scanners.filter { ($0.name ?? "") == (scanner.name ?? "") }.count
        let transport = Self.transport(of: scanner)
        return sameName > 1 || transport != "USB" ? "\(base) (\(transport))" : base
    }

    static func transport(of device: ICDevice) -> String {
        let raw = String(describing: device.transportType as Any).lowercased()
        if raw.contains("usb") { return "USB" }
        if raw.contains("tcp") || raw.contains("bonjour") || raw.contains("network") { return "Netzwerk" }
        if raw.contains("bluetooth") { return "Bluetooth" }
        return "lokal"
    }

    /// Vom Nutzer im Menü gewählt.
    func userSelect(_ scanner: ICScannerDevice?) {
        userPicked = true
        select(scanner)
    }

    func select(_ scanner: ICScannerDevice?) {
        if let current = selectedScanner, current !== scanner, current.hasOpenSession {
            current.requestCloseSession()
        }
        selectedScanner = scanner
        supportsDuplex = false
        usesFeeder = false
        connectAttempts = 0
        guard let scanner else {
            phase = .idle
            return
        }
        connect(scanner)
    }

    /// Verbindung neu aufbauen (z. B. nach „Scanner belegt“).
    func reconnect() {
        guard let scanner = selectedScanner else {
            if let first = bestCandidate() { select(first) }
            return
        }
        connectAttempts = 0
        if scanner.hasOpenSession {
            scanner.requestCloseSession()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.selectedScanner === scanner else { return }
            self.connect(scanner)
        }
    }

    func closeSession() {
        if let scanner = selectedScanner, scanner.hasOpenSession {
            scanner.requestCloseSession()
        }
    }

    /// Bevorzugt: Epson FastFoto vor anderen, USB vor Netzwerk.
    private func score(_ scanner: ICScannerDevice) -> Int {
        var score = 0
        if (scanner.name ?? "").localizedCaseInsensitiveContains("FF-680") { score += 2 }
        if Self.transport(of: scanner) == "USB" { score += 1 }
        return score
    }

    private func bestCandidate(excluding excluded: ICScannerDevice? = nil) -> ICScannerDevice? {
        scanners.filter { $0 !== excluded }.max { score($0) < score($1) }
    }

    func startScan(_ options: Options) {
        guard let scanner = selectedScanner else { return }
        guard phase == .ready else {
            // Verbindung (wieder) aufbauen und danach automatisch scannen.
            pendingScan = options
            connect(scanner)
            return
        }

        let unit: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
        if let unit {
            let supported = unit.supportedResolutions
            unit.resolution = supported.min(by: { abs($0 - options.resolution) < abs($1 - options.resolution) })
                ?? options.resolution
            unit.pixelDataType = options.grayscale ? .gray : .RGB
            unit.bitDepth = .depth8Bits
            activeResolution = Double(unit.resolution)

            if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
                if feeder.supportsDuplexScanning {
                    feeder.duplexScanningEnabled = options.duplex
                }
                applyPaperFormat(options.paperFormat, to: feeder)
            }
            if let flatbed = unit as? ICScannerFunctionalUnitFlatbed {
                flatbed.scanArea = NSRect(origin: .zero, size: flatbed.physicalSize)
            }
        }

        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = downloadDirectory
        scanner.documentName = "scan-\(Int(Date().timeIntervalSince1970))"
        scanner.documentUTI = UTType.png.identifier
        phase = .scanning
        scanner.requestScan()
    }

    func cancelScan() {
        selectedScanner?.cancelScan()
    }

    /// Setzt das Papierformat des Einzugs. Ohne ausdrückliche Angabe nimmt manch ein Treiber
    /// (beobachtet: Epson FF-680W) A5 und schneidet A4-Blätter ab.
    /// „Automatisch“ schaltet die Größenerkennung des Treibers ein (falls vorhanden) und stellt die
    /// größte Scanfläche ein; ohne Größenerkennung gilt A4.
    private func applyPaperFormat(_ format: PaperFormat, to feeder: ICScannerFunctionalUnitDocumentFeeder) {
        guard format != .driverDefault else {
            activeFormatDescription = describe(feeder)
            return
        }
        var effective = format
        let autoSize = autoSizeFeature(of: feeder)
        if format == .auto {
            if let autoSize, setAutoSize(autoSize, enabled: true) {
                // Scanfläche trotzdem groß wählen, falls die Erkennung einmal versagt.
            } else {
                effective = .a4
            }
        } else if let autoSize {
            _ = setAutoSize(autoSize, enabled: false)
        }

        let candidates = paperCandidates(feeder)
        if let match = effective.bestMatch(in: candidates),
           let type = ICScannerDocumentType(rawValue: match.id) {
            feeder.documentType = type
        } else if let raw = Self.fallbackRawValue(effective),
                  feeder.supportedDocumentTypes.contains(Int(raw)),
                  let type = ICScannerDocumentType(rawValue: raw) {
            // Treiber liefert keine brauchbaren Größen: Nummern laut ImageCaptureCore-Header.
            feeder.documentType = type
        }
        activeFormatDescription = effective == .auto ? "automatisch" : describe(feeder)
    }

    /// Herstellerfunktion „Automatische Größenerkennung“, sofern der Treiber sie anbietet.
    private func autoSizeFeature(of unit: ICScannerFunctionalUnit) -> ICScannerFeatureEnumeration? {
        let features: [ICScannerFeature]? = unit.vendorFeatures
        return features?.lazy.compactMap { $0 as? ICScannerFeatureEnumeration }.first { feature in
            let name: String? = feature.humanReadableName
            return AutoSizeFeature.matches(name: name ?? "")
        }
    }

    private func setAutoSize(_ feature: ICScannerFeatureEnumeration, enabled: Bool) -> Bool {
        let values = feature.values
        guard let index = AutoSizeFeature.optionIndex(labels: feature.menuItemLabels, enabled: enabled),
              index < values.count
        else { return false }
        feature.currentValue = values[index]
        return true
    }

    /// Alle vom Einzug angebotenen Formate mit ihrer tatsächlichen Größe in mm.
    private func paperCandidates(_ feeder: ICScannerFunctionalUnitDocumentFeeder) -> [PaperFormat.Candidate] {
        let original = feeder.documentType
        defer { feeder.documentType = original }
        return feeder.supportedDocumentTypes.compactMap { raw -> PaperFormat.Candidate? in
            guard let type = ICScannerDocumentType(rawValue: UInt(raw)) else { return nil }
            feeder.documentType = type
            let size = feeder.documentSize
            return PaperFormat.Candidate(id: UInt(raw), widthMM: millimeters(size.width, feeder),
                                         heightMM: millimeters(size.height, feeder))
        }
    }

    private func millimeters(_ value: CGFloat, _ unit: ICScannerFunctionalUnit) -> Double {
        PaperFormat.millimeters(Double(value), unitRawValue: UInt(unit.measurementUnit.rawValue),
                                resolution: Double(unit.resolution))
    }

    private func describe(_ feeder: ICScannerFunctionalUnitDocumentFeeder) -> String {
        let size = feeder.documentSize
        return String(format: "%.0f × %.0f mm", millimeters(size.width, feeder), millimeters(size.height, feeder))
    }

    private static func fallbackRawValue(_ format: PaperFormat) -> UInt? {
        switch format {
        case .a4: return 1
        case .letter: return 3
        case .legal: return 4
        case .a5: return 5
        case .auto, .largest, .driverDefault: return nil
        }
    }

    /// Klartext-Übersicht über den Scanner – zum Nachvollziehen von Treiber-Eigenheiten.
    func diagnostics() -> String {
        var lines = ["Gefundene Scanner: " + (scanners.isEmpty ? "keine"
            : scanners.map { name(of: $0) + ($0 === selectedScanner ? " ← ausgewählt" : "") }.joined(separator: ", "))]
        guard let scanner = selectedScanner else { return (lines + ["Kein Scanner ausgewählt."]).joined(separator: "\n") }
        lines += ["Scanner: \(name(of: scanner))", "Verbindung: \(phase)",
                  "Sitzung offen: \(scanner.hasOpenSession ? "ja" : "nein")"]
        let available = scanner.availableFunctionalUnitTypes.map { "\($0)" }.joined(separator: ", ")
        lines.append("Funktionseinheiten (Typ-Nr.): \(available)")
        let unit: ICScannerFunctionalUnit? = scanner.selectedFunctionalUnit
        guard let unit else { return lines.joined(separator: "\n") }
        lines.append("Aktive Einheit: \(type(of: unit))")
        lines.append("Auflösungen: \(unit.supportedResolutions.map { String($0) }.joined(separator: ", ")) dpi")
        lines.append("Maßeinheit (Nr.): \(unit.measurementUnit.rawValue)")
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            lines.append("Duplex: \(feeder.supportsDuplexScanning ? "ja" : "nein")")
            lines.append("Aktuelles Format: Nr. \(feeder.documentType.rawValue), \(describe(feeder))")
            lines.append("Angebotene Formate:")
            for c in paperCandidates(feeder) {
                lines.append("  Nr. \(c.id): " + String(format: "%.1f × %.1f mm", c.widthMM, c.heightMM))
            }
        }
        let features: [ICScannerFeature]? = unit.vendorFeatures
        if let features, !features.isEmpty {
            lines.append("Herstellerfunktionen:")
            for feature in features {
                let name: String? = feature.humanReadableName
                var entry = "  \(name ?? "?")"
                if let e = feature as? ICScannerFeatureEnumeration {
                    entry += ": \(e.menuItemLabels.joined(separator: " | ")) (aktuell: \(e.currentValue))"
                } else if let b = feature as? ICScannerFeatureBoolean {
                    entry += ": \(b.value ? "an" : "aus")"
                }
                lines.append(entry)
            }
        } else {
            lines.append("Herstellerfunktionen: keine")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Intern

    private func connect(_ scanner: ICScannerDevice) {
        scanner.delegate = self
        phase = .connecting
        if scanner.hasOpenSession {
            selectPreferredUnit(scanner)
        } else {
            scanner.requestOpenSession()
        }
    }

    /// Bevorzugt den Dokumenteneinzug, sonst was der Scanner anbietet.
    private func selectPreferredUnit(_ scanner: ICScannerDevice) {
        let available = scanner.availableFunctionalUnitTypes.map { $0.uintValue }
        let feeder = ICScannerFunctionalUnitType.documentFeeder
        let type: ICScannerFunctionalUnitType
        if available.contains(feeder.rawValue) || available.isEmpty {
            type = feeder
        } else {
            type = ICScannerFunctionalUnitType(rawValue: available[0]) ?? .flatbed
        }
        scanner.requestSelect(type)
    }

    private func unitSelected(_ unit: ICScannerFunctionalUnit) {
        let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder
        usesFeeder = feeder != nil
        supportsDuplex = feeder?.supportsDuplexScanning ?? false
        phase = .ready
        if let options = pendingScan {
            pendingScan = nil
            startScan(options)
        }
    }

    private func fail(_ message: String) {
        pendingScan = nil
        phase = .failed(message)
    }
}

extension ScannerService: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice, !scanners.contains(where: { $0 === scanner }) else { return }
        scanners.append(scanner)
        guard let current = selectedScanner else {
            select(scanner)
            return
        }
        // Nur zu einem klar besseren Eintrag wechseln (z. B. derselbe Scanner per USB statt WLAN),
        // nie mitten in einer funktionierenden Verbindung oder gegen die Wahl des Nutzers.
        let settled = phase == .ready || phase == .scanning
        if !userPicked, !settled, score(scanner) > score(current) {
            select(scanner)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        scanners.removeAll { $0 === device }
        if selectedScanner === device {
            select(bestCandidate())
        }
    }
}

extension ScannerService: ICScannerDeviceDelegate {
    func didRemove(_ device: ICDevice) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard device === selectedScanner, let scanner = device as? ICScannerDevice else { return }
        guard let error else {
            connectAttempts = 0
            selectPreferredUnit(scanner)
            return
        }
        connectAttempts += 1
        if connectAttempts < Self.maxConnectAttempts {
            // Anderer Eintrag desselben Scanners (USB/WLAN)? Sonst derselbe nach kurzer Pause.
            let sameName = scanners.first { $0 !== scanner && $0.name == scanner.name }
            let next = userPicked ? scanner : (sameName ?? scanner)
            phase = .connecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.selectedScanner === scanner else { return }
                if next !== scanner {
                    let attempts = self.connectAttempts
                    self.select(next)
                    self.connectAttempts = attempts
                } else {
                    self.connect(scanner)
                }
            }
        } else {
            fail(ScannerError.message(for: error))
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if device === selectedScanner, phase != .connecting {
            phase = .idle
        }
    }

    func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
        if scanner === selectedScanner, phase != .ready, phase != .scanning {
            connect(scanner)
        }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        guard scanner === selectedScanner else { return }
        if let error {
            fail("Scanner-Modus nicht verfügbar: " + ScannerError.message(for: error))
        } else {
            unitSelected(functionalUnit)
        }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        onPageScanned?(url, activeResolution)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        if phase == .scanning { phase = .ready }
        onScanFinished?(error)
    }
}

/// Verständliche Meldungen für ImageCapture-Fehlercodes.
enum ScannerError {
    static func code(of error: Error) -> Int {
        var code = (error as NSError).code
        // Manche Codes kommen vorzeichenlos (z. B. 4294957394 statt -9902).
        if code > Int(Int32.max), code <= Int(UInt32.max) { code -= Int(UInt32.max) + 1 }
        return code
    }

    static func message(for error: Error) -> String {
        let code = code(of: error)
        let busy = "Andere Scan-Apps (Epson ScanSmart, Epson Scan 2, Digitalbilder) schließen, "
            + "Scanner aus- und wieder einschalten, dann „Neu verbinden“."
        switch code {
        case -9902, -9927, -9958:
            return "Scanner lässt sich nicht öffnen (Code \(code)). " + busy
        case -9909, -9914, -9925, -9926:
            return "Scanner wird von einer anderen App verwendet (Code \(code)). " + busy
        case -9900, -9901, -9923:
            return "Scanner nicht erreichbar (Code \(code)). Kabel bzw. WLAN prüfen, dann „Neu verbinden“."
        default:
            return "Verbindung fehlgeschlagen (Code \(code)): \(error.localizedDescription)"
        }
    }
}
