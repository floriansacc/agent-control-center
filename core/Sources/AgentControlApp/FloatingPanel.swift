import AppKit
import SwiftUI

/// Small always-on-top window that follows you across Spaces and full-screen apps,
/// without stealing focus from the app you are typing in.
final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Agents"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        minSize = NSSize(width: 300, height: 160)
        let hosting = NSHostingView(rootView: rootView)
        // Only enforce the minimum size; otherwise the panel snaps to the content's ideal size
        // and cannot be resized freely.
        hosting.sizingOptions = [.minSize]
        contentView = hosting
        if !setFrameUsingName("AgentControlPanel") {
            // First time: top-right corner of the main screen.
            if let screen = NSScreen.main?.visibleFrame {
                setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 16, y: screen.maxY - frame.height - 16))
            }
        }
        setFrameAutosaveName("AgentControlPanel")
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
    }
}
