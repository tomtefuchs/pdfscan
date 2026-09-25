import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Hilfsfunktionen zum Laden, Drehen, Skalieren und Speichern von Seitenbildern.
public enum ImageOps {
    /// Lädt das erste Bild einer Datei, EXIF-Orientierung bereits angewendet.
    public static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return orientedImage(source, index: 0)
    }

    /// Lädt alle Bilder einer Datei (z. B. mehrseitiges TIFF).
    public static func loadImages(at url: URL) -> [CGImage] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { orientedImage(source, index: $0) }
    }

    /// Auflösung aus den Bild-Metadaten, sofern plausibel für einen Scan.
    public static func dpi(at url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
              (100...2400).contains(dpi)
        else { return nil }
        return dpi
    }

    /// Verkleinertes Vorschaubild, ohne das ganze Bild zu dekodieren.
    public static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Skaliert so, dass die längere Seite höchstens `maxDimension` Pixel hat.
    public static func scaled(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxDimension else { return image }
        let factor = Double(maxDimension) / Double(longest)
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let ctx = makeContext(width: width, height: height, gray: isGray(image)) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// Dreht das Bild im Uhrzeigersinn um 0, 90, 180 oder 270 Grad.
    public static func rotated(_ image: CGImage, clockwiseDegrees: Int) -> CGImage? {
        let degrees = ((clockwiseDegrees % 360) + 360) % 360
        guard degrees != 0 else { return image }
        let width = image.width, height = image.height
        let (newWidth, newHeight) = degrees == 180 ? (width, height) : (height, width)
        guard let ctx = makeContext(width: newWidth, height: newHeight, gray: isGray(image)) else { return nil }
        ctx.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
        // Positive Winkel drehen in Quartz gegen den Uhrzeigersinn.
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180)
        ctx.draw(image, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2,
                                   width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage()
    }

    /// Speichert verlustfrei als PNG (Arbeitskopie einer Seite).
    public static func writePNG(_ image: CGImage, to url: URL, dpi: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PDFScanError.cannotWriteImage(url)
        }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PDFScanError.cannotWriteImage(url) }
    }

    /// JPEG-kodierte Daten, z. B. zum Einbetten ins PDF.
    public static func jpegData(_ image: CGImage, quality: Double, dpi: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.1), 1.0),
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, flattened(image), props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Rendert jede Seite eines PDFs als Bild (für das nachträgliche OCR alter Scan-PDFs).
    public static func renderPDFPages(at url: URL, dpi: Double, _ body: (CGImage) throws -> Void) rethrows {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return }
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index) else { continue }
            let box = page.getBoxRect(.cropBox)
            let quarterTurns = (page.rotationAngle / 90) % 2 != 0
            let size = quarterTurns ? CGSize(width: box.height, height: box.width) : box.size
            let scale = dpi / 72
            let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
            guard width > 0, height > 0, let ctx = makeContext(width: width, height: height, gray: false) else { continue }
            ctx.scaleBy(x: scale, y: scale)
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                     rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            if let image = ctx.makeImage() { try body(image) }
        }
    }

    // MARK: - Intern

    static func isGray(_ image: CGImage) -> Bool {
        image.colorSpace?.model == .monochrome
    }

    /// Bitmap-Kontext mit weißem Hintergrund (transparente Bereiche werden weiß).
    static func makeContext(width: Int, height: Int, gray: Bool) -> CGContext? {
        let ctx: CGContext?
        if gray {
            ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        ctx?.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// Entfernt einen Alphakanal bzw. ungewöhnliche Bittiefen, damit JPEG sauber kodiert.
    static func flattened(_ image: CGImage) -> CGImage {
        let alpha = image.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst)
        guard hasAlpha || image.bitsPerComponent != 8 else { return image }
        guard let ctx = makeContext(width: image.width, height: image.height, gray: isGray(image)) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func orientedImage(_ source: CGImageSource, index: Int) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard orientation != 1, width > 0, height > 0 else {
            return CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}

public enum PDFScanError: LocalizedError {
    case noPages
    case cannotCreatePDF(URL)
    case unreadableImage(URL)
    case cannotWriteImage(URL)

    public var errorDescription: String? {
        switch self {
        case .noPages: return "Keine Seiten zum Speichern."
        case .cannotCreatePDF(let url): return "PDF konnte nicht erstellt werden: \(url.path)"
        case .unreadableImage(let url): return "Bild konnte nicht gelesen werden: \(url.lastPathComponent)"
        case .cannotWriteImage(let url): return "Bild konnte nicht gespeichert werden: \(url.lastPathComponent)"
        }
    }
}
