import AppKit

/// Whether the app shows in the Dock (and ⌘-Tab, with a menu bar) or only in the menu bar.
enum DockMode: String, CaseIterable, Identifiable {
    case never
    case whileWindowOpen
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .whileWindowOpen: "While a window is open"
        case .always: "Always"
        }
    }
}

/// Switches between a menu bar app and a regular app, following the Dock setting and which windows are
/// open, and gives the app a standard menu bar (Edit, Window…) for when it is a regular app.
@MainActor
final class AppShell {
    static let shared = AppShell()

    private var openWindows = Set<ObjectIdentifier>()

    var dockMode: DockMode {
        get { DockMode(rawValue: UserDefaults.standard.string(forKey: "dockMode") ?? "") ?? .whileWindowOpen }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "dockMode")
            update()
        }
    }

    /// Called by the Control Center and Settings windows as they open and close.
    func windowOpened(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        update()
    }

    func windowClosed(_ window: NSWindow) {
        openWindows.remove(ObjectIdentifier(window))
        update()
    }

    func update() {
        let regular = switch dockMode {
        case .never: false
        case .whileWindowOpen: !openWindows.isEmpty
        case .always: true
        }
        let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if regular {
            installMainMenu()
            // Becoming a regular app does not bring it forward by itself.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// App, Edit and Window menus. Their shortcuts also work while the app is menu bar only.
    func installMainMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Agent Control Center", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(ShellMenuItem("Settings…", key: ",") { SettingsWindow.shared.show() })
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Agent Control Center", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Agent Control Center", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "Agent Control Center"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(ShellMenuItem("Control Center", key: "0") { AppModel.shared.openControlCenter() })
        window.addItem(.separator())
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// A menu item that runs a closure.
final class ShellMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        MainActor.assumeIsolated { handler() }
    }
}
