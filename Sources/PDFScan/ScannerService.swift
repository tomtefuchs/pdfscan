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
    }

    func name(of scanner: ICScannerDevice) -> String {
        scanner.name ?? "Scanner"
    }

    func select(_ scanner: ICScannerDevice?) {
        if let current = selectedScanner, current !== scanner, current.hasOpenSession {
            current.requestCloseSession()
        }
        selectedScanner = scanner
        supportsDuplex = false
        usesFeeder = false
        guard let scanner else {
            phase = .idle
            return
        }
        connect(scanner)
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
    private func applyPaperFormat(_ format: PaperFormat, to feeder: ICScannerFunctionalUnitDocumentFeeder) {
        guard format != .driverDefault else {
            activeFormatDescription = describe(feeder)
            return
        }
        let candidates = paperCandidates(feeder)
        if let match = format.bestMatch(in: candidates),
           let type = ICScannerDocumentType(rawValue: match.id) {
            feeder.documentType = type
        } else if let raw = Self.fallbackRawValue(format),
                  feeder.supportedDocumentTypes.contains(Int(raw)),
                  let type = ICScannerDocumentType(rawValue: raw) {
            // Treiber liefert keine brauchbaren Größen: Nummern laut ImageCaptureCore-Header.
            feeder.documentType = type
        }
        activeFormatDescription = describe(feeder)
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
        case .largest, .driverDefault: return nil
        }
    }

    /// Klartext-Übersicht über den Scanner – zum Nachvollziehen von Treiber-Eigenheiten.
    func diagnostics() -> String {
        guard let scanner = selectedScanner else { return "Kein Scanner ausgewählt." }
        var lines = ["Scanner: \(name(of: scanner))", "Verbindung: \(phase)"]
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
        // Epson FastFoto automatisch wählen, sonst den ersten gefundenen Scanner.
        let isEpsonFF = (scanner.name ?? "").localizedCaseInsensitiveContains("FF-680")
        if selectedScanner == nil || (isEpsonFF && phase != .scanning) {
            select(scanner)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        scanners.removeAll { $0 === device }
        if selectedScanner === device {
            select(scanners.first)
        }
    }
}

extension ScannerService: ICScannerDeviceDelegate {
    func didRemove(_ device: ICDevice) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard device === selectedScanner, let scanner = device as? ICScannerDevice else { return }
        if let error {
            fail("Verbindung fehlgeschlagen: \(error.localizedDescription)")
        } else {
            selectPreferredUnit(scanner)
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
            fail("Scanner-Modus nicht verfügbar: \(error.localizedDescription)")
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
