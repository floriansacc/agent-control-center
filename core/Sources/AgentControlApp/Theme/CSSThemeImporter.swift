import Foundation

/// Turns a CSS theme into a `Theme`: shadcn/ui (v3 HSL and v4 OKLCH), tweakcn, Tailwind v4 `@theme`
/// blocks, or any stylesheet that defines its colors as custom properties.
///
/// Light values come from `:root` (or `@theme`, `.light`, `[data-theme="light"]`), dark values from any rule
/// whose selector or enclosing `@media` mentions "dark" (`.dark`, `[data-theme="dark"]`,
/// `@media (prefers-color-scheme: dark)`). Colors the CSS does not define come from the default preset.
enum CSSThemeImporter {
    struct Result {
        var theme: Theme
        /// Tokens set from the CSS (the others come from the default preset or are derived).
        var found: Set<ThemeToken>
        /// Whether the CSS had separate light and dark values.
        var hasLight: Bool
        var hasDark: Bool
    }

    enum ImportError: LocalizedError {
        case noColors

        var errorDescription: String? {
            "No color variables were found. Paste CSS with custom properties such as --background, --foreground and --primary."
        }
    }

    /// Variable names (without "--" and a "color-" prefix) tried for each token, in order.
    static let aliases: [ThemeToken: [String]] = [
        .background: ["background", "bg", "base", "surface-background"],
        .sidebar: ["sidebar", "sidebar-background", "panel", "surface-1"],
        .card: ["card", "muted", "surface", "surface-2"],
        .border: ["border", "divider", "outline"],
        .text: ["foreground", "text", "fg", "text-primary"],
        .textSecondary: ["muted-foreground", "text-secondary", "text-muted", "fg-muted", "subtle"],
        .textFaint: ["text-faint", "text-tertiary", "fg-subtle"],
        .accent: ["primary", "brand", "accent"],
        .accentForeground: ["primary-foreground", "on-primary", "brand-foreground", "accent-foreground"],
        .bubble: ["bubble", "chat-user"],
        .working: ["info", "working", "blue"],
        .waiting: ["warning", "waiting", "orange", "amber"],
        .done: ["success", "done", "green"],
        .error: ["destructive", "error", "danger", "red"],
    ]

    static func parse(_ css: String, name: String) throws -> Result {
        let (light, dark) = variables(in: css)
        let lightColors = colors(from: light)
        // As in CSS, the dark rules override :root: what they leave out (often the status colors) is inherited.
        let darkColors = dark.isEmpty ? [:] : colors(from: light.merging(dark) { _, darkValue in darkValue })
        guard !lightColors.isEmpty || !darkColors.isEmpty else { throw ImportError.noColors }

        let fallback = ThemePresets.fallback
        var theme = fallback.duplicate(named: name)
        var found = Set<ThemeToken>()
        for token in ThemeToken.allCases {
            let l = lightColors[token]
            let d = darkColors[token]
            if l != nil || d != nil { found.insert(token) }
            // A theme with one mode only: the missing mode keeps the preset's value.
            theme[token] = ThemeColor(light: l ?? fallback[token].light, dark: d ?? fallback[token].dark)
        }
        // Derived when the CSS does not say: faint text between secondary text and the background,
        // your messages as the accent faded into the background.
        if !found.contains(.textFaint) {
            theme[.textFaint] = ThemeColor(
                light: theme[.textSecondary].light.mixed(with: theme[.background].light, 0.3),
                dark: theme[.textSecondary].dark.mixed(with: theme[.background].dark, 0.3)
            )
        }
        if !found.contains(.bubble) {
            theme[.bubble] = ThemeColor(
                light: theme[.background].light.mixed(with: theme[.accent].light, 0.12),
                dark: theme[.background].dark.mixed(with: theme[.accent].dark, 0.2)
            )
        }
        if !found.contains(.sidebar), found.contains(.background) {
            theme[.sidebar] = ThemeColor(
                light: theme[.background].light.mixed(with: theme[.text].light, 0.03),
                dark: theme[.background].dark.mixed(with: theme[.text].dark, 0.05)
            )
        }
        if !found.contains(.accentForeground), found.contains(.accent) {
            func onAccent(_ accent: RGBA) -> RGBA {
                let white = RGBA(0xFFFFFF)
                let black = RGBA(0x0A0A0A)
                return white.contrast(on: accent) >= black.contrast(on: accent) ? white : black
            }
            theme[.accentForeground] = ThemeColor(light: onAccent(theme[.accent].light), dark: onAccent(theme[.accent].dark))
        }
        return Result(theme: theme, found: found, hasLight: !lightColors.isEmpty, hasDark: !darkColors.isEmpty)
    }

    // MARK: - Variables

    /// Custom properties by mode, names without "--". Later declarations win, as in CSS.
    static func variables(in css: String) -> (light: [String: String], dark: [String: String]) {
        let text = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var light: [String: String] = [:]
        var dark: [String: String] = [:]
        // Rule headers ("@media (…)", ".dark", ":root") enclosing the current position.
        var stack: [String] = []
        var segment = ""

        func declare(_ declaration: String) {
            let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("--"), let colon = trimmed.firstIndex(of: ":") else { return }
            let name = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...]
                .replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { return }
            if stack.contains(where: { $0.lowercased().contains("dark") }) {
                dark[name] = value
            } else {
                light[name] = value
            }
        }

        for char in text {
            switch char {
            case "{":
                stack.append(segment.trimmingCharacters(in: .whitespacesAndNewlines))
                segment = ""
            case "}":
                declare(segment)
                segment = ""
                if !stack.isEmpty { stack.removeLast() }
            case ";":
                declare(segment)
                segment = ""
            default:
                segment.append(char)
            }
        }
        // Bare declarations pasted without a selector.
        declare(segment)
        return (light, dark)
    }

    /// The theme's tokens found among `variables`.
    static func colors(from variables: [String: String]) -> [ThemeToken: RGBA] {
        // Tailwind v4 prefixes theme colors with "color-": accept both.
        var names = variables
        for (key, value) in variables where key.hasPrefix("color-") {
            let short = String(key.dropFirst(6))
            if names[short] == nil { names[short] = value }
        }
        var result: [ThemeToken: RGBA] = [:]
        for token in ThemeToken.allCases {
            for alias in aliases[token] ?? [] {
                guard let raw = names[alias], let color = parseColor(resolve(raw, in: names)) else { continue }
                result[token] = color
                break
            }
        }
        // shadcn's --accent is a subtle hover background, not a brand color: only use it without --primary.
        if names["primary"] == nil, names["brand"] == nil, let accent = result[.accent], accent.contrast(on: result[.background] ?? RGBA(0xFFFFFF)) < 1.5 {
            result[.accent] = nil
        }
        return result
    }

    /// Follows `var(--name)` / `var(--name, fallback)` references.
    static func resolve(_ value: String, in variables: [String: String], depth: Int = 0) -> String {
        guard depth < 8, let match = value.firstMatch(of: #/var\(\s*--([\w-]+)\s*(?:,\s*([^)]*))?\)/#) else { return value }
        let name = String(match.1).lowercased()
        let replacement = variables[name] ?? variables["color-" + name] ?? match.2.map(String.init) ?? ""
        return resolve(value.replacingCharacters(in: match.range, with: replacement), in: variables, depth: depth + 1)
    }

    // MARK: - Color values

    /// hex, rgb()/rgba(), hsl()/hsla(), shadcn v3's bare "H S% L%", oklch(), and a few names.
    static func parseColor(_ raw: String) -> RGBA? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { return RGBA(hex: value) }
        switch value {
        case "white": return RGBA(0xFFFFFF)
        case "black": return RGBA(0x000000)
        default: break
        }
        if let call = value.firstMatch(of: #/^([a-z]+)\((.*)\)$/#) {
            let args = arguments(String(call.2))
            switch call.1 {
            case "rgb", "rgba": return rgb(args)
            case "hsl", "hsla": return hsl(args)
            case "oklch": return oklch(args)
            default: return nil
            }
        }
        // shadcn v3: "222.2 84% 4.9%" (meant for hsl(var(--x))).
        let parts = arguments(value)
        if parts.count >= 3, parts[1].hasSuffix("%"), parts[2].hasSuffix("%") { return hsl(parts) }
        return nil
    }

    /// "1 2 3 / 0.5", "1, 2, 3, 0.5" → ["1", "2", "3", "0.5"].
    private static func arguments(_ text: String) -> [String] {
        text.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split(separator: " ")
            .map(String.init)
    }

    /// "50%" → 0.5 of `scale`; "0.5" → 0.5 (or `value / scale` when `divideBy`).
    private static func number(_ s: String, percentOf scale: Double = 1, divideBy: Double = 1) -> Double? {
        if s.hasSuffix("%") { return Double(s.dropLast()).map { $0 / 100 * scale } }
        if s.hasSuffix("deg") { return Double(s.dropLast(3)) }
        return Double(s).map { $0 / divideBy }
    }

    private static func alpha(_ args: [String], at index: Int) -> Double {
        index < args.count ? (number(args[index]) ?? 1) : 1
    }

    private static func rgb(_ args: [String]) -> RGBA? {
        guard args.count >= 3,
              let r = number(args[0], divideBy: 255), let g = number(args[1], divideBy: 255), let b = number(args[2], divideBy: 255)
        else { return nil }
        return RGBA(r: r, g: g, b: b, a: alpha(args, at: 3))
    }

    private static func hsl(_ args: [String]) -> RGBA? {
        guard args.count >= 3, let h = number(args[0]), let s = number(args[1], divideBy: 100), let l = number(args[2], divideBy: 100)
        else { return nil }
        // number() already turned "84%" into 0.84; a bare "84" was divided by 100.
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ t: Double) -> Double {
            let k = (t * 12 + hue * 12).truncatingRemainder(dividingBy: 12)
            let a = s * min(l, 1 - l)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return RGBA(r: channel(0), g: channel(8 / 12), b: channel(4 / 12), a: alpha(args, at: 3))
    }

    /// OKLCH → OKLab → linear sRGB → sRGB (Björn Ottosson's matrices). Out-of-gamut values are clamped.
    private static func oklch(_ args: [String]) -> RGBA? {
        guard args.count >= 3, let L = number(args[0]), let C = number(args[1], percentOf: 0.4), let H = number(args[2]) else { return nil }
        let hue = H * .pi / 180
        let a = C * cos(hue)
        let b = C * sin(hue)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let (l, m, s) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func gamma(_ x: Double) -> Double {
            let c = min(max(x, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return RGBA(r: gamma(r), g: gamma(g), b: gamma(bl), a: alpha(args, at: 3))
    }
}
