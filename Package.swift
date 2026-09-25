// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PDFScan",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PDFScan", targets: ["PDFScan"]),
    ],
    targets: [
        // Scanner-unabhängige Verarbeitung: Bild-Operationen, OCR, Leerseiten, PDF-Erzeugung.
        .target(name: "PDFScanCore"),
        // SwiftUI-App inkl. Scanner-Anbindung über ImageCaptureCore.
        .executableTarget(name: "PDFScan", dependencies: ["PDFScanCore"]),
        .testTarget(name: "PDFScanCoreTests", dependencies: ["PDFScanCore"]),
    ]
)
