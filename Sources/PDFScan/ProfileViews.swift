import AppKit
import PDFScanCore
import SwiftUI

/// Profil-Auswahl in der Werkzeugleiste (links neben dem Scanner).
struct ProfileMenu: View {
    @EnvironmentObject private var profiles: ProfileStore

    var body: some View {
        Menu {
            ForEach(profiles.profiles) { profile in
                Button {
                    profiles.activate(profile.id)
                } label: {
                    if profile.id == profiles.activeID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("Neues Profil…") { ProfileDialogs.create(in: profiles) }
            Button("Profil umbenennen…") { ProfileDialogs.rename(profiles.active, in: profiles) }
            Button("Profil löschen…") { ProfileDialogs.delete(profiles.active, in: profiles) }
                .disabled(profiles.profiles.count < 2)
        } label: {
            IconLabel(profiles.active.name, systemImage: "person.crop.rectangle.stack.fill")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Profil: Zielordner und Einstellungen – ⌘, bearbeitet das aktive Profil")
    }
}

/// Auswahl beim Start, wenn mehrere Profile existieren.
struct ProfileChooser: View {
    @EnvironmentObject private var profiles: ProfileStore
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Mit welchem Profil möchtest du arbeiten?", systemImage: "person.crop.rectangle.stack.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 8) {
                ForEach(profiles.profiles) { profile in
                    Button {
                        profiles.activate(profile.id)
                        done()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: profile.id == profiles.activeID ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: Theme.iconSize))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(ProfileDialogs.folderDescription(profile))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(profile.id == profiles.activeID ? Theme.accent : Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Weiter mit „\(profiles.active.name)“", action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ActionButtonStyle(prominent: true))
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.window)
        .preferredColorScheme(.dark)
    }
}

/// Kleine Dialoge zum Anlegen, Umbenennen und Löschen.
enum ProfileDialogs {
    static func folderDescription(_ profile: Profile) -> String {
        let folder = profile.string(SettingsKey.outputFolder) ?? AppSettings.defaultOutputFolder
        return "Zielordner: " + (folder as NSString).abbreviatingWithTildeInPath
    }

    static func create(in profiles: ProfileStore) {
        guard let name = askForName(title: "Neues Profil",
                                    message: "Das neue Profil übernimmt die aktuellen Einstellungen. "
                                        + "Danach kannst du den Zielordner wählen.",
                                    initial: "") else { return }
        profiles.create(name: name)
        chooseFolder()
    }

    static func rename(_ profile: Profile, in profiles: ProfileStore) {
        guard let name = askForName(title: "Profil umbenennen", message: "", initial: profile.name) else { return }
        profiles.rename(profile.id, to: name)
    }

    static func delete(_ profile: Profile, in profiles: ProfileStore) {
        let alert = NSAlert()
        alert.messageText = "Profil „\(profile.name)“ löschen?"
        alert.informativeText = "Die Einstellungen dieses Profils gehen verloren. Gespeicherte PDFs bleiben erhalten."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        if alert.runModal() == .alertFirstButtonReturn {
            profiles.delete(profile.id)
        }
    }

    /// Zielordner für das aktive Profil wählen (schreibt in die Einstellungen, das Profil übernimmt ihn).
    static func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Zielordner für das Profil"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Als Zielordner verwenden"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: SettingsKey.outputFolder)
        }
    }

    private static func askForName(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "z. B. Privat, Firma, Eltern"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
