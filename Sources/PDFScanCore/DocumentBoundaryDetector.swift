import Foundation

/// Text einer Seite, so aufbereitet wie ihn die Trennlogik erwartet.
public struct PageText: Equatable, Sendable {
    /// Volltext in Lesereihenfolge, zeilenweise.
    public var body: String
    /// Text aus dem Blattrand (Steuerzeichen und Kennungen der Druckstraße).
    public var margin: String

    public init(body: String, margin: String) {
        self.body = body
        self.margin = margin
    }
}

/// Zerlegt einen Sammelscan in Einzeldokumente.
///
/// Portierung von `reference/split_docs.py`, Logik und Schwellwerte unverändert.
///
/// Kaskade (in dieser Reihenfolge, erste sichere Aussage gewinnt):
///   1. Seiten-/Gesamtzähler (Fuß, Kopftabelle, senkrechter Randblock),
///      sowohl „neue Seite 1“ als auch „Vorseite war 4/4 und damit Schluss“
///   2. Vorgangskennung im Blattrand, unscharf verglichen
///   3. Anschriftenfeld mit Anrede
/// Ein Fortsetzungshinweis auf der Vorseite („Fortsetzung auf Seite 03“) unterdrückt einen Schnitt.
///
/// Ein *Sprung* im Zähler ist bewusst kein Signal: gescannte Blätter liegen nicht zwingend in
/// Leserichtung, und zerlesene Zähler springen ebenfalls. Nur der Zählerstand 1 zählt.
///
/// Bewusst übersegmentierend: ein zu viel gesetzter Schnitt kostet Sekunden, ein übersehener
/// versteckt ein Dokument dauerhaft.
public enum DocumentBoundaryDetector {
    public struct PageNumber: Equatable, Sendable {
        public var current: Int
        public var total: Int?
    }

    public enum Reason: Equatable, Sendable {
        case firstPage
        case counterReset
        case previousWasLast(Int, Int)
        case identifierChanged
        case letterHead
        case shortNote
        case afterShortNote
        case insert

        public var description: String {
            switch self {
            case .firstPage: return "erste Seite"
            case .counterReset: return "Zähler auf 1"
            case .previousWasLast(let current, let total): return "Vorseite \(current)/\(total) war Schluss"
            case .identifierChanged: return "Kennung wechselt"
            case .letterHead: return "Anschrift + Anrede"
            case .shortNote: return "kurzer Einzelzettel"
            case .afterShortNote: return "nach Einzelzettel"
            case .insert: return "Einschub ohne Zähler"
            }
        }
    }

    public struct Start: Equatable, Sendable {
        public var page: Int
        public var reason: Reason
    }

    public struct Result: Equatable, Sendable {
        /// Schnitte aus der Kaskade (vor dem Herauslösen von Einschüben).
        public var starts: [Start]
        public var pageNumbers: [PageNumber?]
        /// Seitenindizes je Dokument, sortiert nach erster Seite. Einschübe sind eigene Dokumente,
        /// daher sind die Dokumente nicht zwingend zusammenhängend.
        public var documents: [[Int]]
        /// Grund je Dokument (parallel zu `documents`).
        public var reasons: [Reason]
    }

    // MARK: - Schwellwerte (wie im Original)

    /// Token, das auf mehr als 40 % aller Seiten steht, ist Briefkopf, nicht Vorgangskennung.
    static let maxDF = 0.40
    /// Randbreite in Punkt (gut 1 cm), absolut statt relativ (Querformat, ISIN/WKN in Tabellen).
    public static let marginPoints = 30.0
    /// Ähnlichkeit, ab der zwei Kennungen als dieselbe gelten (OCR-Rauschen in der Kennung).
    static let fuzz = 0.80

    // MARK: - Signale

    /// Maschinenkennung aus Ziffern und Großbuchstaben, mindestens 8 Zeichen.
    static let token = Rx(#"\b(?=[A-Z0-9_]*\d)[A-Z][A-Z0-9_]{7,23}\b"#)
    /// Zählerblock: zwei nullgepolsterte Zahlen untereinander.
    static let vblock = Rx(#"^[ \t]*0*(\d{1,5})[ \t]*\n[ \t]*0*(\d{1,5})[ \t]*$"#, [.anchorsMatchLines])
    static let pgSlash = Rx(#"(?<![\d,.])(\d{1,3})\s*/\s*(\d{1,3})(?![\d,.])"#)
    static let pgWord = Rx(#"\bSeite\s+(\d{1,3})\b"#, [.caseInsensitive])
    static let cont = Rx(#"Fortsetzung auf Seite\s*0?(\d{1,3})"#, [.caseInsensitive])
    /// Anrede. Im Original nur „Sehr geehrte(r) Herr/Frau/Damen“ – Vereine, Genossenschaften und
    /// Versicherungen schreiben aber auch „Sehr geehrtes Mitglied“, „Sehr geehrte Kundin“ usw.
    /// Daher jedes Wort nach „Sehr geehrt…“, dazu „Guten Tag …“.
    static let salut = Rx(#"(?:Sehr\s+geehrt\w*|Guten\s+Tag)\s+\w"#, [.caseInsensitive])
    /// Postleitzahl + Ort. Im Original `[A-ZAOU]` – gemeint sind offensichtlich die Umlaute.
    static let addr = Rx(#"\b\d{5}\s+[A-ZÄÖÜ][a-zäöüß]"#, [.anchorsMatchLines])

    // MARK: - Einstieg

    /// Erweiterungen gegenüber reference/split_docs.py (für den Abgleich mit dem Original abschaltbar).
    public struct Options: Sendable {
        /// Seiten mit sehr wenig Text (handschriftliche Notiz, Zettel) sind eigene Dokumente.
        public var shortNotes = true

        public init(shortNotes: Bool = true) {
            self.shortNotes = shortNotes
        }

        /// Genau die Regeln des Python-Originals.
        public static let original = Options(shortNotes: false)
    }

    public static func split(_ pages: [PageText], options: Options = Options()) -> Result {
        guard !pages.isEmpty else { return Result(starts: [], pageNumbers: [], documents: [], reasons: []) }
        let texts = pages.map { squeeze($0.body) }
        let (starts, numbers) = findStarts(texts, margins: pages.map(\.margin), options: options)
        let bounds = starts.map(\.page) + [pages.count]
        var documents: [([Int], Reason)] = []
        for k in starts.indices {
            let parts = splitInserts(Array(bounds[k]..<bounds[k + 1]), numbers)
            documents.append((parts[0], starts[k].reason))
            documents += parts.dropFirst().map { ($0, Reason.insert) }
        }
        documents.sort { $0.0[0] < $1.0[0] }
        return Result(starts: starts, pageNumbers: numbers,
                      documents: documents.map(\.0), reasons: documents.map(\.1))
    }

    // MARK: - Bausteine

    /// OCR-Verwechslungen einebnen und Leserichtung vereinheitlichen.
    static func norm(_ s: String) -> String {
        let t = s.uppercased()
            .replacingOccurrences(of: "VV", with: "W")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "S", with: "5")
        let reversed = String(t.reversed())
        return pyLess(reversed, t) ? reversed : t
    }

    /// Füll-Leerzeichen kollabieren, Zeilenumbrüche bleiben.
    static func squeeze(_ t: String) -> String {
        t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    /// Pro Seite die Menge der Vorgangskennungen, ohne Briefkopf-Token.
    static func tokenSets(_ margins: [String]) -> [Set<String>] {
        let raw: [Set<String>] = margins.map { page in
            Set(token.findAll(page).map { norm($0[0]) }.filter { Set($0).count >= 4 })
        }
        var df: [String: Int] = [:]
        for set in raw { for t in set { df[t, default: 0] += 1 } }
        let limit = max(2, Int(Double(margins.count) * maxDF))
        return raw.map { $0.filter { df[$0, default: 0] <= limit } }
    }

    /// Teilen sich zwei Seiten eine Vorgangskennung (unscharf)?
    static func related(_ a: Set<String>, _ b: Set<String>) -> Bool {
        if !a.isDisjoint(with: b) { return true }
        for x in a {
            for y in b where abs(x.count - y.count) <= 2 && similarity(x, y) >= fuzz {
                return true
            }
        }
        return false
    }

    /// Schrägstrich-Paare, die auf zu vielen Seiten unverändert stehen (Formularnummern o. ä.).
    static func slashBlacklist(_ pages: [String]) -> Set<Pair> {
        var df: [Pair: Int] = [:]
        for t in pages {
            let found = pgSlash.findAll(head(t, 3000)) + pgSlash.findAll(tail(t, 700))
            let seen = Set(found.compactMap { m -> Pair? in
                guard let a = Int(m[1]), let b = Int(m[2]) else { return nil }
                return Pair(a: a, b: b)
            })
            for pair in seen { df[pair, default: 0] += 1 }
        }
        let limit = max(2, Int(Double(pages.count) * maxDF))
        return Set(df.filter { $0.value > limit }.keys)
    }

    /// Wahrscheinlichste (Seite, Gesamt) der Seite: Randblock, dann Fuß, dann Kopf, dann „Seite n“.
    static func pageNumber(_ text: String, skip: Set<Pair> = []) -> PageNumber? {
        if let m = vblock.first(text), let cur = Int(m[1]), let tot = Int(m[2]), 1 <= cur, cur <= tot, tot <= 999 {
            return PageNumber(current: cur, total: tot)
        }
        var best: PageNumber?
        for zone in [tail(text, 700), head(text, 3000)] {
            for m in pgSlash.findAll(zone) {
                guard let cur = Int(m[1]), let tot = Int(m[2]) else { continue }
                if skip.contains(Pair(a: cur, b: tot)) { continue }
                if 1 <= cur, cur <= tot, tot <= 99 { best = PageNumber(current: cur, total: tot) }
            }
            if let best { return best }
        }
        if let m = pgWord.first(head(text, 1200)), let cur = Int(m[1]) {
            return PageNumber(current: cur, total: nil)
        }
        return nil
    }

    /// Handschriftliche Notiz, Zettel, Deckblatt mit wenigen Worten: unter 150 Zeichen Text
    /// (ohne Leerraum) und kein Briefschluss (Grußformel, Unterschrift) – der gehört zum Brief davor.
    static let closing = Rx(#"Gr[üu](?:ß|ss)|Hochachtungsvoll|\bi\.\s?[AV]\.|Unterschrift"#, [.caseInsensitive])

    static func isShortNote(_ text: String) -> Bool {
        let characters = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        return (10..<150).contains(characters) && !closing.matches(text)
    }

    static func isHead(_ text: String) -> Bool {
        let h = head(text, 1400)
        return salut.matches(h) && addr.matches(h)
    }

    static func findStarts(_ pages: [String], margins: [String],
                           options: Options = .original) -> ([Start], [PageNumber?]) {
        let toks = tokenSets(margins)
        let blacklist = slashBlacklist(pages)
        var nums = pages.map { pageNumber($0, skip: blacklist) }
        let conts = pages.map { cont.matches($0) }

        // Rückwärts auffüllen: Folgeseite trägt eine 2, die aktuelle keinen Zähler, aber einen
        // Anschriftenblock → aktuelle Seite ist 1 (Deckblatt mit zerlesenem Randmarker).
        for i in 0..<max(0, pages.count - 1) {
            if nums[i] == nil, let next = nums[i + 1], next.current == 2, addr.matches(head(pages[i], 1400)) {
                nums[i] = PageNumber(current: 1, total: next.total)
            }
        }

        var starts = [Start(page: 0, reason: .firstPage)]
        // Letzte Seite, die überhaupt eine Kennung trug (Beiblätter tragen keine).
        var lastTok: Set<String>? = toks[0].isEmpty ? nil : toks[0]
        for i in 1..<max(1, pages.count) {
            let n = nums[i], pn = nums[i - 1]
            var reason: Reason?

            if let n, n.current == 1, !conts[i - 1] {
                reason = .counterReset
            } else if let pn, let total = pn.total, total != 0, pn.current == total {
                reason = .previousWasLast(pn.current, total)
            } else if !toks[i].isEmpty, let lastTok, !related(toks[i], lastTok) {
                reason = .identifierChanged
            } else if isHead(pages[i]), !conts[i - 1] {
                reason = .letterHead
            } else if options.shortNotes, n == nil, !conts[i - 1], isShortNote(pages[i]) {
                reason = .shortNote
            } else if options.shortNotes, pn == nil, isShortNote(pages[i - 1]) {
                reason = .afterShortNote
            }

            if !toks[i].isEmpty { lastTok = toks[i] }
            if let reason { starts.append(Start(page: i, reason: reason)) }
        }
        return (starts, nums)
    }

    /// Fremde Blätter aus dem Bauch eines Dokuments lösen: Läufe zählerloser Seiten, die eine sonst
    /// fortlaufende Zählerfolge unterbrechen (… 4, –, –, 5 …). Nur herauslösen, nie umsortieren.
    static func splitInserts(_ block: [Int], _ nums: [PageNumber?]) -> [[Int]] {
        var main: [Int] = [], inserts: [[Int]] = []
        var i = 0
        while i < block.count {
            if nums[block[i]] != nil {
                main.append(block[i])
                i += 1
                continue
            }
            var j = i
            while j < block.count, nums[block[j]] == nil { j += 1 }
            let prev = main.reversed().lazy.compactMap { nums[$0] }.first
            let next = j < block.count ? nums[block[j]] : nil
            if let prev, let next, prev.current + 1 == next.current {
                inserts.append(Array(block[i..<j]))   // Einschub: eigenes Dokument
            } else {
                main += block[i..<j]                   // Vor-/Nachspann: gehört dazu
            }
            i = j
        }
        return [main] + inserts
    }

    // MARK: - Hilfen

    struct Pair: Hashable {
        var a: Int
        var b: Int
    }

    /// Python-Slicing `t[:n]` (Unicode-Codepoints).
    static func head(_ t: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(t.unicodeScalars.prefix(n)))
    }

    /// Python-Slicing `t[-n:]`.
    static func tail(_ t: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(t.unicodeScalars.suffix(n)))
    }

    /// Stringvergleich wie in Python (nach Codepoints).
    static func pyLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    /// `difflib.SequenceMatcher(None, a, b).ratio()` – Ratcliff/Obershelp wie in Python
    /// (Autojunk greift erst ab 200 Zeichen und ist für Kennungen irrelevant).
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var b2j: [Unicode.Scalar: [Int]] = [:]
        for (j, c) in b.enumerated() { b2j[c, default: []].append(j) }

        func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var besti = alo, bestj = blo, bestsize = 0
            var j2len: [Int: Int] = [:]
            for i in alo..<ahi {
                var newj2len: [Int: Int] = [:]
                for j in b2j[a[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    newj2len[j] = k
                    if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
                j2len = newj2len
            }
            return (besti, bestj, bestsize)
        }

        var matches = 0
        var queue = [(0, a.count, 0, b.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            guard alo < ahi, blo < bhi else { continue }
            let (i, j, k) = longestMatch(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            matches += k
            queue.append((alo, i, blo, j))
            queue.append((i + k, ahi, j + k, bhi))
        }
        return 2 * Double(matches) / Double(a.count + b.count)
    }
}

/// Dünne Hülle um NSRegularExpression mit Python-artigen Ergebnissen (Gruppen als Strings).
struct Rx {
    let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Alle Treffer; Index 0 ist der Gesamttreffer, danach die Gruppen ("" wenn nicht beteiligt).
    func findAll(_ s: String) -> [[String]] {
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    func first(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    func matches(_ s: String) -> Bool {
        first(s) != nil
    }
}
