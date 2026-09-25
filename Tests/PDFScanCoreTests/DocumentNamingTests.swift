import XCTest
@testable import PDFScanCore

final class DocumentNamingTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private var date: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 5))!
    }

    func testFileNamePattern() {
        let naming = DocumentNaming(prefix: "Scan_")
        XCTAssertEqual(naming.fileName(date: date, batch: 3, document: 1, calendar: calendar),
                       "Scan_2026_09_05_003_01.pdf")
        XCTAssertEqual(naming.fileName(date: date, batch: 1234, document: 100, calendar: calendar),
                       "Scan_2026_09_05_1234_100.pdf")
        XCTAssertEqual(DocumentNaming(prefix: "").fileName(date: date, batch: 1, document: 2, calendar: calendar),
                       "2026_09_05_001_02.pdf")
    }

    func testPrefixIsSanitized() {
        XCTAssertEqual(DocumentNaming.sanitizedPrefix(" Akte/Steuer: "), "Akte-Steuer-")
    }

    func testBatchContinuesFromExistingFiles() {
        let naming = DocumentNaming(prefix: "Scan_")
        XCTAssertEqual(naming.nextBatch(existingFileNames: [], date: date, calendar: calendar), 1)
        let existing = [
            "Scan_2026_09_05_001_01.pdf",
            "Scan_2026_09_05_001_02.pdf",
            "Scan_2026_09_05_002_01.pdf",
            "Scan_2026_09_04_007_01.pdf",   // anderer Tag
            "Brief_2026_09_05_009_01.pdf",  // anderes Präfix
            "notizen.txt",
        ]
        XCTAssertEqual(naming.nextBatch(existingFileNames: existing, date: date, calendar: calendar), 3)
    }

    func testGroupingAtMarkers() {
        // Seiten:        0     1      2     3      4
        let starts =   [true, false, true, false, true]
        let excluded = [false, false, false, false, false]
        XCTAssertEqual(DocumentSplitter.group(startsDocument: starts, excluded: excluded), [[0, 1], [2, 3], [4]])
    }

    func testMarkerOnExcludedPageMovesToNextPage() {
        // Seite 2 ist eine weggelassene Leerseite mit Trennmarke → Dokument 2 beginnt mit Seite 3.
        let starts =   [false, false, true, false]
        let excluded = [false, false, true, false]
        XCTAssertEqual(DocumentSplitter.group(startsDocument: starts, excluded: excluded), [[0, 1], [3]])
    }

    func testExcludedPagesAndEmptyDocumentsDisappear() {
        let starts =   [false, true, true, false]
        let excluded = [true, true, false, true]
        XCTAssertEqual(DocumentSplitter.group(startsDocument: starts, excluded: excluded), [[2]])
        XCTAssertEqual(DocumentSplitter.group(startsDocument: [], excluded: []), [])
    }
}
