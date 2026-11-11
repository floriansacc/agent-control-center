import AgentCore
import AppKit
import SwiftUI

/// Menu bar label: a spinner with the number of running sessions, then a terminal (or a bell when
/// one needs input) with the number of the other ones.
///
/// `MenuBarExtra` only shows one image and one text from its label, so the whole label is drawn into a
/// single template image (black + alpha, recolored by macOS for light / dark menu bars).
///
/// The spinner is deliberately still: every image change makes AppKit re-snapshot the status item for
/// each display, which costs ~2% CPU per frame per second (~9% at 4 fps) for as long as an agent runs.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let counts = MenuBarCounts(model.snapshot.sessions)
        Image(nsImage: MenuBarIconRenderer.image(counts))
            .accessibilityLabel(counts.accessibilityLabel)
    }
}

struct MenuBarCounts: Hashable {
    var running = 0
    var others = 0
    var needsAttention = false

    init(_ sessions: [Session]) {
        for s in sessions {
            if s.status == .working {
                running += 1
            } else {
                others += 1
                if s.status == .waiting || s.status == .error { needsAttention = true }
            }
        }
    }

    var accessibilityLabel: String {
        if running == 0, others == 0 { return "Agent Control Center: no Claude sessions" }
        let rest = needsAttention ? "\(others) other, some need input" : "\(others) idle or finished"
        return "Agent Control Center: \(running) running, \(rest)"
    }
}

@MainActor
enum MenuBarIconRenderer {
    private static var cache: [MenuBarCounts: NSImage] = [:]

    static func image(_ counts: MenuBarCounts) -> NSImage {
        if let image = cache[counts] { return image }
        if cache.count > 64 { cache.removeAll() }

        let renderer = ImageRenderer(content: MenuBarIconContent(counts: counts))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        cache[counts] = image
        return image
    }
}

private struct MenuBarIconContent: View {
    let counts: MenuBarCounts

    private let font = Font.system(size: 13, weight: .medium)

    var body: some View {
        HStack(spacing: 8) {
            if counts.running > 0 {
                group(count: counts.running) { SpinnerShape() }
            }
            if counts.others > 0 || counts.running == 0 {
                group(count: counts.others) {
                    Image(systemName: counts.needsAttention ? "bell.badge.fill" : "terminal").font(font)
                }
            }
        }
        .foregroundStyle(.black)
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
