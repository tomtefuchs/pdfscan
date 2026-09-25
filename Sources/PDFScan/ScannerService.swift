import Foundation
import ImageCaptureCore
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
    }

    @Published private(set) var scanners: [ICScannerDevice] = []
    @Published private(set) var selectedScanner: ICScannerDevice?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var supportsDuplex = false
    @Published private(set) var usesFeeder = false

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

            if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder, feeder.supportsDuplexScanning {
                feeder.duplexScanningEnabled = options.duplex
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
