import AgentCore
import AppKit
import SwiftUI

/// Menu bar label: a spinner with the number of running sessions, then a terminal (or a bell when
/// one needs input) with the number of the other ones.
///
/// `MenuBarExtra` only shows one image and one text from its label, so the whole label is drawn into a
/// single image. Normally a template image (black + alpha, recolored by macOS for light / dark menu
/// bars). While a session needs you, the bell is orange (red for an error); a template image cannot
/// hold a color, so that variant is drawn in the menu bar's own text color, read from the status item.
///
/// The spinner is deliberately still: every image change makes AppKit re-snapshot the status item for
/// each display, which costs ~2% CPU per frame per second (~9% at 4 fps) for as long as an agent runs.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var menuBar = MenuBarAppearance.shared
    /// The bell takes the theme's "needs input" / "error" color.
    @ObservedObject var themes = ThemeStore.shared

    var body: some View {
        let counts = MenuBarCounts(model.snapshot.sessions)
        Image(nsImage: MenuBarIconRenderer.image(counts, darkMenuBar: menuBar.isDark, themeRevision: themes.revisionNumber))
            .accessibilityLabel(counts.accessibilityLabel)
    }
}

struct MenuBarCounts: Hashable {
    enum Alert: Hashable { case none, waiting, error }

    var running = 0
    var others = 0
    var alert = Alert.none

    init(_ sessions: [Session]) {
        for s in sessions {
            if s.status == .working {
                running += 1
            } else {
                others += 1
                if s.status == .waiting {
                    alert = .waiting
                } else if s.status == .error, alert == .none {
                    alert = .error
                }
            }
        }
    }

    var accessibilityLabel: String {
        if running == 0, others == 0 { return "Agent Control Center: no Claude sessions" }
        let rest: String
        switch alert {
        case .waiting: rest = "\(others) other, some need input"
        case .error: rest = "\(others) other, some stopped with an error"
        case .none: rest = "\(others) idle or finished"
        }
        return "Agent Control Center: \(running) running, \(rest)"
    }
}

/// Whether the menu bar behind our status item is dark (it follows the wallpaper, not only the system
/// theme). Read from the status item button's effective appearance and kept up to date with KVO.
@MainActor
final class MenuBarAppearance: ObservableObject {
    static let shared = MenuBarAppearance()

    @Published private(set) var isDark = false
    private var observation: NSKeyValueObservation?

    /// The status item window appears shortly after launch; retry until it does.
    func attach(attempt: Int = 0) {
        guard observation == nil else { return }
        guard let button = Self.statusButton() else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.attach(attempt: attempt + 1) }
            }
            return
        }
        update(button.effectiveAppearance)
        observation = button.observe(\.effectiveAppearance, options: [.new]) { button, _ in
            MainActor.assumeIsolated { MenuBarAppearance.shared.update(button.effectiveAppearance) }
        }
    }

    private func update(_ appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            .map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
        if dark != isDark { isDark = dark }
    }

    static func statusButton() -> NSButton? {
        for window in NSApp.windows where NSStringFromClass(type(of: window)).contains("StatusBarWindow") {
            if let content = window.contentView, let button = findButton(in: content) { return button }
        }
        return nil
    }

    static func findButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for sub in view.subviews {
            if let button = findButton(in: sub) { return button }
        }
        return nil
    }
}

/// Draws the menu bar label with AppKit.
///
/// Not SwiftUI's `ImageRenderer`: it brings up GPU rendering (RenderBox / Metal) that stays resident, about
/// 30 MB for a 60×18 pt image. AppKit draws the same symbols and text into a plain bitmap.
@MainActor
enum MenuBarIconRenderer {
    private struct Key: Hashable {
        let counts: MenuBarCounts
        let darkMenuBar: Bool
        let themeRevision: Int
    }

    private static var cache: [Key: NSImage] = [:]

    private static let height: CGFloat = 18
    private static let iconSize: CGFloat = 15
    private static let iconTextGap: CGFloat = 3
    private static let groupGap: CGFloat = 8
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

    /// One part of the label: an icon and an optional count.
    private struct Group {
        enum Icon { case spinner, symbol(String, NSColor) }
        let icon: Icon
        let count: Int
    }

    static func image(_ counts: MenuBarCounts, darkMenuBar: Bool, themeRevision: Int) -> NSImage {
        let colored = counts.alert != .none
        // The template variant depends on neither the menu bar color nor the theme.
        let key = Key(counts: counts, darkMenuBar: colored && darkMenuBar, themeRevision: colored ? themeRevision : 0)
        if let image = cache[key] { return image }
        if cache.count > 64 { cache.removeAll() }

        // Template images are drawn in black and recolored by macOS; the colored variant uses the menu bar's
        // own text color.
        let text: NSColor = !colored ? .black : darkMenuBar ? .white : NSColor(white: 0, alpha: 0.85)
        var groups: [Group] = []
        if counts.running > 0 { groups.append(Group(icon: .spinner, count: counts.running)) }
        if counts.others > 0 || counts.running == 0 {
            let symbol = colored
                ? Group.Icon.symbol("bell.badge.fill", alertColor(counts.alert, darkMenuBar: darkMenuBar))
                : Group.Icon.symbol("terminal", text)
            groups.append(Group(icon: symbol, count: counts.others))
        }

        let image = draw(groups, text: text)
        image.isTemplate = !colored
        cache[key] = image
        return image
    }

    private static func draw(_ groups: [Group], text: NSColor) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
        let labels = groups.map { $0.count > 0 ? NSAttributedString(string: "\($0.count)", attributes: attributes) : nil }
        let symbols: [NSImage?] = groups.map { group in
            guard case let .symbol(name, color) = group.icon else { return nil }
            let config = symbolConfig.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        let widths = groups.indices.map { i in
            let icon = symbols[i]?.size.width ?? iconSize
            return icon + (labels[i].map { iconTextGap + ceil($0.size().width) } ?? 0)
        }
        let width = widths.reduce(0, +) + groupGap * CGFloat(max(0, groups.count - 1)) + 2

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 1
            for (i, group) in groups.enumerated() {
                switch group.icon {
                case .spinner:
                    drawSpinner(in: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize), color: text)
                    x += iconSize
                case .symbol:
                    if let symbol = symbols[i] {
                        symbol.draw(in: NSRect(origin: NSPoint(x: x, y: (height - symbol.size.height) / 2), size: symbol.size))
                        x += symbol.size.width
                    }
                }
                if let label = labels[i] {
                    let size = label.size()
                    label.draw(at: NSPoint(x: x + iconTextGap, y: (height - size.height) / 2))
                    x += iconTextGap + ceil(size.width)
                }
                x += groupGap
            }
            return true
        }
    }

    /// The classic macOS activity spinner: eight spokes, the head (top) opaque and the tail fading out
    /// counter-clockwise behind it.
    private static func drawSpinner(in rect: NSRect, color: NSColor) {
        let spokes = 8
        let center = NSPoint(x: rect.midX, y: rect.midY)
        for i in 0..<spokes {
            let behind = (spokes - i) % spokes
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            // Clockwise from the top: AppKit rotates counter-clockwise for positive angles.
            transform.rotate(byDegrees: -CGFloat(i) * 360 / CGFloat(spokes))
            let spoke = NSBezierPath(roundedRect: NSRect(x: -1, y: 2.25, width: 2, height: 4.5), xRadius: 1, yRadius: 1)
            spoke.transform(using: transform as AffineTransform)
            color.withAlphaComponent(color.alphaComponent * max(0.22, 1 - CGFloat(behind) * 0.13)).setFill()
            spoke.fill()
        }
    }

    private static func alertColor(_ alert: MenuBarCounts.Alert, darkMenuBar: Bool) -> NSColor {
        if let themed = ThemeStore.shared.nsColor(alert == .error ? .error : .waiting, dark: darkMenuBar) { return themed }
        return switch alert {
        case .error: darkMenuBar ? .systemRed : NSColor(srgbRed: 0.80, green: 0.16, blue: 0.11, alpha: 1)
        default: darkMenuBar ? .systemOrange : NSColor(srgbRed: 0.85, green: 0.39, blue: 0.0, alpha: 1)
        }
    }
}
