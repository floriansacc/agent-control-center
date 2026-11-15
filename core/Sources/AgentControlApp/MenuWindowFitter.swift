import AppKit
import SwiftUI

/// Keeps the MenuBarExtra window exactly as tall as its content, with its top edge under the menu bar.
///
/// SwiftUI only gives this window a *minimum* content size: it grows the window when the content grows
/// (before drawing), but never shrinks it. Shrinking it afterwards (on the next run loop turn) is a frame
/// late: for one frame the panel is drawn at the bottom of the still-tall window, a visible flicker.
///
/// So the window is resized synchronously from `MenuSizeTracker`, an AppKit view laid out behind the
/// content: its frame changes during the layout pass, i.e. before that frame is drawn.
@MainActor
final class MenuWindowFitter {
    private weak var window: NSWindow?
    private var height: CGFloat = 0
    /// Where the window's top edge belongs (screen coordinates); taken when the window is shown.
    private var anchorTop: CGFloat?
    private var observers: [NSObjectProtocol] = []
    private var resizing = false

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        anchorTop = window.frame.maxY
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        observers = [
            // The menu is (re)opened: MenuBarExtra has just placed the window under the status item.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.anchorTop = window.frame.maxY
                }
            },
        ]
        fit()
    }

    /// Called during layout with the content's new height.
    func update(height: CGFloat) {
        guard abs(height - self.height) > 0.5 else { return }
        self.height = height
        fit()
    }

    private func fit() {
        guard !resizing, let window, height > 0 else { return }
        var frame = window.frame
        let delta = height - window.contentRect(forFrameRect: frame).height
        guard abs(delta) > 0.5 else { return }
        let top = anchorTop ?? frame.maxY
        frame.size.height += delta
        frame.origin.y = top - frame.height // AppKit origin is bottom-left: keep the top fixed.
        resizing = true
        // No forced display: the frame being laid out draws once, at the new size.
        window.setFrame(frame, display: false)
        resizing = false
    }
}

/// Laid out behind the menu content: reports the window it lives in and its own height (the content's)
/// the moment AppKit sizes it, so the window can be resized in the same layout pass.
struct MenuSizeTracker: NSViewRepresentable {
    let fitter: MenuWindowFitter

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.fitter = fitter
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.fitter = fitter
    }

    final class TrackingView: NSView {
        weak var fitter: MenuWindowFitter?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { fitter?.attach(window) }
            fitter?.update(height: frame.height)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fitter?.update(height: newSize.height)
        }
    }
}
