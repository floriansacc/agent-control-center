import AppKit

/// An sRGB color, stored as "#RRGGBB" (or "#RRGGBBAA" when not opaque).
struct RGBA: Hashable, Codable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
        self.a = min(max(a, 0), 1)
    }

    init(_ hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    /// "#abc", "#aabbcc", "#aabbccdd".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 3 || s.count == 4 { s = String(s.flatMap { [$0, $0] }) }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let rgb = s.count == 8 ? value >> 8 : value
        self.init(UInt32(rgb))
        if s.count == 8 { a = Double(value & 0xFF) / 255 }
    }

    init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return "#" + byte(r) + byte(g) + byte(b) + (a < 1 ? byte(a) : "")
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// Linear interpolation towards `other` (0 = self, 1 = other).
    func mixed(with other: RGBA, _ amount: Double) -> RGBA {
        RGBA(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount, a: a + (other.a - a) * amount)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast ratio (1–21) of this color drawn over `background`.
    func contrast(on background: RGBA) -> Double {
        let fg = a < 1 ? background.mixed(with: RGBA(r: r, g: g, b: b), a) : self
        let (l1, l2) = (fg.luminance, background.luminance)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let color = RGBA(hex: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a hex color: \(string)")
        }
        self = color
    }
}

/// One color of a theme, in light and dark mode.
struct ThemeColor: Hashable, Codable {
    var light: RGBA
    var dark: RGBA

    init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    init(_ light: UInt32, _ dark: UInt32) {
        self.init(light: RGBA(light), dark: RGBA(dark))
    }

    func value(dark isDark: Bool) -> RGBA { isDark ? dark : light }
}

/// The colors a theme sets. Named after shadcn's variables where they match (background, card, border,
/// primary → accent, muted-foreground → secondary text, destructive → error).
enum ThemeToken: String, CaseIterable, Codable, CodingKeyRepresentable, Identifiable {
    case background, sidebar, card, border
    case text, textSecondary, textFaint
    case accent, accentForeground, bubble
    case working, waiting, done, error

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case surfaces = "Surfaces"
        case text = "Text"
        case accent = "Accent"
        case status = "Status"
    }

    var group: Group {
        switch self {
        case .background, .sidebar, .card, .border: .surfaces
        case .text, .textSecondary, .textFaint: .text
        case .accent, .accentForeground, .bubble: .accent
        case .working, .waiting, .done, .error: .status
        }
    }

    var label: String {
        switch self {
        case .background: "Background"
        case .sidebar: "Sidebar"
        case .card: "Card"
        case .border: "Border"
        case .text: "Text"
        case .textSecondary: "Secondary text"
        case .textFaint: "Faint text"
        case .accent: "Accent"
        case .accentForeground: "Text on accent"
        case .bubble: "Your messages"
        case .working: "Working"
        case .waiting: "Needs input"
        case .done: "Done"
        case .error: "Error"
        }
    }

    var help: String {
        switch self {
        case .background: "The Control Center's main area."
        case .sidebar: "The session list and the details panel."
        case .card: "Code blocks, tool inputs, tags."
        case .border: "Separators and outlines."
        case .text: "Claude's replies, session names."
        case .textSecondary: "Summaries, labels, tool calls."
        case .textFaint: "Times, hosts, least important details."
        case .accent: "Selection, buttons, links, port chips."
        case .accentForeground: "Text and icons drawn on the accent color."
        case .bubble: "The background of your prompts."
        case .working: "Running sessions, everywhere (menu bar dropdown and windows)."
        case .waiting: "Sessions that need you, and the menu bar bell."
        case .done: "Finished sessions, low usage."
        case .error: "Errors, high usage, failed tool calls."
        }
    }

    /// Text drawn on these must stay readable: (text token, background token).
    static let contrastPairs: [(ThemeToken, ThemeToken)] = [
        (.text, .background), (.textSecondary, .background), (.text, .sidebar), (.textSecondary, .sidebar),
        (.text, .bubble), (.accentForeground, .accent), (.text, .card),
    ]
}

/// A theme: a name and one light / dark pair per token.
struct Theme: Hashable, Codable, Identifiable {
    var id: String
    var name: String
    var colors: [ThemeToken: ThemeColor]
    /// The System theme: native materials, the macOS accent color and text levels; `colors` only describes it.
    var isSystem = false
    /// Presets cannot be edited; duplicate them instead.
    var isPreset = false

    subscript(token: ThemeToken) -> ThemeColor {
        get { colors[token] ?? ThemePresets.fallback.colors[token]! }
        set { colors[token] = newValue }
    }

    /// Pairs below WCAG AA (4.5:1) in light or dark mode, e.g. "Secondary text on Sidebar (dark): 3.1:1".
    var contrastWarnings: [String] {
        var warnings: [String] = []
        for (fg, bg) in ThemeToken.contrastPairs {
            for dark in [false, true] {
                let ratio = self[fg].value(dark: dark).contrast(on: self[bg].value(dark: dark))
                if ratio < 4.5 {
                    warnings.append("\(fg.label) on \(bg.label) (\(dark ? "dark" : "light")): \(String(format: "%.1f", ratio)):1")
                }
            }
        }
        return warnings
    }

    // MARK: - File format

    /// What "Export Theme…" writes: a small, hand-editable JSON file.
    struct File: Codable {
        static let format = "agent-control-center-theme"

        var format = File.format
        var version = 1
        var name: String
        var colors: [String: ThemeColor]
    }

    var file: File {
        File(name: name, colors: Dictionary(uniqueKeysWithValues: ThemeToken.allCases.map { ($0.rawValue, self[$0]) }))
    }

    /// A custom theme from an exported file. Missing colors come from the default preset.
    init(file: File) {
        id = UUID().uuidString
        name = file.name
        colors = ThemePresets.fallback.colors
        for (key, color) in file.colors {
            if let token = ThemeToken(rawValue: key) { colors[token] = color }
        }
    }

    init(id: String, name: String, colors: [ThemeToken: ThemeColor], isSystem: Bool = false, isPreset: Bool = false) {
        self.id = id
        self.name = name
        self.colors = colors
        self.isSystem = isSystem
        self.isPreset = isPreset
    }

    /// An editable copy.
    func duplicate(named newName: String) -> Theme {
        Theme(id: UUID().uuidString, name: newName, colors: ThemeToken.allCases.reduce(into: [:]) { $0[$1] = self[$1] })
    }
}
