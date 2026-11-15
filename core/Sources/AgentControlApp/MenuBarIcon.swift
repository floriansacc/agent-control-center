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

    var body: some View {
        let counts = MenuBarCounts(model.snapshot.sessions)
        Image(nsImage: MenuBarIconRenderer.image(counts, darkMenuBar: menuBar.isDark))
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

@MainActor
enum MenuBarIconRenderer {
    private struct Key: Hashable {
        let counts: MenuBarCounts
        let darkMenuBar: Bool
    }

    private static var cache: [Key: NSImage] = [:]

    static func image(_ counts: MenuBarCounts, darkMenuBar: Bool) -> NSImage {
        let colored = counts.alert != .none
        // The template variant does not depend on the menu bar color.
        let key = Key(counts: counts, darkMenuBar: colored && darkMenuBar)
        if let image = cache[key] { return image }
        if cache.count > 64 { cache.removeAll() }

        let palette = colored
            ? MenuBarIconContent.Colors(
                text: darkMenuBar ? .white : Color(white: 0, opacity: 0.85),
                alert: alertColor(counts.alert, darkMenuBar: darkMenuBar)
            )
            : MenuBarIconContent.Colors(text: .black, alert: .black)
        let renderer = ImageRenderer(content: MenuBarIconContent(counts: counts, colors: palette))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = !colored
        cache[key] = image
        return image
    }

    private static func alertColor(_ alert: MenuBarCounts.Alert, darkMenuBar: Bool) -> Color {
        switch alert {
        case .error: Color(nsColor: darkMenuBar ? .systemRed : NSColor(srgbRed: 0.80, green: 0.16, blue: 0.11, alpha: 1))
        default: Color(nsColor: darkMenuBar ? .systemOrange : NSColor(srgbRed: 0.85, green: 0.39, blue: 0.0, alpha: 1))
        }
    }
}

private struct MenuBarIconContent: View {
    struct Colors {
        let text: Color
        let alert: Color
    }

    let counts: MenuBarCounts
    let colors: Colors

    private let font = Font.system(size: 13, weight: .medium)

    var body: some View {
        HStack(spacing: 8) {
            if counts.running > 0 {
                group(count: counts.running) { SpinnerShape() }
            }
            if counts.others > 0 || counts.running == 0 {
                group(count: counts.others) {
                    if counts.alert == .none {
                        Image(systemName: "terminal").font(font)
                    } else {
                        Image(systemName: "bell.badge.fill").font(font).foregroundStyle(colors.alert)
                    }
                }
            }
        }
        .foregroundStyle(colors.text)
        .padding(.horizontal, 1)
        .frame(height: 18)
    }

    private func group(count: Int, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 3) {
            icon()
            if count > 0 { Text("\(count)").font(font).monospacedDigit() }
        }
    }
}

/// The classic macOS activity spinner: eight spokes, the head opaque and the tail fading out.
private struct SpinnerShape: View {
    private static let spokes = 8

    var body: some View {
        ZStack {
            ForEach(0..<Self.spokes, id: \.self) { i in
                // Spoke 0 (top) is the head; the tail fades counter-clockwise behind it.
                let behind = (Self.spokes - i) % Self.spokes
                Capsule()
                    .frame(width: 2, height: 4.5)
                    .offset(y: -4.5)
                    .rotationEffect(.degrees(Double(i) * 360 / Double(Self.spokes)))
                    .opacity(max(0.22, 1 - Double(behind) * 0.13))
            }
        }
        .frame(width: 15, height: 15)
    }
}
