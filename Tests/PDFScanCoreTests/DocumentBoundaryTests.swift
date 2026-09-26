import XCTest
@testable import PDFScanCore

final class DocumentBoundaryTests: XCTestCase {
    private struct ParityCase: Decodable {
        var bodies: [String]
        var margins: [String]
        var starts: [Int]
        var documents: [[Int]]
    }

    /// Ergebnisse müssen exakt denen von reference/split_docs.py entsprechen.
    func testMatchesPythonReference() throws {
        let cases = try JSONDecoder().decode([ParityCase].self, from: Data(SplitParityCases.json.utf8))
        XCTAssertEqual(cases.count, 80)
        for (index, c) in cases.enumerated() {
            let pages = zip(c.bodies, c.margins).map { PageText(body: $0, margin: $1) }
            let result = DocumentBoundaryDetector.split(pages, options: .original)
            XCTAssertEqual(result.starts.map(\.page), c.starts, "Fall \(index): Schnitte")
            XCTAssertEqual(result.documents, c.documents, "Fall \(index): Dokumente")
        }
    }

    func testSimilarityMatchesDifflib() {
        XCTAssertEqual(DocumentBoundaryDetector.similarity("93569C0D", "93569C01J"), 0.8235294117647058, accuracy: 1e-12)
        XCTAssertEqual(DocumentBoundaryDetector.similarity("AB12CD34EF", "AB12CD34FE"), 0.9, accuracy: 1e-12)
        XCTAssertEqual(DocumentBoundaryDetector.similarity("X1Y2Z3W4", "Q9R8T7U6"), 0, accuracy: 1e-12)
        XCTAssertEqual(DocumentBoundaryDetector.similarity("ABCDEFGH", "HGFEDCBA"), 0.125, accuracy: 1e-12)
    }

    func testNormFoldsOCRConfusionsAndDirection() {
        XCTAssertEqual(DocumentBoundaryDetector.norm("AB12OISL"), "151021BA")
        XCTAssertEqual(DocumentBoundaryDetector.norm("vvx"), DocumentBoundaryDetector.norm("XW"))
    }

    func testCascadeReasons() {
        let pages = [
            PageText(body: "Rechnung\nSeite 1/2", margin: ""),
            PageText(body: "Posten\nSeite 2/2", margin: ""),
            PageText(body: "Beiblatt ohne Zähler", margin: ""),
            PageText(body: "Max Muster\n10115 Berlin\nSehr geehrte Frau Muster,\nText", margin: ""),
            PageText(body: "Text\nFortsetzung auf Seite 02", margin: ""),
            PageText(body: "Max Muster\n10115 Berlin\nSehr geehrte Frau Muster,\nweiter", margin: ""),
        ]
        let result = DocumentBoundaryDetector.split(pages)
        XCTAssertEqual(result.starts.map(\.page), [0, 2, 3])
        // Seite 4: Rückwärts-Auffüllung, weil „Fortsetzung auf Seite 02“ auf Seite 5 als Zähler 2 gilt.
        XCTAssertEqual(result.starts.map(\.reason), [.firstPage, .previousWasLast(2, 2), .counterReset])
        XCTAssertEqual(result.documents, [[0, 1], [2], [3, 4, 5]])
    }

    func testLetterHeadStartsDocument() {
        let pages = [
            PageText(body: "Text a", margin: ""),
            PageText(body: "Text b", margin: ""),
            PageText(body: "Max Muster\n80331 München\nSehr geehrte Damen und Herren,\nText", margin: ""),
        ]
        let result = DocumentBoundaryDetector.split(pages)
        XCTAssertEqual(result.starts.map(\.reason), [.firstPage, .letterHead])
        XCTAssertEqual(result.documents, [[0, 1], [2]])
    }

    /// Serienbriefe ohne Seitenzähler, Anrede „Sehr geehrtes Mitglied“ (z. B. Genossenschaft).
    func testMemberLettersWithoutCountersAreSplit() {
        func letter(_ year: Int) -> PageText {
            PageText(body: "Beispiel eG, Postfach 1234, 24103 Kiel\nMax Mustermann\nHauptstr. 1\n24103 Kiel\n"
                     + "Kiel, im März \(year)\nSehr geehrtes Mitglied,\nwir freuen uns, Ihnen mitzuteilen …\n"
                     + String(repeating: "Text des Schreibens. ", count: 10),
                     margin: "")
        }
        let statement = PageText(body: "Dividendenabrechnung\nGeschäftsguthaben am Berechnungsstichtag\n"
                                 + String(repeating: "Position Betrag EUR 12,34\n", count: 8), margin: "")
        let pages = [letter(2001), statement, letter(2000), statement, letter(1999)]
        let result = DocumentBoundaryDetector.split(pages)
        XCTAssertEqual(result.documents, [[0, 1], [2, 3], [4]])
        XCTAssertEqual(result.reasons, [.firstPage, .letterHead, .letterHead])

        // „Guten Tag Frau …“ zählt ebenso, eine bloße Erwähnung „sehr geehrt“ ohne Anschrift nicht.
        XCTAssertTrue(DocumentBoundaryDetector.isHead("10115 Berlin\nGuten Tag Frau Muster,"))
        XCTAssertFalse(DocumentBoundaryDetector.isHead("Sehr geehrtes Mitglied, ohne Anschrift"))
    }

    /// Handschriftliche Notiz zwischen zwei Briefen wird ein eigenes Dokument, eine Unterschriftsseite nicht.
    func testShortNoteIsOwnDocument() {
        let letter = PageText(body: "Beispiel eG, Postfach 1234, 24103 Kiel\nMax Mustermann\n24103 Kiel\n"
                              + "Sehr geehrtes Mitglied,\n" + String(repeating: "Text des Schreibens. ", count: 20),
                              margin: "")
        let attachment = PageText(body: String(repeating: "Erläuterungen zur Abrechnung. ", count: 20), margin: "")
        let note = PageText(body: "Übergabe\nder\nAnteile\nan Max\nWeihnachten 2004", margin: "")
        let signature = PageText(body: "Mit freundlichen Grüßen\nBeispiel eG\nVorstand", margin: "")

        let pages = [letter, attachment, note, letter, signature]
        let result = DocumentBoundaryDetector.split(pages)
        XCTAssertEqual(result.documents, [[0, 1], [2], [3, 4]])
        XCTAssertEqual(result.reasons, [.firstPage, .shortNote, .letterHead])

        // Nach der Notiz beginnt auch ohne Briefkopf ein neues Dokument.
        let noteThenText = DocumentBoundaryDetector.split([attachment, note, attachment])
        XCTAssertEqual(noteThenText.documents, [[0], [1], [2]])

        // Das Original kennt die Regel nicht.
        XCTAssertEqual(DocumentBoundaryDetector.split(pages, options: .original).documents, [[0, 1, 2], [3, 4]])
    }

    func testInsertIsSplitOutWithoutReordering() {
        let pages = ["1/3", "2/3", "fremd", "3/3"].map { PageText(body: "Text\n\($0)", margin: "") }
        let result = DocumentBoundaryDetector.split(pages)
        XCTAssertEqual(result.documents, [[0, 1, 3], [2]])
        XCTAssertEqual(result.reasons, [.firstPage, .insert])
    }

    func testPageTextBuilderSeparatesMarginAndOrdersRows() {
        // A4 hochkant: 595 × 842 pt
        let size = CGSize(width: 595, height: 842)
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: x / 595, y: y / 842, width: w / 595, height: h / 842)
        }
        let lines = [
            RecognizedLine(text: "Seite 1/2", box: box(250, 40, 80, 10), confidence: 1),
            RecognizedLine(text: "Betreff", box: box(70, 700, 60, 12), confidence: 1),
            RecognizedLine(text: "Datum", box: box(400, 701, 50, 12), confidence: 1),
            RecognizedLine(text: "AB12CD34EF", box: box(5, 400, 20, 100), confidence: 1),
            RecognizedLine(text: "FUSSZEILE", box: box(200, 5, 100, 10), confidence: 1),
        ]
        let text = PageTextBuilder.make(lines: lines, pageSize: size, verticalMarginLines: ["0001", "0002"])
        XCTAssertEqual(text.body, "Betreff Datum\nAB12CD34EF\nSeite 1/2\nFUSSZEILE\n0001\n0002")
        XCTAssertEqual(text.margin, "AB12CD34EF FUSSZEILE 0001 0002")
        XCTAssertEqual(DocumentBoundaryDetector.pageNumber(text.body), .init(current: 1, total: 2))
    }
}
