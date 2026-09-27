import XCTest
@testable import PDFScanCore

final class ProfileStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let keys = ["outputFolder", "filePrefix", "resolution", "duplex", "jpeg"]

    override func setUp() {
        let suite = "pdfscan.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        defaults.register(defaults: ["outputFolder": "/Scans", "filePrefix": "Scan_", "resolution": 300, "duplex": true])
    }

    func testFirstProfileTakesExistingSettings() {
        defaults.set("/Users/me/Privat", forKey: "outputFolder")
        let store = ProfileStore(defaults: defaults, keys: keys)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.active.name, "Standard")
        XCTAssertEqual(store.active.string("outputFolder"), "/Users/me/Privat")
    }

    func testSwitchingSavesAndRestoresSettings() {
        let store = ProfileStore(defaults: defaults, keys: keys)
        let privat = store.active.id
        defaults.set("/Privat", forKey: "outputFolder")
        defaults.set(true, forKey: "duplex")
        defaults.set(0.7, forKey: "jpeg")

        let firma = store.create(name: "Firma")
        XCTAssertEqual(defaults.string(forKey: "outputFolder"), "/Privat", "neues Profil übernimmt die Einstellungen")
        defaults.set("/Firma", forKey: "outputFolder")
        defaults.set(false, forKey: "duplex")
        defaults.set(600, forKey: "resolution")

        store.activate(privat)
        XCTAssertEqual(defaults.string(forKey: "outputFolder"), "/Privat")
        XCTAssertTrue(defaults.bool(forKey: "duplex"))
        XCTAssertEqual(defaults.integer(forKey: "resolution"), 300)
        XCTAssertEqual(defaults.double(forKey: "jpeg"), 0.7)

        store.activate(firma.id)
        XCTAssertEqual(defaults.string(forKey: "outputFolder"), "/Firma")
        XCTAssertFalse(defaults.bool(forKey: "duplex"))
        XCTAssertEqual(defaults.integer(forKey: "resolution"), 600)
    }

    func testProfilesSurviveRestart() {
        let store = ProfileStore(defaults: defaults, keys: keys)
        defaults.set("/Privat", forKey: "outputFolder")
        store.create(name: "Firma")
        defaults.set("/Firma", forKey: "outputFolder")
        store.captureActive()

        let reopened = ProfileStore(defaults: defaults, keys: keys)
        XCTAssertEqual(reopened.profiles.map(\.name), ["Standard", "Firma"])
        XCTAssertEqual(reopened.active.name, "Firma")
        XCTAssertEqual(reopened.profiles[0].string("outputFolder"), "/Privat")
        XCTAssertEqual(defaults.string(forKey: "outputFolder"), "/Firma")
    }

    func testRenameDeleteAndUniqueNames() {
        let store = ProfileStore(defaults: defaults, keys: keys)
        let first = store.active.id
        let second = store.create(name: "Standard")
        XCTAssertEqual(second.name, "Standard 2")
        store.rename(second.id, to: "  Archiv  ")
        XCTAssertEqual(store.active.name, "Archiv")

        store.delete(second.id)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.activeID, first)
        store.delete(first)
        XCTAssertEqual(store.profiles.count, 1, "das letzte Profil bleibt")
    }
}
