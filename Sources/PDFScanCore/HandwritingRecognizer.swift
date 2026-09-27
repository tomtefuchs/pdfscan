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
/// Vision liest Handschrift nur im Modus „accurate“, und bei verblasster Tinte auf vergilbtem Papier
/// deutlich schlechter als Druckschrift. Der Handschrift-Durchgang erkennt deshalb ein kontrastverstärktes
/// Graustufenbild (Papier → Weiß, blasse Striche → kräftig) und übernimmt pro Zeile das bessere Ergebnis.
/// Deutsche Schreibschrift der letzten Jahrzehnte klappt oft, Kurrent und Sütterlin kann Vision nicht lesen.
public enum HandwritingRecognizer {
    /// Normale Texterkennung, bei Bedarf gefolgt vom Handschrift-Durchgang.
    public static func recognizePage(_ image: CGImage, languages: [String], mode: HandwritingMode) throws -> PageRecognition {
        let printed = try TextRecognizer.recognize(image, languages: languages)
        let needsPass: Bool
        switch mode {
        case .off: needsPass = false
        case .always: needsPass = true
        case .auto: needsPass = looksHandwritten(lines: printed, inkCoverage: BlankPageDetector.inkCoverage(image))
        }
        guard needsPass else {
            return PageRecognition(lines: printed, handwritingPass: false, handwritingImproved: false)
        }
        let handwritten = (try? recognize(image, languages: languages)) ?? []
        let merged = merge(printed, handwritten)
        return PageRecognition(lines: merged, handwritingPass: true, handwritingImproved: merged != printed)
    }

    /// Der eigentliche Handschrift-Durchgang auf dem kontrastverstärkten Bild.
    public static func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let prepared = enhanced(image) ?? image
        return try TextRecognizer.recognize(prepared, languages: languages, languageCorrection: true)
    }

    /// Sieht die Seite nach Handschrift aus? Grobe Faustregel, bewusst großzügig –
    /// ein unnötiger zweiter Durchgang kostet nur Zeit, das Zusammenführen behält das bessere Ergebnis.
    /// - Tinte, aber kaum erkannter Text (Notizzettel, Randvermerke)
    /// - unsichere Erkennung (Vision meldet bei Handschrift niedrige Konfidenzen)
    /// - viel Tinte pro erkanntem Zeichen (Handschrift ist groß und wird nur teilweise gelesen)
    public static func looksHandwritten(lines: [RecognizedLine], inkCoverage: Double) -> Bool {
        guard inkCoverage >= 0.003 else { return false }
        let characters = lines.reduce(0) { $0 + $1.text.count }
        if characters < 20 { return true }
        let confidence = lines.reduce(0.0) { $0 + Double($1.confidence) * Double($1.text.count) } / Double(characters)
        if confidence < 0.6 { return true }
        return inkCoverage / Double(characters) > 1.5e-4
    }

    /// Führt die Zeilen beider Durchgänge zusammen. Überlappen sich Zeilen, gewinnt die Seite mit mehr
    /// sicher erkannten Zeichen; neue Zeilen aus dem Handschrift-Durchgang kommen dazu.
    /// Ergebnis in Lesereihenfolge (oben nach unten, links nach rechts).
    public static func merge(_ base: [RecognizedLine], _ extra: [RecognizedLine]) -> [RecognizedLine] {
        var result = base
        for line in extra {
            let overlapping = result.indices.filter { overlaps(result[$0].box, line.box) }
            if overlapping.isEmpty {
                result.append(line)
                continue
            }
            let existing = overlapping.reduce(0.0) { $0 + score(result[$1]) }
            if score(line) > existing * 1.1 {
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

    static func score(_ line: RecognizedLine) -> Double {
        Double(line.text.filter { !$0.isWhitespace }.count) * Double(line.confidence)
    }

    /// Mindestens die Hälfte der kleineren Box liegt in der anderen.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && intersection.width * intersection.height >= smaller * 0.5
    }

    /// Graustufen mit gespreiztem Kontrast: Papierton → Weiß, dunkelste Striche → Schwarz,
    /// Zwischentöne mit Gamma > 1 abgedunkelt, damit blasse Tinte und Bleistift kräftig werden.
    public static func enhanced(_ image: CGImage) -> CGImage? {
        guard let ctx = ImageOps.makeContext(width: image.width, height: image.height, gray: true) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let width = image.width, height = image.height, bytesPerRow = ctx.bytesPerRow
        let count = bytesPerRow * height
        let pixels = data.bindMemory(to: UInt8.self, capacity: count)

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
        // Kein Papier (Foto, dunkle Seite) oder keine Striche: unverändert lassen.
        guard paper > 100, range >= 25 else { return ctx.makeImage() }

        let white = Double(paper) - range * 0.15
        let black = Double(ink) + range * 0.05
        var table = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            let t = max(0, min(1, (Double(v) - black) / (white - black)))
            table[v] = UInt8((pow(t, 1.8) * 255).rounded())
        }
        for i in 0..<count { pixels[i] = table[Int(pixels[i])] }
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
