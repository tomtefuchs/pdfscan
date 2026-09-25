import Foundation

/// Dateinamen nach dem Schema `<Präfix><Jahr>_<Monat>_<Tag>_<Batch>_<Dokument>.pdf`,
/// z. B. `Scan_2026_09_25_003_01.pdf`.
///
/// Ein Batch ist ein Speichervorgang (ein Stapel), das Dokument zählt innerhalb des Batches.
/// Der Batch-Zähler beginnt jeden Tag bei 1 und wird aus den bereits im Zielordner liegenden
/// Dateien fortgesetzt, damit auch nach einem Neustart der App nichts überschrieben wird.
public struct DocumentNaming {
    public var prefix: String
    public var batchDigits: Int
    public var documentDigits: Int

    public init(prefix: String, batchDigits: Int = 3, documentDigits: Int = 2) {
        self.prefix = prefix
        self.batchDigits = batchDigits
        self.documentDigits = documentDigits
    }

    /// `<Präfix>2026_09_25_`
    public func datePart(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return prefix + String(format: "%04d_%02d_%02d_", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func fileName(date: Date, batch: Int, document: Int, calendar: Calendar = .current) -> String {
        datePart(date, calendar: calendar) + pad(batch, batchDigits) + "_" + pad(document, documentDigits) + ".pdf"
    }

    /// Nächste freie Batch-Nummer für diesen Tag, anhand vorhandener Dateinamen.
    public func nextBatch(existingFileNames: [String], date: Date, calendar: Calendar = .current) -> Int {
        let start = datePart(date, calendar: calendar)
        let used = existingFileNames.compactMap { name -> Int? in
            guard name.hasPrefix(start) else { return nil }
            let digits = name.dropFirst(start.count).prefix { $0.isNumber }
            return Int(digits)
        }
        return (used.max() ?? 0) + 1
    }

    public func nextBatch(in folder: URL, date: Date, calendar: Calendar = .current) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return nextBatch(existingFileNames: names, date: date, calendar: calendar)
    }

    /// Entfernt Zeichen, die in Dateinamen stören (Pfadtrenner, Doppelpunkt).
    public static func sanitizedPrefix(_ prefix: String) -> String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
    }

    private func pad(_ value: Int, _ digits: Int) -> String {
        let text = String(value)
        return text.count >= digits ? text : String(repeating: "0", count: digits - text.count) + text
    }
}

/// Teilt eine Seitenfolge an Trennmarken in einzelne Dokumente.
public enum DocumentSplitter {
    /// - Parameters:
    ///   - startsDocument: pro Seite, ob mit ihr ein neues Dokument beginnt.
    ///   - excluded: pro Seite, ob sie weggelassen wird (z. B. Leerseite). Die Trennmarke einer
    ///     weggelassenen Seite gilt für die nächste übernommene Seite.
    /// - Returns: Seitenindizes je Dokument, leere Dokumente entfallen.
    public static func group(startsDocument: [Bool], excluded: [Bool]) -> [[Int]] {
        var documents: [[Int]] = []
        var current: [Int] = []
        var pendingBreak = false
        for index in startsDocument.indices {
            if startsDocument[index] { pendingBreak = true }
            guard !excluded[index] else { continue }
            if pendingBreak, !current.isEmpty {
                documents.append(current)
                current = []
            }
            pendingBreak = false
            current.append(index)
        }
        if !current.isEmpty { documents.append(current) }
        return documents
    }
}
