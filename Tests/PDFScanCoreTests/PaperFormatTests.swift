import XCTest
@testable import PDFScanCore

final class PaperFormatTests: XCTestCase {
    // Typisches Angebot eines Einzugs-Treibers (Nummern bewusst willkürlich).
    private let offered = [
        PaperFormat.Candidate(id: 7, widthMM: 148, heightMM: 210),     // A5 – war der Treiberstandard
        PaperFormat.Candidate(id: 3, widthMM: 210, heightMM: 297),     // A4
        PaperFormat.Candidate(id: 12, widthMM: 215.9, heightMM: 279.4), // Letter
        PaperFormat.Candidate(id: 9, widthMM: 215.9, heightMM: 355.6),  // Legal
        PaperFormat.Candidate(id: 0, widthMM: 0, heightMM: 0),          // „Default“ ohne Größe
    ]

    func testPicksFormatBySizeNotByNumber() {
        XCTAssertEqual(PaperFormat.a4.bestMatch(in: offered)?.id, 3)
        XCTAssertEqual(PaperFormat.a5.bestMatch(in: offered)?.id, 7)
        XCTAssertEqual(PaperFormat.letter.bestMatch(in: offered)?.id, 12)
        XCTAssertEqual(PaperFormat.legal.bestMatch(in: offered)?.id, 9)
        XCTAssertEqual(PaperFormat.largest.bestMatch(in: offered)?.id, 9)
        XCTAssertNil(PaperFormat.driverDefault.bestMatch(in: offered))
        XCTAssertEqual(PaperFormat.auto.bestMatch(in: offered)?.id, 9)
    }

    func testLandscapeEntriesMatch() {
        let landscape = [PaperFormat.Candidate(id: 4, widthMM: 297, heightMM: 210)]
        XCTAssertEqual(PaperFormat.a4.bestMatch(in: landscape)?.id, 4)
    }

    func testFallsBackToNextLargerFormatSoNothingIsCut() {
        // Kein A4 im Angebot: Legal ist das kleinste Format, in das A4 ganz passt.
        let noA4 = offered.filter { $0.id != 3 }
        XCTAssertEqual(PaperFormat.a4.bestMatch(in: noA4)?.id, 9)
        // Nichts groß genug: dann wenigstens das größte.
        XCTAssertEqual(PaperFormat.legal.bestMatch(in: [offered[0], offered[1]])?.id, 3)
    }

    func testUnitConversion() {
        XCTAssertEqual(PaperFormat.millimeters(8.27, unitRawValue: 0, resolution: 300), 210.058, accuracy: 0.01)
        XCTAssertEqual(PaperFormat.millimeters(21, unitRawValue: 1, resolution: 300), 210, accuracy: 0.001)
        XCTAssertEqual(PaperFormat.millimeters(595.28, unitRawValue: 3, resolution: 300), 210, accuracy: 0.01)
        XCTAssertEqual(PaperFormat.millimeters(2480, unitRawValue: 5, resolution: 300), 209.97, accuracy: 0.01)
    }

    func testFindsEpsonAutoSizeFeature() {
        XCTAssertTrue(AutoSizeFeature.matches(name: "Automatische Größenerkennung"))
        XCTAssertTrue(AutoSizeFeature.matches(name: "Auto Size Detection"))
        XCTAssertTrue(AutoSizeFeature.matches(name: "Automatische Gro\u{0308}ßenerkennung"))
        XCTAssertFalse(AutoSizeFeature.matches(name: "Automatische Drehung"))
        XCTAssertFalse(AutoSizeFeature.matches(name: "Leere Seiten überspringen"))

        let labels = ["Aus", "Standardpapier", "Langes Papier"]
        XCTAssertEqual(AutoSizeFeature.optionIndex(labels: labels, enabled: true), 1)
        XCTAssertEqual(AutoSizeFeature.optionIndex(labels: labels, enabled: false), 0)
        XCTAssertEqual(AutoSizeFeature.optionIndex(labels: ["Off", "On"], enabled: true), 1)
    }
}
