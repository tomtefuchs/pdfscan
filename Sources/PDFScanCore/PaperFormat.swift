import Foundation

/// Papierformat für den Einzug. Der Scanner-Treiber meldet seine Formate als interne Nummern;
/// ausgewählt wird anhand der tatsächlichen Größe, nicht anhand der Nummer.
public enum PaperFormat: String, CaseIterable, Identifiable, Sendable {
    case a4, a5, letter, legal, largest, driverDefault

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .a4: return "A4 (210 × 297 mm)"
        case .a5: return "A5 (148 × 210 mm)"
        case .letter: return "US Letter (216 × 279 mm)"
        case .legal: return "US Legal (216 × 356 mm)"
        case .largest: return "Größtes Format des Scanners"
        case .driverDefault: return "Vom Treiber vorgegeben"
        }
    }

    /// Zielgröße in mm (kurze Seite, lange Seite).
    public var sizeMM: (Double, Double)? {
        switch self {
        case .a4: return (210, 297)
        case .a5: return (148, 210)
        case .letter: return (215.9, 279.4)
        case .legal: return (215.9, 355.6)
        case .largest, .driverDefault: return nil
        }
    }

    /// Ein vom Treiber angebotenes Format.
    public struct Candidate: Equatable, Sendable {
        public var id: UInt
        public var widthMM: Double
        public var heightMM: Double

        public init(id: UInt, widthMM: Double, heightMM: Double) {
            self.id = id
            self.widthMM = widthMM
            self.heightMM = heightMM
        }

        var short: Double { min(widthMM, heightMM) }
        var long: Double { max(widthMM, heightMM) }
    }

    /// Wählt das passende Treiberformat. Bei festen Formaten muss die Größe auf 3 mm stimmen –
    /// sonst lieber das nächstgrößere, damit nichts abgeschnitten wird.
    public func bestMatch(in candidates: [Candidate]) -> Candidate? {
        let usable = candidates.filter { $0.short > 0 && $0.long > 0 }
        switch self {
        case .driverDefault:
            return nil
        case .largest:
            return usable.max { $0.short * $0.long < $1.short * $1.long }
        default:
            guard let (short, long) = sizeMM else { return nil }
            if let exact = usable.first(where: { abs($0.short - short) <= 3 && abs($0.long - long) <= 3 }) {
                return exact
            }
            // Kleinstes Format, in das die Zielgröße vollständig passt.
            return usable
                .filter { $0.short >= short - 3 && $0.long >= long - 3 }
                .min { $0.short * $0.long < $1.short * $1.long }
                ?? usable.max { $0.short * $0.long < $1.short * $1.long }
        }
    }

    /// Umrechnung der Maßeinheiten von ImageCaptureCore (ICScannerMeasurementUnit) in mm.
    public static func millimeters(_ value: Double, unitRawValue: UInt, resolution: Double) -> Double {
        switch unitRawValue {
        case 0: return value * 25.4                 // Zoll
        case 1: return value * 10                   // Zentimeter
        case 2: return value * 25.4 / 6             // Pica
        case 3: return value * 25.4 / 72            // Punkt
        case 4: return value * 25.4 / 1440          // Twip
        case 5: return resolution > 0 ? value * 25.4 / resolution : 0   // Pixel
        default: return value * 25.4
        }
    }
}
