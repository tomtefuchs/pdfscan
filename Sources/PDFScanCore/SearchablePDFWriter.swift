import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Eine Seite für das PDF: Bilddatei, ihre Auflösung und der erkannte Text.
public struct PDFPageSource {
    public var imageURL: URL
    public var dpi: Double
    public var lines: [RecognizedLine]

    public init(imageURL: URL, dpi: Double, lines: [RecognizedLine]) {
        self.imageURL = imageURL
        self.dpi = dpi
        self.lines = lines
    }
}

/// Schreibt ein durchsuchbares PDF: sichtbar ist der Scan, darüber liegt unsichtbarer Text
/// an den Positionen, an denen Vision ihn erkannt hat (Suche, Markieren, Kopieren, Spotlight).
public enum SearchablePDFWriter {
    public static func write(_ pages: [PDFPageSource], to url: URL, title: String? = nil, jpegQuality: Double = 0.7) throws {
        guard !pages.isEmpty else { throw PDFScanError.noPages }
        var info: [CFString: Any] = [kCGPDFContextCreator: "PDFScan"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw PDFScanError.cannotCreatePDF(url)
        }
        do {
            for page in pages {
                try autoreleasepool {
                    try draw(page, into: ctx, jpegQuality: jpegQuality)
                }
            }
            ctx.closePDF()
        } catch {
            ctx.closePDF()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func draw(_ page: PDFPageSource, into ctx: CGContext, jpegQuality: Double) throws {
        guard let image = ImageOps.loadImage(at: page.imageURL) else {
            throw PDFScanError.unreadableImage(page.imageURL)
        }
        // Ein direkt aus JPEG-Daten erzeugtes CGImage bettet Quartz ohne Neukodierung (DCT) ein – kleine PDFs.
        guard let jpeg = ImageOps.jpegData(image, quality: jpegQuality, dpi: page.dpi),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let embedded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PDFScanError.unreadableImage(page.imageURL) }

        let pointsPerPixel = 72.0 / (page.dpi > 0 ? page.dpi : 300)
        var mediaBox = CGRect(x: 0, y: 0,
                              width: Double(image.width) * pointsPerPixel,
                              height: Double(image.height) * pointsPerPixel)
        ctx.beginPage(mediaBox: &mediaBox)
        ctx.draw(embedded, in: mediaBox)
        drawInvisibleText(page.lines, in: mediaBox, context: ctx)
        ctx.endPage()
    }

    static func drawInvisibleText(_ lines: [RecognizedLine], in pageBox: CGRect, context ctx: CGContext) {
        for line in lines {
            let rect = CGRect(x: pageBox.minX + line.box.minX * pageBox.width,
                              y: pageBox.minY + line.box.minY * pageBox.height,
                              width: line.box.width * pageBox.width,
                              height: line.box.height * pageBox.height)
            guard rect.width > 1, rect.height > 1 else { continue }

            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
            let attributed = NSAttributedString(string: line.text,
                                                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let lineWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard lineWidth > 0 else { continue }

            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            ctx.textMatrix = .identity
            // Grundlinie etwas über der Unterkante, Breite exakt auf die erkannte Zeile gestreckt.
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.2)
            ctx.scaleBy(x: rect.width / lineWidth, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }
}
