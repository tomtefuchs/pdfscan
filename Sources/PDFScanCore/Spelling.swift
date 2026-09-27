import AppKit
import Foundation

/// Rechtschreibprüfung über die macOS-Wörterbücher (lokal). Maß dafür, wie viel einer OCR-Zeile echte Wörter sind:
/// Druckschrift liefert fast nur echte Wörter, schlecht gelesene Handschrift Gebilde wie „Sevezhet“ oder „hlanen“.
/// Die Konfidenz von Vision taugt dafür nicht – sie steht auch bei solchem Unsinn oft auf 1,0.
public enum Spelling {
    public struct Count: Equatable, Sendable {
        /// Buchstaben in Wörtern, die das Wörterbuch kennt.
        public var known = 0
        /// Buchstaben in geprüften Wörtern insgesamt.
        public var checked = 0
        public var words = 0
        public var knownWords = 0

        public var knownFraction: Double { words == 0 ? 0 : Double(knownWords) / Double(words) }
    }

    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]

    /// Prüft alle Wörter ab drei Buchstaben. `languages` wie in den Einstellungen („de-DE“, „en-US“).
    public static func count(_ text: String, languages: [String]) -> Count {
        var result = Count()
        let words = text.split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        guard !words.isEmpty else { return result }
        let codes = dictionaryLanguages(for: languages)
        for word in words {
            result.words += 1
            result.checked += word.count
            if isKnown(word, languages: codes) {
                result.knownWords += 1
                result.known += word.count
            }
        }
        return result
    }

    static func isKnown(_ word: String, languages: [String?]) -> Bool {
        let key = languages.map { $0 ?? "*" }.joined(separator: ",") + "|" + word
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let checker = NSSpellChecker.shared
        let known = languages.contains { language in
            checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        cache[key] = known
        return known
    }

    /// „de-DE“ → „de“, sofern ein Wörterbuch dafür installiert ist; sonst automatische Spracherkennung (nil).
    static func dictionaryLanguages(for languages: [String]) -> [String?] {
        lock.lock()
        let available = NSSpellChecker.shared.availableLanguages
        lock.unlock()
        var codes: [String?] = []
        for language in languages.isEmpty ? ["de-DE", "en-US"] : languages {
            let underscored = language.replacingOccurrences(of: "-", with: "_")
            let base = String(language.prefix { $0 != "-" && $0 != "_" })
            if let match = [underscored, base].first(where: available.contains), !codes.contains(match) {
                codes.append(match)
            }
        }
        return codes.isEmpty ? [nil] : codes
    }
}
