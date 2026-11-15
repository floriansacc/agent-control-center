import AppKit

/// Right-click (or Control-click) on the menu bar icon shows the settings as a native menu, while a
/// regular click still opens the session list.
///
/// `MenuBarExtra` exposes neither its `NSStatusItem` nor a secondary-click hook, so this watches the
/// app's own mouse events and picks those that land on the status item's window.
@MainActor
final class StatusItemMenu: NSObject {
    static let shared = StatusItemMenu()

    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let secondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard secondary, let window = event.window else { return event }
            // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated {
                guard let button = Self.statusButton(in: window) else { return false }
                StatusItemMenu.shared.show(from: button)
                return true
            }
            return handled ? nil : event
        }
    }

    private static func statusButton(in window: NSWindow) -> NSButton? {
        guard NSStringFromClass(type(of: window)).contains("StatusBarWindow"), let content = window.contentView else {
            return nil
        }
        return MenuBarAppearance.findButton(in: content)
    }

    private func show(from button: NSButton) {
        let model = AppModel.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item(model.panelVisible ? "Hide Floating Panel" : "Show Floating Panel") { model.togglePanel() })
        menu.addItem(item("Refresh") { model.refresh() })
        menu.addItem(.separator())
        menu.addItem(item("Notify when input is needed", on: model.notifyOnWaiting) { model.notifyOnWaiting.toggle() })
        menu.addItem(item("Notify when a session finishes", on: model.notifyOnDone) { model.notifyOnDone.toggle() })
        let fold = NSMenuItem(title: "Fold idle sessions after", action: nil, keyEquivalent: "")
        let foldMenu = NSMenu()
        for choice in AppModel.foldIdleChoices {
            foldMenu.addItem(item(choice.label, on: model.foldIdleAfter == choice.seconds) { model.foldIdleAfter = choice.seconds })
        }
        fold.submenu = foldMenu
        menu.addItem(fold)
        if model.isBundled {
            menu.addItem(item("Launch at login", on: model.launchAtLogin) { model.setLaunchAtLogin(!model.launchAtLogin) })
        }
        menu.addItem(.separator())
        let quit = item("Quit Agent Control Center") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        // A menu popped up in a view takes that view's appearance, and the status bar button uses the menu
        // bar's (dark over a dark wallpaper even in light mode). Follow the system theme like other menus.
        menu.appearance = NSApp.effectiveAppearance

        // Keep the icon highlighted while the menu is open, like a native status item menu.
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        button.highlight(false)
    }

    private func item(_ title: String, on: Bool? = nil, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, handler: action)
        if let on { item.state = on ? .on : .off }
        return item
    }
}

/// An `NSMenuItem` that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        MainActor.assumeIsolated { handler() }
    }
}
