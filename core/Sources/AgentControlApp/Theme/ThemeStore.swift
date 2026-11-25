import AgentCore
import AppKit
import SwiftUI

/// The current theme's colors, as views use them (`@Environment(\.theme) private var theme`).
///
/// Each color is a dynamic color with a light and a dark value, so light / dark mode switches need nothing
/// more. Where the themes apply (scope agreed on): status and accent colors everywhere; surfaces and text
/// only in the Control Center and Settings windows, the menu dropdown keeps its translucent native look.
struct ThemeColors: Equatable {
    /// Changes with every theme edit: views reading the theme re-render.
    var revision: Int
    /// The System theme: keep native materials, backgrounds and text colors.
    var isNative: Bool

    var background: Color
    var sidebar: Color
    var card: Color
    var border: Color
    var text: Color
    var textSecondary: Color
    var textFaint: Color
    /// Inline code text; its background is `card`.
    var code: Color
    var accent: Color
    var accentForeground: Color
    var bubble: Color
    var working: Color
    var waiting: Color
    var done: Color
    var error: Color

    static func == (a: ThemeColors, b: ThemeColors) -> Bool { a.revision == b.revision }

    func status(_ status: SessionStatus) -> Color {
        switch status {
        case .waiting: waiting
        case .error: error
        case .working: working
        case .done: done
        case .idle, .untracked: textSecondary
        }
    }

    /// Context and plan usage: done color below 60%, waiting color to 85%, error color above.
    func usage(_ percent: Double) -> Color {
        percent >= 85 ? error : percent >= 60 ? waiting : done
    }

    /// For the menu dropdown: the theme's accent and status colors, but native text
    /// and surfaces, made for their translucent background.
    func forMenu() -> ThemeColors {
        var colors = self
        colors.background = ThemeColors.system.background
        colors.sidebar = ThemeColors.system.sidebar
        colors.card = ThemeColors.system.card
        colors.border = ThemeColors.system.border
        colors.text = Palette.textBody
        colors.textSecondary = Palette.textMeta
        colors.textFaint = Palette.textFaint
        return colors
    }

    /// The native look (today's colors).
    static let system = ThemeColors(
        revision: 0,
        isNative: true,
        background: Color(nsColor: .windowBackgroundColor),
        sidebar: .clear,
        card: Color.primary.opacity(0.05),
        border: Color(nsColor: .separatorColor),
        text: .primary,
        textSecondary: .secondary,
        textFaint: Color(nsColor: .tertiaryLabelColor),
        code: Color(nsColor: Theme(id: "", name: "", colors: [.code: ThemePresets.codeColor]).nsColor(.code)),
        accent: .accentColor,
        accentForeground: .white,
        bubble: Palette.blue.opacity(0.13),
        working: Palette.blue,
        waiting: Palette.orange,
        done: Palette.green,
        error: Palette.red
    )

    init(theme: Theme, revision: Int) {
        func color(_ token: ThemeToken) -> Color { Color(nsColor: theme.nsColor(token)) }
        self.revision = revision
        isNative = false
        background = color(.background)
        sidebar = color(.sidebar)
        card = color(.card)
        border = color(.border)
        text = color(.text)
        textSecondary = color(.textSecondary)
        textFaint = color(.textFaint)
        code = color(.code)
        accent = color(.accent)
        accentForeground = color(.accentForeground)
        bubble = color(.bubble)
        working = color(.working)
        waiting = color(.waiting)
        done = color(.done)
        error = color(.error)
    }

    private init(
        revision: Int, isNative: Bool, background: Color, sidebar: Color, card: Color, border: Color, text: Color,
        textSecondary: Color, textFaint: Color, code: Color, accent: Color, accentForeground: Color, bubble: Color,
        working: Color, waiting: Color, done: Color, error: Color
    ) {
        self.revision = revision
        self.isNative = isNative
        self.background = background
        self.sidebar = sidebar
        self.card = card
        self.border = border
        self.text = text
        self.textSecondary = textSecondary
        self.textFaint = textFaint
        self.code = code
        self.accent = accent
        self.accentForeground = accentForeground
        self.bubble = bubble
        self.working = working
        self.waiting = waiting
        self.done = done
        self.error = error
    }
}

extension Theme {
    /// The token as a dynamic color: its light or dark value depending on where it is drawn.
    func nsColor(_ token: ThemeToken) -> NSColor {
        let pair = self[token]
        let light = pair.light.nsColor
        let dark = pair.dark.nsColor
        return NSColor(name: nil) { Palette.isDark($0) ? dark : light }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ThemeColors.system
}

extension EnvironmentValues {
    var theme: ThemeColors {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Gives `content` the current theme, and re-renders it when the theme changes. Wraps every root view.
/// `surfaces: false` (the menu dropdown) keeps native text and backgrounds.
struct Themed<Content: View>: View {
    @ObservedObject private var store = ThemeStore.shared
    private let surfaces: Bool
    private let content: Content

    init(surfaces: Bool, @ViewBuilder _ content: () -> Content) {
        self.surfaces = surfaces
        self.content = content()
    }

    var body: some View {
        let colors = surfaces ? store.colors : store.colors.forMenu()
        content
            .environment(\.theme, colors)
            .tint(colors.accent)
    }
}

/// The selected theme, the custom themes, and light / dark mode. Saved in the app's defaults.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Published private(set) var custom: [Theme]
    @Published private(set) var selectedId: String
    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }
    @Published private(set) var colors = ThemeColors.system

    private let defaults = UserDefaults.standard
    private var revision = 0
    private var saveWork: DispatchWorkItem?
    private var systemTheme: Theme
    private var accentObserver: NSObjectProtocol?

    private enum Keys {
        static let custom = "themes.custom"
        static let selected = "themes.selected"
        static let appearance = "themes.appearance"
    }

    private init() {
        custom = (defaults.data(forKey: Keys.custom)).flatMap { try? JSONDecoder().decode([Theme].self, from: $0) } ?? []
        selectedId = defaults.string(forKey: Keys.selected) ?? ThemePresets.systemId
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        systemTheme = ThemePresets.system
        rebuild()
        applyAppearance()
        // The System theme follows the macOS accent color.
        accentObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ThemeStore.shared.systemTheme = ThemePresets.system
                ThemeStore.shared.rebuild()
            }
        }
    }

    var presets: [Theme] { [systemTheme] + ThemePresets.all }

    var current: Theme {
        theme(id: selectedId) ?? systemTheme
    }

    func theme(id: String) -> Theme? {
        if id == ThemePresets.systemId { return systemTheme }
        return custom.first { $0.id == id } ?? ThemePresets.all.first { $0.id == id }
    }

    func select(_ id: String) {
        guard id != selectedId, theme(id: id) != nil else { return }
        selectedId = id
        defaults.set(id, forKey: Keys.selected)
        rebuild()
    }

    /// An editable copy of `theme`, selected.
    @discardableResult
    func duplicate(_ theme: Theme) -> Theme {
        let base = theme.isPreset ? theme.name : "\(theme.name) copy"
        var name = base
        var n = 2
        while custom.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"
            n += 1
        }
        return add(theme.duplicate(named: name))
    }

    @discardableResult
    func add(_ theme: Theme) -> Theme {
        var theme = theme
        theme.isPreset = false
        theme.isSystem = false
        custom.append(theme)
        saveCustom(now: true)
        select(theme.id)
        return theme
    }

    /// Saves an edit of a custom theme; the UI updates at once, the defaults shortly after.
    func update(_ theme: Theme) {
        guard let index = custom.firstIndex(where: { $0.id == theme.id }), custom[index] != theme else { return }
        custom[index] = theme
        if theme.id == selectedId { rebuild() }
        saveCustom(now: false)
    }

    func delete(_ id: String) {
        custom.removeAll { $0.id == id }
        saveCustom(now: true)
        if selectedId == id {
            selectedId = ThemePresets.systemId
            defaults.set(selectedId, forKey: Keys.selected)
            rebuild()
        }
    }

    /// The selected theme's color as AppKit draws it, e.g. the menu bar bell.
    func nsColor(_ token: ThemeToken, dark: Bool) -> NSColor? {
        let theme = current
        return theme.isSystem ? nil : theme[token].value(dark: dark).nsColor
    }

    var revisionNumber: Int { revision }

    // MARK: - Files

    func export(_ theme: Theme, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme.file).write(to: url, options: .atomic)
    }

    /// A .json file exported by this app, or a .css theme. Added to the custom themes and selected.
    @discardableResult
    func importFile(_ url: URL) throws -> Theme {
        let data = try Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "css" {
            return add(try CSSThemeImporter.parse(String(decoding: data, as: UTF8.self), name: name).theme)
        }
        let file = try JSONDecoder().decode(Theme.File.self, from: data)
        guard file.format == Theme.File.format else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This is not an Agent Control Center theme file."])
        }
        return add(Theme(file: file))
    }

    // MARK: - Private

    private func rebuild() {
        revision += 1
        let theme = current
        colors = theme.isSystem ? ThemeColors.system : ThemeColors(theme: theme, revision: revision)
        if theme.isSystem { colors.revision = revision }
    }

    private func saveCustom(now: Bool) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.custom) else { return }
            self.defaults.set(data, forKey: Keys.custom)
        }
        saveWork = work
        if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work) }
    }

    private func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
