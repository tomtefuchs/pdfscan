import Foundation
import PDFScanCore

enum SettingsKey {
    static let resolution = "resolution"
    static let grayscale = "grayscale"
    static let duplex = "duplex"
    static let autoRotate = "autoRotate"
    static let skipBlankPages = "skipBlankPages"
    static let jpegQuality = "jpegQuality"
    static let languages = "languages"
    static let outputFolder = "outputFolder"
    static let filePrefix = "filePrefix"
    static let autoSaveAfterScan = "autoSaveAfterScan"
}

/// Momentaufnahme der Einstellungen (gespeichert in UserDefaults, bearbeitet per @AppStorage).
struct AppSettings {
    var resolution: Int
    var grayscale: Bool
    var duplex: Bool
    var autoRotate: Bool
    var skipBlankPages: Bool
    var jpegQuality: Double
    var languages: [String]
    var outputFolder: URL
    var filePrefix: String
    var autoSaveAfterScan: Bool

    static let languagePresets: [(label: String, value: String)] = [
        ("Deutsch + Englisch", "de-DE,en-US"),
        ("Deutsch", "de-DE"),
        ("Englisch", "en-US"),
        ("Deutsch + Französisch", "de-DE,fr-FR"),
        ("Deutsch + Italienisch", "de-DE,it-IT"),
        ("Deutsch + Spanisch", "de-DE,es-ES"),
    ]

    static var defaultOutputFolder: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true).path
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.resolution: 300,
            SettingsKey.grayscale: false,
            SettingsKey.duplex: true,
            SettingsKey.autoRotate: true,
            SettingsKey.skipBlankPages: true,
            SettingsKey.jpegQuality: 0.7,
            SettingsKey.languages: "de-DE,en-US",
            SettingsKey.outputFolder: defaultOutputFolder,
            SettingsKey.filePrefix: "Scan_",
            SettingsKey.autoSaveAfterScan: false,
        ])
    }

    static var current: AppSettings {
        let d = UserDefaults.standard
        return AppSettings(
            resolution: d.integer(forKey: SettingsKey.resolution),
            grayscale: d.bool(forKey: SettingsKey.grayscale),
            duplex: d.bool(forKey: SettingsKey.duplex),
            autoRotate: d.bool(forKey: SettingsKey.autoRotate),
            skipBlankPages: d.bool(forKey: SettingsKey.skipBlankPages),
            jpegQuality: d.double(forKey: SettingsKey.jpegQuality),
            languages: (d.string(forKey: SettingsKey.languages) ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            outputFolder: URL(fileURLWithPath: d.string(forKey: SettingsKey.outputFolder) ?? defaultOutputFolder,
                              isDirectory: true),
            filePrefix: DocumentNaming.sanitizedPrefix(d.string(forKey: SettingsKey.filePrefix) ?? "Scan_"),
            autoSaveAfterScan: d.bool(forKey: SettingsKey.autoSaveAfterScan)
        )
    }
}
