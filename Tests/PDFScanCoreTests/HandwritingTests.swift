import CoreGraphics
import CoreText
import XCTest
@testable import PDFScanCore

final class HandwritingTests: XCTestCase {
    private func line(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 0.03,
                      confidence: Float = 1) -> RecognizedLine {
        RecognizedLine(text: text, box: CGRect(x: x, y: y, width: w, height: h), confidence: confidence)
    }

    /// Blasse „Handschrift“ (Schreibschrift-Font) auf vergilbtem Papier, 300 dpi A5.
    private func makeNote(_ lines: [String], ink: CGFloat = 0.55, fontName: String = "Bradley Hand") -> CGImage {
        let width = 1748, height = 2480
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.93, green: 0.89, blue: 0.78, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName(fontName as CFString, 80, nil)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: ink * 0.9, green: ink * 0.9, blue: ink, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 160, y: 2150 - index * 150)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        return ctx.makeImage()!
    }

    private func grayValues(_ image: CGImage) -> [UInt8] {
        let ctx = ImageOps.makeContext(width: image.width, height: image.height, gray: true)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytesPerRow = ctx.bytesPerRow
        let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: bytesPerRow * image.height)
        // Nur echte Pixel, ohne das Füllmaterial am Zeilenende.
        return (0..<image.height).flatMap { y in (0..<image.width).map { pixels[y * bytesPerRow + $0] } }
    }

    func testEnhancementWhitensPaperAndDarkensFaintInk() throws {
        let note = makeNote(["Bitte Milch kaufen"], ink: 0.6)
        let before = grayValues(note)
        let after = grayValues(try XCTUnwrap(HandwritingRecognizer.enhanced(note)))
        XCTAssertLessThan(before.max()!, 250)
        XCTAssertGreaterThan(before.min()!, 90)
        // Papier wird weiß, die blassen Striche werden kräftig.
        let paper = after.sorted()[after.count / 2]
        XCTAssertEqual(paper, 255)
        XCTAssertLessThan(after.min()!, 20)
    }

    func testDarkestChannelTurnsBlueInkBlackAndRemovesGrid() throws {
        // Weißes Karopapier mit hellblauem Raster und türkisblauer Tinte (Farbwerte aus einem echten Scan).
        let size = 1000
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 221 / 255, green: 246 / 255, blue: 251 / 255, alpha: 1))
        for x in stride(from: 50, to: size, by: 50) { ctx.fill(CGRect(x: x, y: 0, width: 3, height: size)) }
        ctx.setFillColor(CGColor(red: 30 / 255, green: 170 / 255, blue: 235 / 255, alpha: 1))
        ctx.fill(CGRect(x: 110, y: 100, width: 300, height: 40))
        let page = ctx.makeImage()!

        let darkest = grayValues(try XCTUnwrap(HandwritingRecognizer.enhanced(page)))
        let gray = grayValues(try XCTUnwrap(HandwritingRecognizer.enhanced(page, channel: .luminance)))
        let inkIndex = (size - 1 - 120) * size + 250, gridIndex = 500 * size + 51
        XCTAssertLessThan(darkest[inkIndex], 20)
        XCTAssertGreaterThanOrEqual(darkest[gridIndex], 250)
        // In der Helligkeit ist die Tinte nur mittelgrau.
        XCTAssertGreaterThan(Int(gray[inkIndex]), Int(darkest[inkIndex]))
    }

    func testStripsMapBoxesBackToPage() throws {
        let note = makeNote(["Termin am Montag", "beim Zahnarzt", "um halb neun", "nicht vergessen",
                             "Schlüssel mitnehmen", "und Unterlagen"], ink: 0.2, fontName: "Helvetica")
        let whole = try TextRecognizer.recognize(note, languages: ["de-DE"])
        let strips = try HandwritingRecognizer.recognizeInStrips(note, languages: ["de-DE"])
        for text in ["Zahnarzt", "vergessen", "Unterlagen"] {
            let a = try XCTUnwrap(whole.first { $0.text.contains(text) }, "\(whole.map(\.text))")
            let b = try XCTUnwrap(strips.first { $0.text.contains(text) }, "\(strips.map(\.text))")
            XCTAssertEqual(a.box.midY, b.box.midY, accuracy: 0.01, text)
            XCTAssertEqual(a.box.minX, b.box.minX, accuracy: 0.01, text)
        }
    }

    func testEnhancementLeavesDarkImagesAlone() throws {
        let ctx = ImageOps.makeContext(width: 100, height: 100, gray: true)!
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let dark = ctx.makeImage()!
        XCTAssertEqual(grayValues(try XCTUnwrap(HandwritingRecognizer.enhanced(dark))), grayValues(dark))
    }

    func testHeuristic() {
        // Leere Seite: nie.
        XCTAssertFalse(HandwritingRecognizer.looksHandwritten(lines: [], inkCoverage: 0.001))
        // Tinte, aber kein Text.
        XCTAssertTrue(HandwritingRecognizer.looksHandwritten(lines: [], inkCoverage: 0.02))
        // Normaler Brief: viel sicherer Text.
        let letter = (0..<30).map { line(String(repeating: "Druckschrift ", count: 5), 0.1, 0.9 - Double($0) * 0.025, 0.8) }
        XCTAssertFalse(HandwritingRecognizer.looksHandwritten(lines: letter, inkCoverage: 0.05))
        // Unsichere Erkennung.
        let unsure = letter.map { var l = $0; l.confidence = 0.3; return l }
        XCTAssertTrue(HandwritingRecognizer.looksHandwritten(lines: unsure, inkCoverage: 0.05))
        // Viel Tinte, wenig gelesen.
        let few = [line("Lieber Hans, danke für", 0.1, 0.8, 0.5), line("deinen Brief vom Juni", 0.1, 0.7, 0.5)]
        XCTAssertTrue(HandwritingRecognizer.looksHandwritten(lines: few, inkCoverage: 0.04))
    }

    func testMergeKeepsBetterLinesAndAddsNewOnes() {
        let base = [
            line("Rechnung Nr. 4711", 0.1, 0.9, 0.5),
            line("l.b Hns dnk", 0.1, 0.5, 0.5, confidence: 0.3),
        ]
        let extra = [
            line("Rechnung Nr. 4711", 0.1, 0.9, 0.5, confidence: 0.5),   // schlechter → bleibt Druck
            line("Lieber Hans, danke", 0.11, 0.5, 0.48, confidence: 0.5), // besser → ersetzt
            line("bis Sonntag!", 0.1, 0.3, 0.3, confidence: 0.5),        // neu
        ]
        let merged = HandwritingRecognizer.merge(base, extra)
        XCTAssertEqual(merged.map(\.text), ["Rechnung Nr. 4711", "Lieber Hans, danke", "bis Sonntag!"])
        XCTAssertEqual(merged[0].confidence, 1)
    }

    func testMergeSortsReadingOrder() {
        let merged = HandwritingRecognizer.merge([line("rechts", 0.6, 0.5, 0.3)], [line("links", 0.1, 0.505, 0.3),
                                                                                   line("oben", 0.1, 0.8, 0.3)])
        XCTAssertEqual(merged.map(\.text), ["oben", "links", "rechts"])
    }

    func testRecognizesFaintHandwrittenNote() throws {
        let note = makeNote(["Lieber Hans,", "vielen Dank für", "deinen Brief.", "Herzliche Grüße"])
        let result = try HandwritingRecognizer.recognizePage(note, languages: ["de-DE"], mode: .always)
        XCTAssertTrue(result.handwritingPass)
        let text = result.lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Dank") || text.contains("Brief"), text)
    }

    func testPrintedLetterSkipsHandwritingPass() throws {
        // Gleicher Aufbau wie in PipelineTests: klarer Druck auf vergilbtem Papier.
        let width = 1700, height = 2200
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let text = [
            "Sehr geehrte Damen und Herren,",
            "hiermit übersende ich Ihnen die Rechnung für die Lieferung",
            "vom 12. März 1987. Bitte überweisen Sie den Betrag innerhalb",
            "von vierzehn Tagen auf das angegebene Konto bei der Sparkasse.",
            "Für Rückfragen stehen wir Ihnen gerne zur Verfügung.",
            "Mit freundlichen Grüßen",
        ]
        for (index, line) in text.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 150, y: 1950 - index * 70)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        let result = try HandwritingRecognizer.recognizePage(ctx.makeImage()!, languages: ["de-DE"], mode: .auto)
        XCTAssertFalse(result.handwritingPass)
        XCTAssertTrue(result.lines.map(\.text).joined(separator: " ").contains("Rechnung"))
    }
}
