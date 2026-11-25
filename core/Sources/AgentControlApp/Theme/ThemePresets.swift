import AppKit

/// The built-in themes, after shadcn/ui: a base gray (Neutral, Zinc, Stone, Slate) combined with an accent
/// (Mono, Blue, Violet, Green, Orange, Rose, Amber). Values are Tailwind CSS's palette, which shadcn uses.
/// Plus "System": the native look.
enum ThemePresets {
    struct Base {
        let id: String
        let name: String
        /// Tailwind shades 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950.
        let scale: [UInt32]

        func shade(_ step: Int) -> RGBA {
            let steps = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]
            return RGBA(scale[steps.firstIndex(of: step)!])
        }
    }

    struct Accent {
        let id: String
        let name: String
        /// nil = the base's own near-black / near-white, like shadcn's default theme.
        let light: UInt32?
        let dark: UInt32?
        /// Text on the accent; nil = white in light mode, the base's darkest shade in dark mode.
        let foregroundLight: UInt32?
        let foregroundDark: UInt32?
    }

    static let bases = [
        Base(id: "neutral", name: "Neutral", scale: [
            0xFAFAFA, 0xF5F5F5, 0xE5E5E5, 0xD4D4D4, 0xA3A3A3, 0x737373, 0x525252, 0x404040, 0x262626, 0x171717, 0x0A0A0A,
        ]),
        Base(id: "zinc", name: "Zinc", scale: [
            0xFAFAFA, 0xF4F4F5, 0xE4E4E7, 0xD4D4D8, 0xA1A1AA, 0x71717A, 0x52525B, 0x3F3F46, 0x27272A, 0x18181B, 0x09090B,
        ]),
        Base(id: "stone", name: "Stone", scale: [
            0xFAFAF9, 0xF5F5F4, 0xE7E5E4, 0xD6D3D1, 0xA8A29E, 0x78716C, 0x57534E, 0x44403C, 0x292524, 0x1C1917, 0x0C0A09,
        ]),
        Base(id: "slate", name: "Slate", scale: [
            0xF8FAFC, 0xF1F5F9, 0xE2E8F0, 0xCBD5E1, 0x94A3B8, 0x64748B, 0x475569, 0x334155, 0x1E293B, 0x0F172A, 0x020617,
        ]),
    ]

    /// Light mode uses the 600 shade (readable white text on it), dark mode the 500 one.
    static let accents = [
        Accent(id: "mono", name: "Mono", light: nil, dark: nil, foregroundLight: nil, foregroundDark: nil),
        Accent(id: "blue", name: "Blue", light: 0x2563EB, dark: 0x3B82F6, foregroundLight: nil, foregroundDark: 0xFFFFFF),
        Accent(id: "violet", name: "Violet", light: 0x7C3AED, dark: 0x8B5CF6, foregroundLight: nil, foregroundDark: 0xFFFFFF),
        Accent(id: "green", name: "Green", light: 0x16A34A, dark: 0x22C55E, foregroundLight: nil, foregroundDark: 0x052E16),
        Accent(id: "orange", name: "Orange", light: 0xEA580C, dark: 0xF97316, foregroundLight: nil, foregroundDark: 0x431407),
        Accent(id: "rose", name: "Rose", light: 0xE11D48, dark: 0xF43F5E, foregroundLight: nil, foregroundDark: 0xFFFFFF),
        Accent(id: "amber", name: "Amber", light: 0xD97706, dark: 0xF59E0B, foregroundLight: 0x451A03, foregroundDark: 0x451A03),
    ]

    static let systemId = "system"

    /// Inline code in every preset: a warm tone, as in Claude Code's VS Code panel.
    static let codeColor = ThemeColor(0x9A3412, 0xD7BA7D)

    static func id(base: Base, accent: Accent) -> String { "\(base.id)-\(accent.id)" }

    static func make(base: Base, accent: Accent) -> Theme {
        let white = RGBA(0xFFFFFF)
        let accentLight = accent.light.map(RGBA.init) ?? base.shade(900)
        let accentDark = accent.dark.map(RGBA.init) ?? base.shade(50)
        let background = ThemeColor(light: white, dark: base.shade(950))
        let colors: [ThemeToken: ThemeColor] = [
            .background: background,
            .sidebar: ThemeColor(light: base.shade(50), dark: base.shade(900)),
            .card: ThemeColor(light: base.shade(100), dark: base.shade(800)),
            .border: ThemeColor(light: base.shade(200), dark: base.shade(800)),
            .text: ThemeColor(light: base.shade(950), dark: base.shade(50)),
            .textSecondary: ThemeColor(light: base.shade(600), dark: base.shade(400)),
            .textFaint: ThemeColor(light: base.shade(500), dark: base.shade(500)),
            .code: codeColor,
            .accent: ThemeColor(light: accentLight, dark: accentDark),
            .accentForeground: ThemeColor(
                light: accent.foregroundLight.map(RGBA.init) ?? (accent.light == nil ? base.shade(50) : white),
                dark: accent.foregroundDark.map(RGBA.init) ?? base.shade(900)
            ),
            // The accent faded into the background.
            .bubble: ThemeColor(
                light: background.light.mixed(with: accentLight, accent.light == nil ? 0.07 : 0.11),
                dark: background.dark.mixed(with: accentDark, accent.dark == nil ? 0.12 : 0.22)
            ),
            .working: ThemeColor(0x2563EB, 0x60A5FA),
            .waiting: ThemeColor(0xC2410C, 0xFB923C),
            .done: ThemeColor(0x15803D, 0x4ADE80),
            .error: ThemeColor(0xDC2626, 0xF87171),
        ]
        return Theme(id: id(base: base, accent: accent), name: "\(base.name) · \(accent.name)", colors: colors, isPreset: true)
    }

    static let all: [Theme] = bases.flatMap { base in accents.map { make(base: base, accent: $0) } }

    /// Used for colors a file or a pasted CSS theme leaves out.
    static let fallback = make(base: bases[0], accent: accents[1])

    /// The native look, described as colors (resolved from the system's in light and dark mode), so it can
    /// be duplicated and edited like the others.
    @MainActor
    static var system: Theme {
        func resolve(_ color: NSColor) -> ThemeColor {
            func value(_ name: NSAppearance.Name) -> RGBA {
                var result = RGBA(0)
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                    result = RGBA(color) ?? RGBA(0)
                }
                return result
            }
            return ThemeColor(light: value(.aqua), dark: value(.darkAqua))
        }
        var colors: [ThemeToken: ThemeColor] = [
            .background: resolve(.windowBackgroundColor),
            .sidebar: resolve(.underPageBackgroundColor),
            .card: resolve(.quaternarySystemFill),
            .border: resolve(.separatorColor),
            .text: resolve(.labelColor),
            .textSecondary: resolve(.secondaryLabelColor),
            .textFaint: resolve(.tertiaryLabelColor),
            .code: codeColor,
            .accent: resolve(.controlAccentColor),
            .accentForeground: resolve(.alternateSelectedControlTextColor),
            .working: resolve(Palette.nsBlue),
            .waiting: resolve(Palette.nsOrange),
            .done: resolve(Palette.nsGreen),
            .error: resolve(Palette.nsRed),
        ]
        // Translucent system colors are flattened over the background, so a copy looks the same.
        for token in [ThemeToken.card, .border, .textSecondary, .textFaint] {
            guard var color = colors[token] else { continue }
            let bg = colors[.background]!
            if color.light.a < 1 { color.light = bg.light.mixed(with: RGBA(r: color.light.r, g: color.light.g, b: color.light.b), color.light.a) }
            if color.dark.a < 1 { color.dark = bg.dark.mixed(with: RGBA(r: color.dark.r, g: color.dark.g, b: color.dark.b), color.dark.a) }
            colors[token] = color
        }
        let accent = colors[.accent]!
        colors[.bubble] = ThemeColor(
            light: colors[.background]!.light.mixed(with: accent.light, 0.13),
            dark: colors[.background]!.dark.mixed(with: accent.dark, 0.2)
        )
        return Theme(id: systemId, name: "System", colors: colors, isSystem: true, isPreset: true)
    }
}
