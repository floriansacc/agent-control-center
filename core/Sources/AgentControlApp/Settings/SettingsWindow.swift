import AppKit
import SwiftUI

/// The Settings window (⌘,): General and Appearance. Built when opened, released when closed.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil {
            let controller = NSHostingController(rootView: Themed(surfaces: true) { SettingsView(app: AppModel.shared) })
            controller.sceneBridgingOptions = [.toolbars, .title]
            let frame = window.frame
            window.contentViewController = controller
            window.setFrame(frame, display: false)
        }
        AppShell.shared.windowOpened(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        // Wide enough for the Appearance page's base row (System, Neutral, Zinc, Stone, Slate) on one line.
        window.minSize = NSSize(width: 860, height: 480)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("AgentControlSettingsWindow")
        // A size saved before the minimum grew.
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            var frame = window.frame
            frame.size.width = max(frame.width, window.minSize.width)
            frame.size.height = max(frame.height, window.minSize.height)
            window.setFrame(frame, display: false)
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        window.contentViewController = nil
        AppShell.shared.windowClosed(window)
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @Environment(\.theme) private var theme

    enum Page: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"

        var id: String { rawValue }
        var symbol: String { self == .general ? "gearshape" : "paintpalette" }
    }

    @State private var page = Page.appearance

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(page == item ? theme.accentForeground : theme.text)
                            .background(RoundedRectangle(cornerRadius: 7).fill(page == item ? theme.accent : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if !theme.isNative { theme.sidebar.ignoresSafeArea() } }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch page {
                case .general: GeneralSettings(app: app)
                case .appearance: AppearanceSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if !theme.isNative { theme.background.ignoresSafeArea() } }
        }
        .foregroundStyle(theme.text)
        .navigationTitle(page.rawValue)
    }
}

/// A titled group of settings.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(theme.textSecondary)
            }
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var app: AppModel
    @Environment(\.theme) private var theme
    @State private var dockMode = AppShell.shared.dockMode

    var body: some View {
        ColumnScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: "Notifications", footer: "Notifications never repeat: one per change of state.") {
                    Toggle("When a session needs input", isOn: $app.notifyOnWaiting)
                    Toggle("When a session finishes", isOn: $app.notifyOnDone)
                }
                SettingsSection(title: "Sessions") {
                    Picker("Fold idle sessions after", selection: $app.foldIdleAfter) {
                        ForEach(AppModel.foldIdleChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }
                    .frame(maxWidth: 360)
                }
                SettingsSection(
                    title: "App",
                    footer: "In the Dock, the app also shows in ⌘-Tab and gets a menu bar. Its menu bar icon stays either way."
                ) {
                    Picker("Show in the Dock", selection: $dockMode) {
                        ForEach(DockMode.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 360)
                    .onChange(of: dockMode) { _, mode in AppShell.shared.dockMode = mode }
                    if app.isBundled {
                        Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                    }
                }
                SettingsSection(title: "Claude Code hook") {
                    if app.hookInstalled {
                        Label("Set up: every Claude Code session reports its status.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(theme.done)
                    } else {
                        HStack {
                            Label("Not set up: sessions show without their status or conversation.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.waiting)
                            Spacer()
                            Button("Set Up…") { app.setUpHook() }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
