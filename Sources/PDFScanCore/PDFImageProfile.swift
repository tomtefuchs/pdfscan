import CoreGraphics
import Foundation

/// Wie die Seitenbilder ins PDF kommen – bestimmt im Wesentlichen die Dateigröße.
/// Die Texterkennung läuft immer auf dem vollen Scan; das Profil betrifft nur das gespeicherte Bild.
public struct PDFImageProfile: Equatable, Sendable {
    /// Höchstauflösung des Bildes im PDF (nil = unverändert).
    public var maxDPI: Double?
    /// Seiten ohne nennenswerte Farbe in Graustufen speichern.
    public var grayscaleWhenColorless: Bool
    /// Vergilbtes Papier aufhellen (nur bei Graustufen-Seiten).
    public var whitenBackground: Bool
    public var jpegQuality: Double

    public init(maxDPI: Double?, grayscaleWhenColorless: Bool, whitenBackground: Bool, jpegQuality: Double) {
        self.maxDPI = maxDPI
        self.grayscaleWhenColorless = grayscaleWhenColorless
        self.whitenBackground = whitenBackground
        self.jpegQuality = jpegQuality
    }

    /// Etwa 100–250 KB pro A4-Seite.
    public static let compact = PDFImageProfile(maxDPI: 200, grayscaleWhenColorless: true,
                                                whitenBackground: true, jpegQuality: 0.6)
    /// Etwa 300–600 KB pro A4-Seite.
    public static let balanced = PDFImageProfile(maxDPI: 300, grayscaleWhenColorless: true,
                                                 whitenBackground: false, jpegQuality: 0.7)
    /// Scan unverändert, nur JPEG-komprimiert (etwa 1–2 MB pro A4-Seite in Farbe).
    public static let original = PDFImageProfile(maxDPI: nil, grayscaleWhenColorless: false,
                                                 whitenBackground: false, jpegQuality: 0.85)

    /// Bereitet ein Seitenbild für das PDF auf.
    public func prepare(_ image: CGImage, dpi: Double) -> CGImage {
        var result = image
        if grayscaleWhenColorless, !ImageOps.isGray(result), ImageOps.isEffectivelyGrayscale(result) {
            result = ImageOps.grayscale(result) ?? result
        }
        if whitenBackground, ImageOps.isGray(result) {
            result = ImageOps.whitenedBackground(result) ?? result
        }
        if let maxDPI, dpi > maxDPI * 1.05 {
            let factor = maxDPI / dpi
            let longest = Int((Double(max(result.width, result.height)) * factor).rounded())
            result = ImageOps.scaled(result, maxDimension: longest)
        }
        return result
    }
}

extension ImageOps {
    /// Hat die Seite echte Farbe (Stempel, farbige Tinte, Fotos) – oder nur vergilbtes Papier und Schwarz?
    /// Vergilbtes Papier hat eine Buntheit von etwa 30–50; gezählt werden nur deutlich bunte Pixel.
    public static func isEffectivelyGrayscale(_ image: CGImage, colorfulFraction: Double = 0.001) -> Bool {
        let small = scaled(image, maxDimension: 400)
        let width = small.width, height = small.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var colorful = 0
        for i in 0..<(width * height) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            if max(r, g, b) - min(r, g, b) > 70 { colorful += 1 }
        }
        return Double(colorful) < Double(width * height) * colorfulFraction
    }

    /// Graustufen-Kopie.
    public static func grayscale(_ image: CGImage) -> CGImage? {
        guard let ctx = makeContext(width: image.width, height: image.height, gray: true) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Hellt den Papierton auf Weiß auf und zieht Schwarz leicht nach (nur Graustufen).
    /// Der Papierton wird wie bei der Leerseiten-Erkennung aus dem Median bestimmt.
    public static func whitenedBackground(_ image: CGImage) -> CGImage? {
        guard isGray(image),
              let ctx = makeContext(width: image.width, height: image.height, gray: true) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let count = ctx.bytesPerRow * image.height
        let pixels = data.bindMemory(to: UInt8.self, capacity: count)

        var histogram = [Int](repeating: 0, count: 256)
        let step = max(1, count / 200_000)
        var sampled = 0
        for i in stride(from: 0, to: count, by: step) {
            histogram[Int(pixels[i])] += 1
            sampled += 1
        }
        var accumulated = 0, paper = 255
        for value in 0..<256 {
            accumulated += histogram[value]
            if accumulated * 2 >= sampled { paper = value; break }
        }
        // Nur echte Papierflächen aufhellen, dunkle Seiten (Fotos) unverändert lassen.
        guard paper > 120 else { return ctx.makeImage() }

        let white = Double(paper) - 8     // knapp unter dem Papierton ist schon Weiß
        let black = 30.0
        var table = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            let t = (Double(v) - black) / (white - black)
            table[v] = UInt8(max(0, min(255, (t * 255).rounded())))
        }
        for i in 0..<count { pixels[i] = table[Int(pixels[i])] }
        return ctx.makeImage()
    }
}
