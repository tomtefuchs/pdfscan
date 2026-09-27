import Combine
import Foundation

/// Ein gespeicherter Einstellungswert (die App nutzt nur diese vier Typen).
public enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init?(_ object: Any?) {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number as CFNumber) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        default:
            return nil
        }
    }

    var object: Any {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        }
    }
}

/// Ein benanntes Einstellungsprofil, z. B. „Privat“ mit Zielordner ~/Dokumente/Privat.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var values: [String: SettingValue]

    public init(id: UUID = UUID(), name: String, values: [String: SettingValue]) {
        self.id = id
        self.name = name
        self.values = values
    }

    public func string(_ key: String) -> String? {
        if case .string(let value)? = values[key] { return value }
        return nil
    }
}

/// Verwaltet Profile. Die Einstellungen selbst bleiben unter ihren gewohnten Schlüsseln in den
/// UserDefaults (dort bearbeitet sie die Oberfläche); sie sind die Arbeitskopie des aktiven Profils.
/// Beim Wechsel wird die Arbeitskopie ins alte Profil gesichert und das neue geladen.
public final class ProfileStore: ObservableObject {
    @Published public private(set) var profiles: [Profile] = []
    @Published public private(set) var activeID: UUID

    private let defaults: UserDefaults
    private let keys: [String]
    /// Während ein Profil geladen wird, nicht zwischendurch halbe Stände sichern.
    private var isLoading = false
    private static let listKey = "profiles.list"
    private static let activeKey = "profiles.active"

    public init(defaults: UserDefaults = .standard, keys: [String], defaultName: String = "Standard") {
        self.defaults = defaults
        self.keys = keys
        var loaded = [Profile(name: defaultName, values: [:])]
        if let data = defaults.data(forKey: Self.listKey),
           let stored = try? JSONDecoder().decode([Profile].self, from: data), !stored.isEmpty {
            loaded = stored
        }
        let storedActive = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        activeID = loaded.first { $0.id == storedActive }?.id ?? loaded[0].id
        profiles = loaded
        if profiles.count == 1, profiles[0].values.isEmpty {
            captureActive()          // erstes Profil aus den bisherigen Einstellungen
        } else {
            load(active)
        }
        persist()
    }

    public var active: Profile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    /// Aktuelle Einstellungen ins aktive Profil übernehmen (nach jeder Änderung aufrufen).
    public func captureActive() {
        guard !isLoading, let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        var values: [String: SettingValue] = [:]
        for key in keys {
            if let value = SettingValue(defaults.object(forKey: key)) { values[key] = value }
        }
        guard profiles[index].values != values else { return }
        profiles[index].values = values
        persist()
    }

    public func activate(_ id: UUID) {
        guard id != activeID, let target = profiles.first(where: { $0.id == id }) else { return }
        captureActive()
        activeID = id
        load(target)
        persist()
    }

    /// Neues Profil mit den aktuellen Einstellungen anlegen und aktivieren.
    @discardableResult
    public func create(name: String) -> Profile {
        captureActive()
        let profile = Profile(name: uniqueName(name), values: active.values)
        profiles.append(profile)
        activeID = profile.id
        persist()
        return profile
    }

    public func rename(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profiles[index].name else { return }
        profiles[index].name = uniqueName(trimmed)
        persist()
    }

    /// Löschen; das letzte Profil bleibt immer bestehen.
    public func delete(_ id: UUID) {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if id == activeID {
            let next = profiles[index == 0 ? 1 : 0]
            activeID = next.id
            load(next)
        }
        profiles.remove(at: index)
        persist()
    }

    // MARK: - Intern

    private func load(_ profile: Profile) {
        isLoading = true
        defer { isLoading = false }
        for key in keys {
            if let value = profile.values[key] {
                defaults.set(value.object, forKey: key)
            } else {
                defaults.removeObject(forKey: key)   // fällt auf den registrierten Standardwert zurück
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.listKey)
        }
        defaults.set(activeID.uuidString, forKey: Self.activeKey)
    }

    private func uniqueName(_ name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Profil" : name
        var candidate = base
        var counter = 2
        while profiles.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }
}
