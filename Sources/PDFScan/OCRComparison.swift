import CoreGraphics
import Foundation
import PDFScanCore

/// Kommandozeilen-Modus zum Vergleichen der Handschrift-Varianten auf echten Scans:
/// `PDFScan --ocr-vergleich <Datei.pdf|Bild> …` – gibt je Seite und Variante den erkannten Text aus.
enum OCRComparison {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--ocr-vergleich") else { return }
        let paths = arguments[(flag + 1)...].filter { !$0.hasPrefix("-") }
        if paths.isEmpty {
            print("Aufruf: PDFScan --ocr-vergleich <Datei.pdf|Bild> …")
            exit(1)
        }
        AppSettings.registerDefaults()
        let languages = AppSettings.current.languages
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var pages: [CGImage] = []
            if url.pathExtension.lowercased() == "pdf" {
                ImageOps.renderPDFPages(at: url, dpi: 300) { pages.append($0) }
            } else {
                pages = ImageOps.loadImages(at: url)
            }
            if pages.isEmpty { print("\(url.lastPathComponent): nicht lesbar") }
            for (index, page) in pages.enumerated() {
                print("\n######## \(url.lastPathComponent) – Seite \(index + 1) (\(page.width)×\(page.height) px)")
                let ink = BlankPageDetector.inkCoverage(page)
                let normal = (try? TextRecognizer.recognize(page, languages: languages)) ?? []
                print("Sieht nach Handschrift aus: "
                      + (HandwritingRecognizer.looksHandwritten(lines: normal, inkCoverage: ink) ? "ja" : "nein")
                      + String(format: " (Tinte %.1f %%)", ink * 100))
                for variant in HandwritingRecognizer.variants(page, languages: languages) {
                    let characters = variant.lines.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
                    let confidence = variant.lines.isEmpty ? 0
                        : variant.lines.reduce(0.0) { $0 + Double($1.confidence) } / Double(variant.lines.count)
                    print("\n=== \(variant.name): \(variant.lines.count) Zeilen, \(characters) Zeichen, "
                          + String(format: "Konfidenz Ø %.2f", confidence))
                    for line in variant.lines {
                        print(String(format: "  [%.2f] ", line.confidence) + line.text)
                    }
                }
            }
        }
        exit(0)
    }
}
