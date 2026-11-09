import AppKit
import SwiftUI

/// Keeps the MenuBarExtra window exactly as tall as its content.
///
/// MenuBarExtra (.window style) grows its window when the content grows but never shrinks it,
/// so collapsing a section (or a session disappearing) leaves the content floating in an
/// oversized window. This resizes the window to the content, keeping its top edge under the menu bar.
@MainActor
final class MenuWindowFitter {
    private weak var window: NSWindow?
    private var height: CGFloat = 0

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        fit()
    }

    func update(height: CGFloat) {
        self.height = height
        fit()
    }

    private func fit() {
        // Deferred: resizing the window during a SwiftUI layout pass triggers layout recursion.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.height > 0 else { return }
            var frame = window.frame
            let delta = self.height - window.contentRect(forFrameRect: frame).height
            guard abs(delta) > 0.5 else { return }
            frame.size.height += delta
            frame.origin.y -= delta // AppKit origin is bottom-left: move it to keep the top fixed.
            window.setFrame(frame, display: true)
        }
    }
}

/// Hands the NSWindow hosting this view to a callback once the view is in a window.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
    }
}
