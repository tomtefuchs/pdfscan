import AppKit
import SwiftUI

/// Farben und Maße der App – dunkles Anthrazit mit kühlem Blau als Akzent.
/// Feste Farben statt durchscheinender Systemflächen, damit kein Schreibtisch-Farbton durchscheint.
enum Theme {
    // Flächen, von hinten nach vorn
    static let window = Color(hex: 0x1C1D20)
    static let sidebar = Color(hex: 0x232428)
    static let surface = Color(hex: 0x2B2D31)
    static let raised = Color(hex: 0x35373C)
    static let border = Color.white.opacity(0.07)

    // Text
    static let textPrimary = Color(hex: 0xECEDEF)
    static let textSecondary = Color(hex: 0x9A9DA3)

    // Akzente
    static let accent = Color(hex: 0x4D8EFF)
    static let success = Color(hex: 0x3FC77A)
    static let warning = Color(hex: 0xFFA940)
    static let danger = Color(hex: 0xFF5C5C)

    // Maße
    static let iconSize: CGFloat = 17
    static let smallIconSize: CGFloat = 14
    static let corner: CGFloat = 8
    static let thumbnail = CGSize(width: 72, height: 96)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Symbol + Text mit größerem Symbol, für Knöpfe in Werkzeugleiste und Seitenleiste.
struct IconLabel: View {
    let title: String
    let systemImage: String
    var size: CGFloat = Theme.iconSize

    init(_ title: String, systemImage: String, size: CGFloat = Theme.iconSize) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
        }
    }
}

/// Kleine Statuskapsel mit farbigem Punkt.
struct StatusPill: View {
    let text: String
    let color: Color
    var systemImage = "circle.fill"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .lineLimit(1)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

/// Große Aktionsknöpfe (Werkzeugleiste): eigener Stil, weil macOS Toolbar-Knöpfe sonst sehr klein zeichnet.
struct ActionButtonStyle: ButtonStyle {
    var prominent = false
    var color: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(prominent ? color : Theme.raised)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(prominent ? Color.clear : Theme.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
    }
}

/// Einstellungszeile mit Symbol, Text und Schalter – Symbole in fester Breite, damit alles fluchtet.
struct ToggleRow: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.smallIconSize, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(title)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
