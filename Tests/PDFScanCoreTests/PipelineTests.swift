import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import PDFScanCore

final class PipelineTests: XCTestCase {
    private let letter = [
        "Sehr geehrte Damen und Herren,",
        "hiermit übersende ich Ihnen die Rechnung",
        "für die Lieferung vom 12. März 1987.",
        "Bitte überweisen Sie den Betrag innerhalb",
        "von vierzehn Tagen auf das angegebene Konto.",
        "Mit freundlichen Grüßen",
    ]

    /// Simuliert einen 200-dpi-Scan einer US-Letter-Seite mit etwas vergilbtem Papier.
    private func makePage(lines: [String]) -> CGImage {
        let width = 1700, height = 2200
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 46, nil)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 150, y: 1950 - index * 80)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        return ctx.makeImage()!
    }

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    func testRecognizesGermanText() throws {
        let lines = try TextRecognizer.recognize(makePage(lines: letter), languages: ["de-DE", "en-US"])
        let text = lines.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Rechnung"), text)
        XCTAssertTrue(text.contains("Grüßen"), text)
        XCTAssertGreaterThanOrEqual(lines.count, 5)
    }

    func testUnsupportedLanguageIsIgnored() throws {
        let lines = try TextRecognizer.recognize(makePage(lines: letter), languages: ["xx-XX", "de-DE"])
        XCTAssertFalse(lines.isEmpty)
    }

    func testDetectsAndFixesRotation() throws {
        let upright = makePage(lines: letter)
        XCTAssertEqual(TextRecognizer.uprightRotation(for: upright), 0)

        // Um 90° gegen den Uhrzeigersinn gekippt → muss um 90° im Uhrzeigersinn zurückgedreht werden.
        let tilted = try XCTUnwrap(ImageOps.rotated(upright, clockwiseDegrees: 270))
        XCTAssertEqual(tilted.width, upright.height)
        let correction = TextRecognizer.uprightRotation(for: tilted)
        XCTAssertEqual(correction, 90)

        let fixed = try XCTUnwrap(ImageOps.rotated(tilted, clockwiseDegrees: correction))
        let text = try TextRecognizer.recognize(fixed, languages: ["de-DE"]).map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Rechnung"), text)

        let upsideDown = try XCTUnwrap(ImageOps.rotated(upright, clockwiseDegrees: 180))
        XCTAssertEqual(TextRecognizer.uprightRotation(for: upsideDown), 180)
    }

    func testBlankPageDetection() throws {
        let blank = makePage(lines: [])
        XCTAssertLessThan(BlankPageDetector.inkCoverage(blank), 0.001)
        XCTAssertTrue(BlankPageDetector.isBlank(blank, recognizedCharacters: 0))

        let text = makePage(lines: letter)
        XCTAssertGreaterThan(BlankPageDetector.inkCoverage(text), 0.004)
        XCTAssertFalse(BlankPageDetector.isBlank(text, recognizedCharacters: 200))

        // Eine einzelne Zeile (z. B. nur eine Unterschrift) darf nicht als leer gelten.
        let oneLine = makePage(lines: ["Unterschrift: Max Mustermann"])
        let chars = try TextRecognizer.recognize(oneLine, languages: ["de-DE"]).reduce(0) { $0 + $1.text.count }
        XCTAssertFalse(BlankPageDetector.isBlank(oneLine, recognizedCharacters: chars))
    }

    func testWritesSearchablePDF() throws {
        let image = makePage(lines: letter)
        let imageURL = temporaryURL("png")
        try ImageOps.writePNG(image, to: imageURL, dpi: 200)
        XCTAssertEqual(ImageOps.dpi(at: imageURL), 200)

        let lines = try TextRecognizer.recognize(image, languages: ["de-DE"])
        let pdfURL = temporaryURL("pdf")
        let pages = [PDFPageSource(imageURL: imageURL, dpi: 200, lines: lines),
                     PDFPageSource(imageURL: imageURL, dpi: 200, lines: lines)]
        try SearchablePDFWriter.write(pages, to: pdfURL, title: "Test", jpegQuality: 0.7)

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(document.pageCount, 2)
        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 612, accuracy: 1)   // 8,5 Zoll
        XCTAssertEqual(bounds.height, 792, accuracy: 1)  // 11 Zoll
        XCTAssertTrue(page.string?.contains("Rechnung") ?? false, page.string ?? "<kein Text>")
        XCTAssertFalse(document.findString("Lieferung", withOptions: .caseInsensitive).isEmpty)

        // JPEG-Einbettung statt unkomprimierter Pixel: zwei Seiten deutlich unter 2 MB.
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int)
        XCTAssertLessThan(size, 2_000_000)
    }

    func testRendersExistingPDFForReOCR() throws {
        let imageURL = temporaryURL("png")
        try ImageOps.writePNG(makePage(lines: letter), to: imageURL, dpi: 200)
        let pdfURL = temporaryURL("pdf")
        try SearchablePDFWriter.write([PDFPageSource(imageURL: imageURL, dpi: 200, lines: [])], to: pdfURL)

        var rendered: [CGImage] = []
        ImageOps.renderPDFPages(at: pdfURL, dpi: 300) { rendered.append($0) }
        XCTAssertEqual(rendered.count, 1)
        XCTAssertEqual(rendered[0].width, 2550, accuracy: 2)
        let text = try TextRecognizer.recognize(rendered[0], languages: ["de-DE"]).map(\.text).joined()
        XCTAssertTrue(text.contains("Rechnung"), text)
    }
}
