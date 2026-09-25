import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Eine erkannte Textzeile. `box` ist normiert (0…1), Ursprung unten links – wie bei Vision und PDF.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect
    public var confidence: Float

    public init(text: String, box: CGRect, confidence: Float) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// Texterkennung über das Vision-Framework (läuft komplett lokal).
public enum TextRecognizer {
    public static func recognize(_ image: CGImage,
                                 languages: [String],
                                 orientation: CGImagePropertyOrientation = .up,
                                 fast: Bool = false) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        if !languages.isEmpty {
            // Nicht unterstützte Sprachen würden die Anfrage scheitern lassen.
            let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
            let usable = languages.filter { supported.contains($0) }
            if !usable.isEmpty { request.recognitionLanguages = usable }
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(text: text, box: observation.boundingBox, confidence: candidate.confidence)
        }
    }

    /// Ermittelt, um wie viel Grad (im Uhrzeigersinn) das Bild gedreht werden muss, damit der Text aufrecht steht.
    /// Probiert alle vier Ausrichtungen mit der schnellen Erkennung und nimmt die mit dem meisten plausiblen Text.
    public static func uprightRotation(for image: CGImage) -> Int {
        let small = ImageOps.scaled(image, maxDimension: 1600)
        let candidates: [(CGImagePropertyOrientation, Int)] = [(.up, 0), (.right, 90), (.down, 180), (.left, 270)]
        var scores: [Int: Double] = [:]
        for (orientation, degrees) in candidates {
            let lines = (try? recognize(small, languages: [], orientation: orientation, fast: true)) ?? []
            scores[degrees] = lines.reduce(0) { $0 + plausibility(of: $1) }
        }
        let upright = scores[0] ?? 0
        guard let best = scores.max(by: { $0.value < $1.value }),
              best.key != 0, best.value > 20, best.value > upright * 1.5
        else { return 0 }
        return best.key
    }

    /// Buchstaben in "echten" Wörtern (≥ 3 Buchstaben), gewichtet mit der Konfidenz.
    /// Falsch herum gelesener Text liefert meist nur kurze Fragmente und Sonderzeichen.
    static func plausibility(of line: RecognizedLine) -> Double {
        let letters = line.text
            .split(whereSeparator: { !$0.isLetter })
            .filter { $0.count >= 3 }
            .reduce(0) { $0 + $1.count }
        return Double(letters) * Double(line.confidence)
    }
}
