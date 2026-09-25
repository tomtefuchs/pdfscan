import CoreGraphics
import CoreText
import XCTest
@testable import PDFScanCore

/// Ende-zu-Ende: gerenderte Seiten → Vision-OCR → Seitentext → Trennung.
final class SplitEndToEndTests: XCTestCase {
    private let dpi = 200.0

    /// A4 bei 200 dpi. `footer` unten mittig, `marginID` senkrecht (von unten nach oben) am linken Rand.
    private func page(_ lines: [String], footer: String?, marginID: String?) -> CGImage {
        let width = 1654, height = 2339
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func draw(_ text: String, size: CGFloat, at point: CGPoint, rotated: Bool = false) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            ctx.saveGState()
            ctx.translateBy(x: point.x, y: point.y)
            if rotated { ctx.rotate(by: .pi / 2) }
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        for (i, text) in lines.enumerated() {
            draw(text, size: 40, at: CGPoint(x: 200, y: 2000 - CGFloat(i) * 70))
        }
        if let footer { draw(footer, size: 34, at: CGPoint(x: 700, y: 120)) }
        // Kennung im 30-pt-Rand (≈ 83 px bei 200 dpi), Schrift ca. 9 pt.
        if let marginID { draw(marginID, size: 26, at: CGPoint(x: 55, y: 900), rotated: true) }
        return ctx.makeImage()!
    }

    private func pageText(_ image: CGImage) throws -> PageText {
        let lines = try TextRecognizer.recognize(image, languages: ["de-DE"])
        let size = CGSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
        return PageTextBuilder.make(lines: lines, pageSize: size,
                                    verticalMarginLines: MarginReader.verticalLines(in: image, dpi: dpi))
    }

    func testMarginReaderFindsVerticalIdentifier() throws {
        let image = page(["Kontoauszug"], footer: nil, marginID: "KX4711AB0815Z")
        let text = try pageText(image)
        let tokens = DocumentBoundaryDetector.tokenSets([text.margin, "", "", "", "", ""])[0]
        XCTAssertTrue(DocumentBoundaryDetector.related(tokens, [DocumentBoundaryDetector.norm("KX4711AB0815Z")]),
                      "Rand: \(text.margin)")
    }

    func testSplitsScannedStack() throws {
        let images = [
            page(["Stadtwerke Beispielstadt", "Jahresabrechnung Strom"], footer: "Seite 1/2", marginID: nil),
            page(["Verbrauchsübersicht", "Zählerstand alt und neu"], footer: "Seite 2/2", marginID: nil),
            page(["Max Mustermann", "Hauptstraße 1", "10115 Berlin", "", "Sehr geehrte Frau Beispiel,",
                  "wir bestätigen Ihre Kündigung."], footer: nil, marginID: nil),
            page(["Versicherung", "Beitragsrechnung"], footer: "Seite 1/3", marginID: nil),
            page(["Leistungsübersicht", "Tarif Komfort"], footer: "Seite 2/3", marginID: nil),
            page(["Bedingungen", "Stand Januar"], footer: "Seite 3/3", marginID: nil),
        ]
        let texts = try images.map(pageText)
        let result = DocumentBoundaryDetector.split(texts)
        XCTAssertEqual(result.documents, [[0, 1], [2], [3, 4, 5]],
                       result.starts.map { "\($0.page): \($0.reason.description)" }.joined(separator: ", "))
    }
}
