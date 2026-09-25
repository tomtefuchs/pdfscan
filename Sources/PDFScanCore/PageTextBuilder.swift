import CoreGraphics
import Foundation

/// Baut aus den Vision-Zeilen den Seitentext, den die Trennlogik erwartet – als Ersatz für
/// `pdfplumber.extract_text(layout=True)` (Volltext) und die Wortpositionen im Rand.
public enum PageTextBuilder {
    /// - Parameters:
    ///   - lines: erkannte Zeilen der ganzen Seite (normierte Boxen, Ursprung unten links).
    ///   - pageSize: Seitengröße in Punkt (1/72 Zoll).
    ///   - verticalMarginLines: Text aus den gedrehten Randstreifen (siehe `MarginReader`).
    public static func make(lines: [RecognizedLine], pageSize: CGSize, verticalMarginLines: [String]) -> PageText {
        let margin = DocumentBoundaryDetector.marginPoints
        let w = pageSize.width, h = pageSize.height

        // Rand wie im Original: Wort liegt vollständig im 30-pt-Streifen links, rechts, oben oder unten.
        let marginLines = lines.filter { line in
            let x0 = line.box.minX * w, x1 = line.box.maxX * w
            let top = (1 - line.box.maxY) * h, bottom = (1 - line.box.minY) * h
            return x1 < margin || x0 > w - margin || bottom < margin || top > h - margin
        }

        // Volltext: Zeilen von oben nach unten, Zeilen auf gleicher Höhe links nach rechts.
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let last = rows.last?.first,
               abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var bodyLines = rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
        // Senkrechte Randtexte als eigene Zeilen anhängen, damit der Zählerblock („0001“ über „0004“)
        // und Randzähler („1/4“) gefunden werden.
        bodyLines += verticalMarginLines

        return PageText(body: bodyLines.joined(separator: "\n"),
                        margin: (marginLines.map(\.text) + verticalMarginLines).joined(separator: " "))
    }
}

/// Liest senkrecht gedruckten Text im linken und rechten Blattrand (Druckstraßen-Kennungen,
/// Randzähler). Vision erkennt um 90° gedrehten Text auf der ganzen Seite nicht zuverlässig,
/// deshalb werden die Streifen ausgeschnitten und aufrecht gedreht gelesen. Um 180° gedrehten
/// Text liest Vision selbst korrekt, eine Drehrichtung genügt.
public enum MarginReader {
    public static func verticalLines(in image: CGImage, dpi: Double) -> [String] {
        // Etwas breiter als der 30-pt-Rand, damit Zeichen an der Grenze nicht abgeschnitten werden.
        let stripWidth = Int((DocumentBoundaryDetector.marginPoints + 8) / 72 * dpi)
        guard stripWidth > 4, image.width > stripWidth * 3 else { return [] }
        let strips = [
            CGRect(x: 0, y: 0, width: stripWidth, height: image.height),
            CGRect(x: image.width - stripWidth, y: 0, width: stripWidth, height: image.height),
        ]
        var result: [String] = []
        for rect in strips {
            guard let strip = image.cropping(to: rect),
                  let upright = ImageOps.rotated(strip, clockwiseDegrees: 90),
                  let lines = try? TextRecognizer.recognize(upright, languages: [], languageCorrection: false)
            else { continue }
            // Reihenfolge wie auf dem gedrehten Streifen: oben nach unten, links nach rechts.
            result += lines.sorted { ($0.box.midY, -$0.box.minX) > ($1.box.midY, -$1.box.minX) }.map(\.text)
        }
        return result
    }
}
