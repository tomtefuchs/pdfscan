import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import PDFScanCore

final class FileSizeTests: XCTestCase {
    /// A4 bei 300 dpi, vergilbtes Papier mit leichtem Rauschen, schwarzer Text, optional roter Stempel.
    private func scan(stamp: Bool) -> CGImage {
        let width = 2480, height = 3508
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.95, green: 0.91, blue: 0.80, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Papierstruktur
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<40_000 {
            let shade = CGFloat.random(in: 0.82...0.93, using: &rng)
            ctx.setFillColor(CGColor(red: shade, green: shade * 0.96, blue: shade * 0.85, alpha: 1))
            ctx.fill(CGRect(x: Int.random(in: 0..<width, using: &rng), y: Int.random(in: 0..<height, using: &rng),
                            width: 3, height: 3))
        }
        let font = CTFontCreateWithName("Times New Roman" as CFString, 50, nil)
        let lines = ["Mietvertrag über einen Fahrradstellplatz", "zwischen Vermieter und Mieter",
                     "§ 1 Überlassung des Stellplatzes", "Die Miete beträgt monatlich Euro 5,00"]
        for row in 0..<30 {
            let text = NSAttributedString(string: lines[row % lines.count], attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 250, y: 3200 - row * 95)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        }
        if stamp {
            ctx.setStrokeColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            ctx.setLineWidth(12)
            ctx.strokeEllipse(in: CGRect(x: 1600, y: 300, width: 500, height: 300))
        }
        return ctx.makeImage()!
    }

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private func pdfSize(_ image: CGImage, profile: PDFImageProfile) throws -> (Int, PDFDocument) {
        let png = tempURL("png")
        try ImageOps.writePNG(image, to: png, dpi: 300)
        let lines = try TextRecognizer.recognize(image, languages: ["de-DE"])
        let pdf = tempURL("pdf")
        try SearchablePDFWriter.write([PDFPageSource(imageURL: png, dpi: 300, lines: lines)], to: pdf, profile: profile)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int)
        return (size, try XCTUnwrap(PDFDocument(url: pdf)))
    }

    func testYellowedPaperCountsAsColorless() {
        XCTAssertTrue(ImageOps.isEffectivelyGrayscale(scan(stamp: false)))
        XCTAssertFalse(ImageOps.isEffectivelyGrayscale(scan(stamp: true)))
    }

    func testWhiteningMakesPaperWhite() throws {
        let gray = try XCTUnwrap(ImageOps.grayscale(scan(stamp: false)))
        let whitened = try XCTUnwrap(ImageOps.whitenedBackground(gray))
        XCTAssertLessThan(BlankPageDetector.inkCoverage(whitened), 0.2)
        // Ein Pixel mitten im Papier (oben links, außerhalb des Textes) ist jetzt weiß.
        let ctx = ImageOps.makeContext(width: 1, height: 1, gray: true)!
        ctx.draw(whitened.cropping(to: CGRect(x: 60, y: 60, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let value = ctx.data!.load(as: UInt8.self)
        XCTAssertGreaterThan(value, 240)
    }

    func testCompactIsMuchSmallerAndStillSearchable() throws {
        let image = scan(stamp: false)
        let (original, _) = try pdfSize(image, profile: .original)
        let (balanced, _) = try pdfSize(image, profile: .balanced)
        let (compact, document) = try pdfSize(image, profile: .compact)
        print("PDF-Größe A4: original \(original / 1024) KB, ausgewogen \(balanced / 1024) KB, kompakt \(compact / 1024) KB")

        XCTAssertLessThan(compact, original * 35 / 100)
        XCTAssertLessThan(compact, 300 * 1024)
        XCTAssertLessThan(balanced, original)

        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595.2, accuracy: 1)   // A4 bleibt A4
        XCTAssertFalse(document.findString("Fahrradstellplatz", withOptions: .caseInsensitive).isEmpty)
    }

    func testColorPagesStayColor() throws {
        let stamped = scan(stamp: true)
        let prepared = PDFImageProfile.compact.prepare(stamped, dpi: 300)
        XCTAssertFalse(ImageOps.isGray(prepared))
        XCTAssertEqual(prepared.width, 1653, accuracy: 2)   // auf 200 dpi verkleinert
    }
}
