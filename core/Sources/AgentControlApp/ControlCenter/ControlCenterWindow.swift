import AppKit
import SwiftUI

/// The Control Center: a regular window listing every session, with the selected one's conversation and
/// details. Opened from the menu bar dropdown, the right-click menu, or a session's context menu.
///
/// Its content (views, model, transcript) is created when the window opens and released when it closes,
/// so the menu bar app stays light the rest of the time. Whether the app shows in the Dock meanwhile is a
/// setting (AppShell).
@MainActor
final class ControlCenterWindow: NSObject, NSWindowDelegate {
    static let shared = ControlCenterWindow()

    private var window: NSWindow?
    private var model: ControlCenterModel?

    var isOpen: Bool { window?.isVisible == true }

    /// Opens (or brings forward) the window; `key` selects that session.
    func show(select key: String? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        if let model {
            if let key { model.selection = key }
        } else {
            let model = ControlCenterModel(selection: key)
            self.model = model
            (window as? ControlCenterNSWindow)?.onNumber = { [weak model] n in model?.selectNumber(n) ?? false }
            let controller = NSHostingController(rootView: Themed(surfaces: true) {
                ControlCenterView(app: AppModel.shared, model: model)
            })
            // The SwiftUI toolbar and title go to the window.
            controller.sceneBridgingOptions = [.toolbars, .title]
            // Keep the saved frame: the hosting controller would otherwise resize the window to its ideal size.
            let frame = window.frame
            window.contentViewController = controller
            window.setFrame(frame, display: false)
        }
        AppShell.shared.windowOpened(window)
        // A menu bar app is never the active app on its own: activate it, or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = ControlCenterNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Control Center"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 420)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("AgentControlCenterWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        // Releases the SwiftUI views and the transcript.
        window?.contentViewController = nil
        if let window { AppShell.shared.windowClosed(window) }
    }
}

/// Handles ⌘1–⌘9, and the standard shortcuts while the app has no menu bar (not in the Dock).
private final class ControlCenterNSWindow: NSWindow {
    /// ⌘1–⌘9: selects the nth session; returns whether there was one.
    var onNumber: ((Int) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Here rather than as hidden SwiftUI buttons: those are real (invisible) buttons that caught the mouse
        // in the middle of the sidebar.
        if modifiers == .command, let key = event.charactersIgnoringModifiers, let n = Int(key), (1...9).contains(n) {
            return onNumber?(n) ?? false
        }
        if super.performKeyEquivalent(with: event) { return true }
        // Without a menu bar (app not in the Dock), ⌘, has no Settings menu item to go through.
        if modifiers == .command, event.charactersIgnoringModifiers == "," {
            SettingsWindow.shared.show()
            return true
        }
        guard modifiers == .command || modifiers == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        let action: Selector? = switch (key, modifiers.contains(.shift)) {
        case ("w", false): #selector(performClose(_:))
        case ("m", false): #selector(performMiniaturize(_:))
        case ("c", false): #selector(NSText.copy(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("x", false): #selector(NSText.cut(_:))
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}
