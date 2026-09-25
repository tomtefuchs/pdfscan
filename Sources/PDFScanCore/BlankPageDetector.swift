import CoreGraphics
import Foundation

/// Erkennt leere Seiten (typisch: unbedruckte Rückseiten beim Duplex-Scan).
public enum BlankPageDetector {
    /// Anteil der "Tinte" auf der Seite (0…1). Ränder werden ignoriert, weil dort oft Scan-Schatten liegen.
    /// Der Hintergrund wird aus dem Median bestimmt, damit vergilbtes Papier nicht als Inhalt zählt.
    public static func inkCoverage(_ image: CGImage) -> Double {
        let width = min(image.width, 600)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        guard let ctx = ImageOps.makeContext(width: width, height: height, gray: true) else { return 1 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return 1 }
        let bytesPerRow = ctx.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        let marginX = width * 4 / 100, marginY = height * 4 / 100
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for y in marginY..<(height - marginY) {
            for x in marginX..<(width - marginX) {
                histogram[Int(pixels[y * bytesPerRow + x])] += 1
                total += 1
            }
        }
        guard total > 0 else { return 0 }

        var accumulated = 0
        var background = 255
        for value in 0..<256 {
            accumulated += histogram[value]
            if accumulated * 2 >= total { background = value; break }
        }
        let threshold = max(0, background - 45)
        let ink = histogram[0..<threshold].reduce(0, +)
        return Double(ink) / Double(total)
    }

    /// Leer = kaum Tinte und praktisch kein erkannter Text.
    public static func isBlank(_ image: CGImage, recognizedCharacters: Int, maxCoverage: Double = 0.004) -> Bool {
        recognizedCharacters < 10 && inkCoverage(image) < maxCoverage
    }
}
