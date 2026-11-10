import AgentCore
import SwiftUI

extension SessionStatus {
    var color: Color {
        switch self {
        case .waiting: .orange
        case .error: .red
        case .working: .blue
        case .done: .green
        case .idle, .untracked: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "bell.badge.fill"
        case .error: "exclamationmark.octagon.fill"
        case .working: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .untracked: "questionmark.circle"
        }
    }
}

extension SessionHost {
    var symbol: String {
        switch self {
        case .iterm, .other: "terminal"
        case .vscodeTerminal: "chevron.left.forwardslash.chevron.right"
        case .vscodePanel: "sidebar.right"
        }
    }
}

func ago(_ sec: Double?) -> String {
    guard let sec else { return "" }
    let d = max(0, Int(Date().timeIntervalSince1970 - sec))
    switch d {
    case ..<60: return "\(d)s"
    case ..<3600: return "\(d / 60)m"
    case ..<86400: return "\(d / 3600)h"
    default: return "\(d / 86400)d"
    }
}

struct SessionListView: View {
    enum Style { case menu, panel }

    @ObservedObject var model: AppModel
    let style: Style
    @State private var showOtherPorts = false
    @State private var contentHeight: CGFloat = 0
    /// Class, not @State value: updating it must not trigger a re-render.
    @State private var windowFitter = MenuWindowFitter()

    private static let menuWidth: CGFloat = 420
    private static let menuMaxHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if style == .menu {
                // Menu windows have no height to fill: size to content, scroll past the cap.
                ScrollView { content.background(heightReader) }
                    .frame(height: min(max(contentHeight, 60), Self.menuMaxHeight))
            } else {
                ScrollView { content }
            }
        }
        // The menu window sizes itself from the outermost frame, so the fixed width must be last:
        // an outer min-width frame made the window 300pt wide and clipped the 400pt content.
        .frame(
            minWidth: style == .menu ? Self.menuWidth : 300,
            maxWidth: style == .menu ? Self.menuWidth : .infinity,
            maxHeight: style == .menu ? nil : .infinity
        )
        .background {
            if style == .menu {
                // Measures the content's own height (before the top-pinning frame below stretches it).
                GeometryReader { geo in
                    WindowReader { windowFitter.attach($0) }
                        .onAppear { windowFitter.update(height: geo.size.height) }
                        .onChange(of: geo.size.height) { _, h in windowFitter.update(height: h) }
                }
            }
        }
        // While the window catches up after the content shrinks, keep the content pinned to the top:
        // the window centres it otherwise, which made it jump down and back up (flicker).
        .frame(maxHeight: style == .menu ? .infinity : nil, alignment: .top)
        // Animated height changes make the window resize lag behind the content; snap instead.
        .transaction { if style == .menu { $0.animation = nil } }
        .onAppear { model.viewAppeared() }
        .onDisappear { model.viewDisappeared() }
    }

    private var heightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { contentHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in contentHeight = h }
        }
    }

    private var header: some View {
        let sessions = model.snapshot.sessions
        let working = sessions.filter { $0.status == .working }.count
        let waiting = sessions.filter { $0.status == .waiting }.count
        return HStack(spacing: 8) {
            if style == .menu {
                Text("Agents").font(.headline)
            }
            if working > 0 { CountBadge(count: working, label: "working", color: .blue) }
            if waiting > 0 { CountBadge(count: waiting, label: "need input", color: .orange) }
            Spacer()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
            if style == .menu {
                Button { model.togglePanel() } label: {
                    Image(systemName: model.panelVisible ? "pip.exit" : "pip.enter")
                }
                .buttonStyle(.borderless)
                .help(model.panelVisible ? "Close floating panel" : "Detach as floating panel")
            }
            Menu {
                Toggle("Notify when input is needed", isOn: $model.notifyOnWaiting)
                Toggle("Notify when a session finishes", isOn: $model.notifyOnDone)
                if model.isBundled {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                Divider()
                Button("Quit Agent Control Center") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.snapshot.sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
                    Text("No Claude Code sessions running")
                    Text("Start `claude` in any terminal or in VS Code.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            ForEach(model.snapshot.sessions) { session in
                SessionRow(session: session, model: model)
            }
            if !model.snapshot.otherPorts.isEmpty {
                Divider().padding(.vertical, 4)
                DisclosureGroup(isExpanded: $showOtherPorts) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.snapshot.otherPorts) { listener in
                            OtherPortRow(listener: listener, model: model)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Other ports (\(model.snapshot.otherPorts.count))").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(8)
    }
}

private struct CountBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        Text("\(count) \(label)")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct SessionRow: View {
    let session: Session
    @ObservedObject var model: AppModel
    @State private var hovering = false

    private static let maxChips = 5

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.status.symbol)
                .foregroundStyle(session.status.color)
                .symbolEffect(.pulse, isActive: session.status == .working)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.project).fontWeight(.semibold).lineLimit(1)
                    if let branch = session.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(session.status.color)
                        .lineLimit(1)
                        .fixedSize()
                }
                if session.status == .waiting, let message = session.message {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if let summary = session.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
                }
                HStack(spacing: 4) {
                    Label(session.host.label, systemImage: session.host.symbol)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(session.ports.prefix(Self.maxChips)) { listener in
                        PortChip(listener: listener, model: model)
                    }
                    if session.ports.count > Self.maxChips {
                        Text("+\(session.ports.count - Self.maxChips)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.focus(session) }
        .contextMenu {
            Button("Focus Terminal") { model.focus(session) }
            Button("Open Folder in VS Code") { model.openFolder(session) }
            Button("Copy Path") { model.copyPath(session) }
            if session.pid != nil {
                Divider()
                Button("Stop Session…") { model.stop(session) }
            }
        }
        .help(tooltip)
    }

    private var statusText: String {
        session.statusSince != nil ? "\(session.status.label) \(ago(session.statusSince))" : session.status.label
    }

    private var tooltip: String {
        var lines = [session.cwd]
        if let tty = session.tty, tty != "??" { lines.append("\(session.host.label) · \(tty)") }
        if let pid = session.pid { lines.append("pid \(pid)") }
        if let prompt = session.lastPrompt { lines.append("You: \(prompt)") }
        if let response = session.lastResponse { lines.append("Claude: \(response)") }
        if session.status == .working, let tool = session.lastTool { lines.append("last tool: \(tool)") }
        if session.status == .untracked { lines.append("Started before the status hook was installed.") }
        lines.append("Click to jump to this session.")
        return lines.joined(separator: "\n")
    }
}

private struct PortChip: View {
    let listener: Listener
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.openPort(listener) } label: {
            Text(":\(String(listener.port))")
                .font(.caption2.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.blue.opacity(listener.viaCwd == true ? 0.08 : 0.18)))
        }
        .buttonStyle(.plain)
        .help("\(listener.command) · pid \(listener.pid)\(listener.viaCwd == true ? " · same folder" : "")\nClick to open in browser")
        .contextMenu {
            Button("Open in Browser") { model.openPort(listener) }
            Button("Stop \(listener.command)…") { model.stop(listener) }
        }
    }
}

private struct OtherPortRow: View {
    let listener: Listener
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text(":\(String(listener.port))").font(.caption.monospaced()).frame(width: 52, alignment: .leading)
            Text(listener.command).font(.caption).lineLimit(1)
            Spacer()
            Text("pid \(listener.pid)").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openPort(listener) }
        .help("Click to open in browser")
        .contextMenu {
            Button("Open in Browser") { model.openPort(listener) }
            Button("Stop \(listener.command)…") { model.stop(listener) }
        }
    }
}
