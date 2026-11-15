import AppKit
import SwiftUI

/// Colors of the session list.
///
/// Dark mode keeps the system colors. Light mode needs its own: the menu window is translucent, so the
/// wallpaper shows through, and the system's light-mode greys and tints (made for opaque white) wash out
/// on it. Light mode therefore gets a near-opaque backdrop, deeper status tints and darker text.
/// With "Increase contrast" the text goes darker still; with "Reduce transparency" the backdrop is opaque.
enum Palette {
    // MARK: Status tints

    static let blue = adaptive(light: rgb(0x0058C4), dark: .systemBlue)
    static let green = adaptive(light: rgb(0x1B7A32), dark: .systemGreen)
    static let orange = adaptive(light: rgb(0xB04F00), dark: .systemOrange)
    static let red = adaptive(light: rgb(0xC0271B), dark: .systemRed)

    // MARK: Text levels (light: black at a fixed alpha, darker with Increase contrast)

    /// Secondary body text: Claude's reply, your prompt.
    static let textBody = text(light: 0.80, highContrast: 0.92, dark: .secondaryLabelColor)
    /// Small metadata: branch, idle status, counts.
    static let textMeta = text(light: 0.64, highContrast: 0.82, dark: .secondaryLabelColor)
    /// Least important: host label, pid.
    static let textFaint = text(light: 0.56, highContrast: 0.76, dark: .tertiaryLabelColor)

    // MARK: Port chips

    static let chipText = adaptive(light: rgb(0x0050B3), dark: .labelColor)
    static func chipFill(sameFolder: Bool) -> Color {
        sameFolder
            ? adaptive(light: rgb(0x0058C4, alpha: 0.08), dark: NSColor.systemBlue.withAlphaComponent(0.08))
            : adaptive(light: rgb(0x0058C4, alpha: 0.14), dark: NSColor.systemBlue.withAlphaComponent(0.18))
    }

    // MARK: Backdrop

    /// Laid under the menu window's content; clear in dark mode, where the glass reads well.
    static let backdrop = Color(nsColor: NSColor(name: nil) { appearance in
        guard !isDark(appearance) else { return .clear }
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        return NSColor.windowBackgroundColor.withAlphaComponent(opaque ? 1 : 0.86)
    })

    // MARK: Helpers

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
    }

    private static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        let names: [NSAppearance.Name] = [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]
        let match = appearance.bestMatch(from: names)
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { isDark($0) ? dark : light })
    }

    private static func text(light alpha: CGFloat, highContrast: CGFloat, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if isDark(appearance) { return dark }
            return NSColor.black.withAlphaComponent(isHighContrast(appearance) ? highContrast : alpha)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Fills the whole menu window with the backdrop, following its rounded corners.
struct MenuBackdrop: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Palette.backdrop.clipShape(ConcentricRectangle()).ignoresSafeArea()
        } else {
            Palette.backdrop.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).ignoresSafeArea()
        }
    }
}
