import AppKit
import SwiftUI

/// The Control Center: a regular window listing every session, with the selected one's conversation and
/// details. Opened from the menu bar dropdown, the right-click menu, or a session's context menu.
///
/// Its content (views, model, transcript) is created when the window opens and released when it closes,
/// so the menu bar app stays light the rest of the time. The app keeps no Dock icon while it is open.
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
            let controller = NSHostingController(rootView: ControlCenterView(app: AppModel.shared, model: model))
            // The SwiftUI toolbar and title go to the window.
            controller.sceneBridgingOptions = [.toolbars, .title]
            // Keep the saved frame: the hosting controller would otherwise resize the window to its ideal size.
            let frame = window.frame
            window.contentViewController = controller
            window.setFrame(frame, display: false)
        }
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
    }
}

/// Handles the standard shortcuts itself: a menu bar app has no visible main menu to route them.
private final class ControlCenterNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
