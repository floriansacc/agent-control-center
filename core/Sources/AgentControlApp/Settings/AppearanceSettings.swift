import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Light / dark mode, the theme (System, a base × accent preset, or a custom theme), its preview, and the
/// editor for custom themes.
struct AppearanceSettings: View {
    @ObservedObject private var store = ThemeStore.shared
    @Environment(\.theme) private var theme
    @State private var showPaste = false
    @State private var importError: String?

    private var current: Theme { store.current }

    var body: some View {
        ColumnScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: "Mode") {
                    Picker("Appearance", selection: $store.appearance) {
                        ForEach(ThemeStore.Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
                SettingsSection(
                    title: "Theme",
                    footer: "Presets follow shadcn/ui: a base gray and an accent. The theme colors the Control Center and "
                        + "Settings windows; the menu dropdown keeps its translucent look and takes the accent and status colors."
                ) {
                    presets
                }
                SettingsSection(title: "Custom themes") {
                    customThemes
                }
                SettingsSection(title: "Preview") {
                    HStack(spacing: 12) {
                        ThemePreview(theme: current, dark: false)
                        ThemePreview(theme: current, dark: true)
                    }
                }
                if !current.isPreset {
                    ThemeEditor(theme: current)
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showPaste) { CSSPasteSheet(isPresented: $showPaste) }
        .alert("Could not import the theme", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Presets

    /// The base and accent of the selected preset, when it is one.
    private var selectedBase: String? {
        current.isSystem ? ThemePresets.systemId : ThemePresets.bases.first { current.isPreset && current.id.hasPrefix($0.id + "-") }?.id
    }

    private var selectedAccent: String? {
        guard current.isPreset, !current.isSystem else { return nil }
        return ThemePresets.accents.first { current.id.hasSuffix("-" + $0.id) }?.id
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Base").frame(width: 56, alignment: .leading).foregroundStyle(theme.textSecondary)
                BaseChip(name: "System", swatches: [], selected: selectedBase == ThemePresets.systemId) {
                    store.select(ThemePresets.systemId)
                }
                ForEach(ThemePresets.bases, id: \.id) { base in
                    BaseChip(
                        name: base.name,
                        swatches: [base.shade(200), base.shade(500), base.shade(900)],
                        selected: selectedBase == base.id
                    ) {
                        // Keep the accent when switching base.
                        let accent = ThemePresets.accents.first { $0.id == selectedAccent } ?? ThemePresets.accents[1]
                        store.select(ThemePresets.id(base: base, accent: accent))
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Accent").frame(width: 56, alignment: .leading).foregroundStyle(theme.textSecondary)
                ForEach(ThemePresets.accents, id: \.id) { accent in
                    let base = ThemePresets.bases.first { $0.id == selectedBase } ?? ThemePresets.bases[0]
                    let preset = ThemePresets.make(base: base, accent: accent)
                    AccentSwatch(color: preset[.accent], name: accent.name, selected: selectedAccent == accent.id) {
                        store.select(preset.id)
                    }
                }
                Spacer()
            }
            .opacity(current.isSystem ? 0.6 : 1)
            .help(current.isSystem ? "The System theme uses the macOS accent color. Pick an accent to switch to a preset." : "")
        }
    }

    // MARK: - Custom themes

    private var customThemes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.custom.isEmpty {
                Text("Start from any theme with Customize, or import one.").foregroundStyle(theme.textSecondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(store.custom) { custom in
                        CustomChip(theme: custom, selected: custom.id == current.id) { store.select(custom.id) }
                            .contextMenu {
                                Button("Duplicate") { store.duplicate(custom) }
                                Button("Export…") { export(custom) }
                                Divider()
                                Button("Delete", role: .destructive) { store.delete(custom.id) }
                            }
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    store.duplicate(current)
                } label: {
                    Label(current.isPreset ? "Customize \(current.name)" : "Duplicate", systemImage: "slider.horizontal.3")
                }
                Menu {
                    Button("Paste CSS…") { showPaste = true }
                    Button("Open File…") { importFile() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .fixedSize()
                Button { export(current) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Spacer()
            }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json] + [UTType(filenameExtension: "css")].compactMap { $0 }
        panel.message = "Choose a theme exported from Agent Control Center (.json) or a CSS theme (.css)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importFile(url)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func export(_ theme: Theme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(theme, to: url)
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Pickers

private struct BaseChip: View {
    let name: String
    let swatches: [RGBA]
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if swatches.isEmpty {
                    Image(systemName: "apple.logo").font(.caption)
                } else {
                    HStack(spacing: -4) {
                        ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                            Circle().fill(Color(nsColor: color.nsColor)).frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(theme.border))
                        }
                    }
                }
                Text(name)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? theme.accent.opacity(0.15) : theme.background))
            .overlay(Capsule().strokeBorder(selected ? theme.accent : theme.border, lineWidth: selected ? 2 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct AccentSwatch: View {
    let color: ThemeColor
    let name: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color.value(dark: scheme == .dark).nsColor))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(theme.border))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? theme.text : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CustomChip: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var current
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                HStack(spacing: -4) {
                    ForEach([ThemeToken.background, .accent, .text], id: \.self) { token in
                        Circle().fill(Color(nsColor: theme[token].value(dark: scheme == .dark).nsColor))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(current.border))
                    }
                }
                Text(theme.name).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? current.accent.opacity(0.15) : current.background))
            .overlay(Capsule().strokeBorder(selected ? current.accent : current.border, lineWidth: selected ? 2 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

/// A miniature Control Center drawn with a theme's light or dark values.
struct ThemePreview: View {
    let theme: Theme
    let dark: Bool

    private func c(_ token: ThemeToken) -> Color { Color(nsColor: theme[token].value(dark: dark).nsColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                // Sidebar.
                VStack(alignment: .leading, spacing: 5) {
                    row(.waiting, selected: false)
                    row(.working, selected: true)
                    row(.done, selected: false)
                    Spacer()
                }
                .padding(7)
                .frame(width: 104)
                .background(c(.sidebar))
                c(.border).frame(width: 1)
                // Conversation.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer()
                        Text("Fix the build").font(.system(size: 8)).foregroundStyle(c(.text))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(c(.bubble)))
                    }
                    Text("Done: the tests pass.").font(.system(size: 8)).foregroundStyle(c(.text))
                    HStack(spacing: 4) {
                        Image(systemName: "terminal").font(.system(size: 7))
                        Text("Bash · swift test").font(.system(size: 7).monospaced())
                    }
                    .foregroundStyle(c(.textSecondary))
                    RoundedRectangle(cornerRadius: 3).fill(c(.card)).frame(height: 14)
                    Spacer()
                    HStack {
                        Spacer()
                        Text("Open").font(.system(size: 8, weight: .medium)).foregroundStyle(c(.accentForeground))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(c(.accent)))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(c(.background))
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(c(.border)))
            .environment(\.colorScheme, dark ? .dark : .light)
            Text(dark ? "Dark" : "Light").font(.caption)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.name), \(dark ? "dark" : "light") preview")
    }

    private func row(_ status: ThemeToken, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(selected ? c(.accentForeground) : c(status)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                RoundedRectangle(cornerRadius: 1).fill(selected ? c(.accentForeground) : c(.text)).frame(width: 48, height: 4)
                RoundedRectangle(cornerRadius: 1).fill(selected ? c(.accentForeground).opacity(0.7) : c(.textFaint)).frame(width: 34, height: 3)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? c(.accent) : .clear))
    }
}

// MARK: - Editor

/// The colors of a custom theme, each with a light and a dark well, and readability warnings.
private struct ThemeEditor: View {
    let theme: Theme
    @ObservedObject private var store = ThemeStore.shared
    @Environment(\.theme) private var colors
    @State private var name = ""

    var body: some View {
        SettingsSection(title: "Edit \(theme.name)") {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(rename)
                    .onChange(of: name) { _, _ in rename() }
                Spacer()
                Button("Delete Theme…", role: .destructive) { delete() }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Light").font(.caption.weight(.semibold)).foregroundStyle(colors.textSecondary)
                    Text("Dark").font(.caption.weight(.semibold)).foregroundStyle(colors.textSecondary)
                }
                ForEach(ThemeToken.Group.allCases, id: \.self) { group in
                    GridRow {
                        Text(group.rawValue).font(.caption.weight(.semibold)).foregroundStyle(colors.textFaint)
                            .gridCellColumns(3)
                            .padding(.top, 6)
                    }
                    ForEach(ThemeToken.allCases.filter { $0.group == group }) { token in
                        GridRow {
                            Text(token.label).help(token.help)
                            well(token, dark: false)
                            well(token, dark: true)
                        }
                    }
                }
            }
            let warnings = theme.contrastWarnings
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Hard to read (below 4.5:1 contrast)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(colors.waiting)
                        .font(.callout.weight(.semibold))
                    ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(colors.textSecondary) }
                }
            }
        }
        .onAppear { name = theme.name }
        .onChange(of: theme.id) { _, _ in name = theme.name }
    }

    private func well(_ token: ThemeToken, dark: Bool) -> some View {
        let binding = Binding<Color>(
            get: { Color(nsColor: theme[token].value(dark: dark).nsColor) },
            set: { color in
                guard let rgba = RGBA(NSColor(color)) else { return }
                var edited = theme
                var pair = edited[token]
                if dark { pair.dark = rgba } else { pair.light = rgba }
                edited[token] = pair
                store.update(edited)
            }
        )
        return HStack(spacing: 6) {
            ColorPicker(token.label, selection: binding, supportsOpacity: false).labelsHidden()
            Text(theme[token].value(dark: dark).hex)
                .font(.caption.monospaced())
                .foregroundStyle(colors.textSecondary)
                .textSelection(.enabled)
        }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != theme.name else { return }
        var edited = theme
        edited.name = trimmed
        store.update(edited)
    }

    private func delete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(theme.name)”?"
        alert.informativeText = "Export it first to keep a copy."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.delete(theme.id) }
    }
}

// MARK: - Paste CSS

private struct CSSPasteSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var store = ThemeStore.shared
    @Environment(\.theme) private var colors
    @State private var css = ""
    @State private var name = "Imported theme"

    private var result: Result<CSSThemeImporter.Result, Error>? {
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Result { try CSSThemeImporter.parse(css, name: name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a CSS theme").font(.headline)
            Text("From ui.shadcn.com/themes, tweakcn.com, a Tailwind @theme block, or any CSS with color variables "
                + "(--background, --foreground, --primary…). Light values come from :root, dark ones from .dark.")
                .font(.callout)
                .foregroundStyle(colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $css)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(colors.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.border))
                .frame(minHeight: 200)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            switch result {
            case let .success(parsed):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        ThemePreview(theme: parsed.theme, dark: false)
                        ThemePreview(theme: parsed.theme, dark: true)
                    }
                    .frame(maxWidth: 480)
                    Text(summary(parsed)).font(.caption).foregroundStyle(colors.textSecondary)
                }
            case let .failure(error):
                Text(error.localizedDescription).font(.callout).foregroundStyle(colors.error)
            case nil:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    if case let .success(parsed) = result {
                        store.add(parsed.theme)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled({ if case .success = result { return false } else { return true } }())
            }
        }
        .padding(20)
        .frame(width: 620)
        .foregroundStyle(colors.text)
    }

    private func summary(_ parsed: CSSThemeImporter.Result) -> String {
        var parts = ["Found \(parsed.found.count) of \(ThemeToken.allCases.count) colors; the others are derived or come from Neutral · Blue."]
        if !parsed.hasDark { parts.append("No dark values (.dark): dark mode uses the default theme's colors.") }
        if !parsed.hasLight { parts.append("No light values (:root): light mode uses the default theme's colors.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Layout

/// Lays children out in rows, wrapping to the next row when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
