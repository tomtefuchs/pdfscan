import CoreGraphics
import Foundation
import Vision

/// Wann der zusätzliche Handschrift-Durchgang läuft.
public enum HandwritingMode: String, CaseIterable, Identifiable, Sendable {
    /// Nur die normale Texterkennung.
    case off
    /// Zweiter Durchgang, wenn die Seite nach Handschrift aussieht (viel Tinte, wenig oder unsicherer Text).
    case auto
    /// Jede Seite bekommt den zweiten Durchgang (langsamer).
    case always

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return "Aus"
        case .auto: return "Automatisch (empfohlen)"
        case .always: return "Immer (langsamer)"
        }
    }
}

/// Ergebnis der Texterkennung einer Seite inklusive Handschrift-Durchgang.
public struct PageRecognition: Sendable {
    public var lines: [RecognizedLine]
    /// Der Handschrift-Durchgang ist gelaufen.
    public var handwritingPass: Bool
    /// Der Handschrift-Durchgang hat Zeilen beigesteuert oder ersetzt.
    public var handwritingImproved: Bool
}

/// Handschrift mit Vision – komplett lokal.
///
/// Vision liest Handschrift nur im Modus „accurate“, und bei blasser oder farbiger Tinte schlechter
/// als Druckschrift. Der Handschrift-Durchgang erkennt deshalb ein kontrastverstärktes Bild aus dem dunkelsten
/// Farbkanal (Tinte → Schwarz, Papier und Karoraster → Weiß), ganz und in Streifen, und übernimmt pro Zeile
/// das bessere Ergebnis. Flüchtige Schreibschrift liest Vision trotzdem nur teilweise.
/// Deutsche Schreibschrift der letzten Jahrzehnte klappt oft, Kurrent und Sütterlin kann Vision nicht lesen.
public enum HandwritingRecognizer {
    /// Normale Texterkennung, bei Bedarf gefolgt vom Handschrift-Durchgang.
    public static func recognizePage(_ image: CGImage, languages: [String], mode: HandwritingMode) throws -> PageRecognition {
        let printed = try TextRecognizer.recognize(image, languages: languages)
        let needsPass: Bool
        switch mode {
        case .off: needsPass = false
        case .always: needsPass = true
        case .auto: needsPass = looksHandwritten(lines: printed, inkCoverage: BlankPageDetector.inkCoverage(image),
                                                 languages: languages)
        }
        guard needsPass else {
            return PageRecognition(lines: printed, handwritingPass: false, handwritingImproved: false)
        }
        let handwritten = (try? recognize(image, languages: languages)) ?? []
        let merged = merge(printed, handwritten, languages: languages)
        return PageRecognition(lines: merged, handwritingPass: true, handwritingImproved: merged != printed)
    }

    /// Der eigentliche Handschrift-Durchgang: drei Lesarten des kontrastverstärkten Bildes – Graustufen,
    /// dunkelster Farbkanal und dunkelster Farbkanal in überlappenden Streifen. Jede liest andere Zeilen gut;
    /// pro Zeile gewinnt die Lesart mit den meisten echten Wörtern.
    public static func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let gray = enhanced(image, channel: .luminance) ?? image
        let darkest = enhanced(image) ?? image
        let fromGray = try TextRecognizer.recognize(gray, languages: languages, languageCorrection: true)
        let fromDarkest = try TextRecognizer.recognize(darkest, languages: languages, languageCorrection: true)
        let fromStrips = try recognizeInStrips(darkest, languages: languages)
        let merged = merge(fromGray, fromDarkest, languages: languages)
        return merge(merged, fromStrips, languages: languages)
    }

    /// Texterkennung in waagerechten Streifen mit Überlappung, Boxen auf die ganze Seite umgerechnet.
    /// Eine an der Streifengrenze zerschnittene Zeile steht in der Überlappung vollständig im Nachbarstreifen;
    /// beim Zusammenführen gewinnt die vollständige.
    public static func recognizeInStrips(_ image: CGImage, languages: [String], count: Int = 3,
                                         overlap: Double = 0.2) throws -> [RecognizedLine] {
        let height = Double(image.height)
        let step = height / Double(count)
        var result: [RecognizedLine] = []
        for index in 0..<count {
            // Pixelkoordinaten mit Ursprung oben (wie `cropping(to:)`).
            let top = max(0, (Double(index) - overlap) * step).rounded()
            let bottom = min(height, (Double(index + 1) + overlap) * step).rounded()
            guard bottom > top,
                  let strip = image.cropping(to: CGRect(x: 0, y: top, width: Double(image.width), height: bottom - top))
            else { continue }
            let lines = try TextRecognizer.recognize(strip, languages: languages, languageCorrection: true)
            let originY = (height - bottom) / height, scaleY = (bottom - top) / height
            result += lines.map { line in
                var mapped = line
                mapped.box = CGRect(x: line.box.minX, y: originY + line.box.minY * scaleY,
                                    width: line.box.width, height: line.box.height * scaleY)
                return mapped
            }
        }
        return merge([], result, languages: languages)
    }

    /// Alle Varianten einzeln – für den Vergleich auf echten Scans (`PDFScan --ocr-vergleich <Datei>`).
    public static func variants(_ image: CGImage, languages: [String]) -> [(name: String, lines: [RecognizedLine])] {
        let gray = enhanced(image, channel: .luminance) ?? image
        let darkest = enhanced(image) ?? image
        let run = { (image: CGImage) in
            (try? TextRecognizer.recognize(image, languages: languages, languageCorrection: true)) ?? []
        }
        return [
            ("Normal (ohne Handschrift-Durchgang)", (try? TextRecognizer.recognize(image, languages: languages)) ?? []),
            ("Grau, Kontrast verstärkt", run(gray)),
            ("Dunkelster Farbkanal, Kontrast verstärkt", run(darkest)),
            ("Dunkelster Farbkanal, in Streifen", (try? recognizeInStrips(darkest, languages: languages)) ?? []),
            ("Ergebnis der App (Modus „Immer“)",
             (try? recognizePage(image, languages: languages, mode: .always).lines) ?? []),
        ]
    }

    /// Sieht die Seite nach Handschrift aus? Grobe Faustregel, bewusst großzügig –
    /// ein unnötiger zweiter Durchgang kostet nur Zeit, das Zusammenführen behält das bessere Ergebnis.
    /// - Tinte, aber kaum erkannter Text (Notizzettel, Randvermerke)
    /// - wenige echte Wörter (Druck: fast alle Wörter stehen im Wörterbuch, gelesene Handschrift: oft unter der Hälfte)
    /// - unsichere Erkennung (bei Handschrift meldet Vision allerdings oft trotzdem 1,0)
    /// - viel Tinte pro erkanntem Zeichen (Handschrift ist groß und wird nur teilweise gelesen)
    public static func looksHandwritten(lines: [RecognizedLine], inkCoverage: Double,
                                        languages: [String] = ["de-DE", "en-US"]) -> Bool {
        guard inkCoverage >= 0.003 else { return false }
        let characters = lines.reduce(0) { $0 + $1.text.count }
        if characters < 20 { return true }
        let spelling = Spelling.count(lines.map(\.text).joined(separator: " "), languages: languages)
        if spelling.words >= 8, spelling.knownFraction < 0.7 { return true }
        let confidence = lines.reduce(0.0) { $0 + Double($1.confidence) * Double($1.text.count) } / Double(characters)
        if confidence < 0.6 { return true }
        return inkCoverage / Double(characters) > 1.5e-4
    }

    /// Führt die Zeilen zweier Lesarten zusammen. Überlappen sich Zeilen, gewinnt die mit mehr Buchstaben in
    /// echten Wörtern (siehe `score`); neue Zeilen kommen dazu.
    /// Ergebnis in Lesereihenfolge (oben nach unten, links nach rechts).
    public static func merge(_ base: [RecognizedLine], _ extra: [RecognizedLine],
                             languages: [String] = ["de-DE", "en-US"]) -> [RecognizedLine] {
        var result = base
        for line in extra {
            let overlapping = result.indices.filter { overlaps(result[$0].box, line.box) }
            if overlapping.isEmpty {
                result.append(line)
                continue
            }
            let existing = overlapping.reduce(0.0) { $0 + score(result[$1], languages: languages) }
            if score(line, languages: languages) > existing * 1.1 {
                for index in overlapping.reversed() { result.remove(at: index) }
                result.append(line)
            }
        }
        return result.sorted { a, b in
            // Gleiche Zeile, wenn sich die Höhen deutlich überschneiden.
            let shared = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
            if shared > 0.5 * min(a.box.height, b.box.height) { return a.box.minX < b.box.minX }
            return a.box.midY > b.box.midY
        }
    }

    /// Buchstaben in echten Wörtern zählen voll, der Rest (Zahlen, Kürzel, Unsinn) zu 30 %; dazu leicht die Konfidenz.
    /// Ohne Wörterbuch-Bewertung gewänne einfach die längere Zeile – bei Handschrift oft die mit mehr Unsinn.
    static func score(_ line: RecognizedLine, languages: [String]) -> Double {
        let visible = line.text.filter { !$0.isWhitespace }.count
        let known = Spelling.count(line.text, languages: languages).known
        return (Double(known) + 0.3 * Double(visible - known)) * (0.5 + 0.5 * Double(line.confidence))
    }

    /// Mindestens die Hälfte der kleineren Box liegt in der anderen.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && intersection.width * intersection.height >= smaller * 0.5
    }

    public enum Channel: Sendable {
        /// Normale Helligkeit – farbige Tinte (Blau, Türkis) wird dabei hellgrau.
        case luminance
        /// Dunkelster der drei Farbkanäle je Pixel: farbige Tinte wird fast schwarz,
        /// hellblaue oder graue Karo- und Linienraster bleiben hell und verschwinden beim Spreizen.
        case darkest
    }

    /// Graustufen mit gespreiztem Kontrast: Papierton → Weiß, dunkelste Striche → Schwarz,
    /// Zwischentöne mit Gamma > 1 abgedunkelt, damit blasse Tinte und Bleistift kräftig werden.
    public static func enhanced(_ image: CGImage, channel: Channel = .darkest) -> CGImage? {
        let width = image.width, height = image.height
        guard let ctx = ImageOps.makeContext(width: width, height: height, gray: true) else { return nil }
        let bytesPerRow = ctx.bytesPerRow
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        switch channel {
        case .luminance:
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        case .darkest:
            guard let rgb = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let rgbData = rgb.data
            else { return nil }
            rgb.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            rgb.fill(CGRect(x: 0, y: 0, width: width, height: height))
            rgb.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let source = rgbData.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    pixels[y * bytesPerRow + x] = min(source[i], source[i + 1], source[i + 2])
                }
            }
        }

        // Nur echte Pixel zählen – die Füllbytes am Zeilenende sind 0 und würden als Tinte gelten.
        var histogram = [Int](repeating: 0, count: 256)
        let step = max(1, Int((Double(width * height) / 400_000).squareRoot()))
        var sampled = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                histogram[Int(pixels[y * bytesPerRow + x])] += 1
                sampled += 1
            }
        }
        let paper = percentile(histogram, total: sampled, 0.5)
        let ink = percentile(histogram, total: sampled, 0.001)
        let range = Double(paper - ink)
        // Kein Papier (Foto, dunkle Seite) oder keine Striche: nur umwandeln, nicht spreizen.
        guard paper > 100, range >= 25 else { return ctx.makeImage() }

        let white = Double(paper) - range * 0.15
        let black = Double(ink) + range * 0.05
        var table = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            let t = max(0, min(1, (Double(v) - black) / (white - black)))
            table[v] = UInt8((pow(t, 1.8) * 255).rounded())
        }
        for y in 0..<height {
            for x in 0..<width { pixels[y * bytesPerRow + x] = table[Int(pixels[y * bytesPerRow + x])] }
        }
        return ctx.makeImage()
    }

    /// Grauwert, unter dem der Anteil `fraction` der Pixel liegt.
    static func percentile(_ histogram: [Int], total: Int, _ fraction: Double) -> Int {
        let target = Double(total) * fraction
        var accumulated = 0
        for value in 0..<256 {
            accumulated += histogram[value]
            if Double(accumulated) >= target { return value }
        }
        return 255
    }
}
