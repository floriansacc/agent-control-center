import AgentCore
import SwiftUI

extension SessionStatus {
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

/// SF Symbol for a Claude Code tool.
func toolSymbol(_ tool: String) -> String {
    switch tool {
    case "Bash": "terminal"
    case "Read": "doc.text"
    case "Edit", "MultiEdit", "Write", "NotebookEdit": "pencil"
    case "Grep", "Glob": "magnifyingglass"
    case "WebFetch", "WebSearch": "globe"
    case "Task", "Agent": "person.2"
    case "TodoWrite": "checklist"
    default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "gearshape"
    }
}

extension SessionHost {
    var symbol: String {
        switch self {
        case .iterm, .other: "terminal"
        case .vscodeTerminal: "chevron.left.forwardslash.chevron.right"
        case .vscodePanel: "sidebar.right"
        case .claudeDesktop: "macwindow"
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

/// The menu bar dropdown.
struct SessionListView: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme
    @State private var showOtherPorts = false
    @State private var showIdle = false
    @State private var contentHeight: CGFloat = 0
    /// Class, not @State value: updating it must not trigger a re-render.
    @State private var windowFitter = MenuWindowFitter()

    private static let menuWidth: CGFloat = 420
    private static let menuMaxHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            header
            if let limits = model.snapshot.rateLimits {
                PlanUsageRow(limits: limits)
            }
            Divider()
            // Menu windows have no height to fill: size to content, scroll past the cap.
            ScrollView { content.background(heightReader) }
                .frame(height: min(max(contentHeight, 60), Self.menuMaxHeight))
        }
        // The menu window sizes itself from the outermost frame, so the fixed width must be last:
        // an outer min-width frame made the window 300pt wide and clipped the 400pt content.
        .frame(width: Self.menuWidth)
        // Sized to the content during layout; resizes the menu window before the frame is drawn.
        .background { MenuSizeTracker(fitter: windowFitter) }
        // The menu view has a fixed height (no `maxHeight: .infinity`): SwiftUI then shrinks the window to it
        // in the same layout pass, before drawing, as it already does when growing. With a flexible height it
        // left shrinking to MenuWindowFitter, a frame late: the panel was drawn at the bottom of the
        // still-tall window for one frame (flicker).
        .background { MenuBackdrop() }
        // Animated height changes make the window resize lag behind the content; snap instead.
        // Last, so it also covers the backdrop: an animated backdrop under snapping content flickered.
        .transaction { $0.animation = nil }
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
            Text("Agents").font(.headline)
            if working > 0 { CountBadge(count: working, label: "working", color: theme.working) }
            if waiting > 0 { CountBadge(count: waiting, label: "need input", color: theme.waiting) }
            Spacer()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
            Button { model.openControlCenter() } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open Control Center")
            Menu {
                Toggle("Notify when input is needed", isOn: $model.notifyOnWaiting)
                Toggle("Notify when a session finishes", isOn: $model.notifyOnDone)
                Picker("Fold idle sessions after", selection: $model.foldIdleAfter) {
                    ForEach(AppModel.foldIdleChoices, id: \.seconds) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                if model.isBundled {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                Divider()
                Button("Settings…") { SettingsWindow.shared.show() }
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

    private var foldIdleLabel: String {
        AppModel.foldIdleChoices.first { $0.seconds == model.foldIdleAfter }?.label ?? "a while"
    }

    private var hookBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.waiting)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code hook not set up").font(.callout.weight(.semibold))
                Text("Sessions show up, but without their status, prompt or reply.")
                    .font(.caption)
                    .foregroundStyle(Palette.textBody)
            }
            Spacer(minLength: 4)
            Button("Set Up") { model.setUpHook() }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.waiting.opacity(0.12)))
        .padding(.bottom, 4)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.hookInstalled { hookBanner }
            if model.snapshot.sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "terminal").font(.title2).foregroundStyle(Palette.textMeta)
                    Text("No Claude Code sessions running")
                    Text("Start `claude` in any terminal or in VS Code.").font(.caption).foregroundStyle(Palette.textMeta)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            let sessions = model.visibleAndIdleSessions
            ForEach(sessions.visible) { session in
                SessionRow(session: session, model: model)
            }
            if !sessions.idle.isEmpty {
                Divider().padding(.vertical, 4)
                FoldingSection(title: "Idle (\(sessions.idle.count))", isExpanded: $showIdle) {
                    ForEach(sessions.idle) { session in
                        SessionRow(session: session, model: model)
                    }
                }
                .help("Sessions idle for more than \(foldIdleLabel). Change it in ⚙.")
            }
            if !model.snapshot.otherPorts.isEmpty {
                Divider().padding(.vertical, 4)
                FoldingSection(title: "Other ports (\(model.snapshot.otherPorts.count))", isExpanded: $showOtherPorts) {
                    ForEach(model.snapshot.otherPorts) { listener in
                        OtherPortRow(listener: listener, model: model)
                            // Lines up with the section title (header padding + chevron + spacing).
                            .padding(.leading, 26)
                            .padding(.trailing, 8)
                            .padding(.vertical, 1)
                    }
                }
            }
        }
        .padding(8)
    }
}

/// A collapsible section whose whole header row toggles it (a DisclosureGroup only reacts to its arrow).
private struct FoldingSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Text(title).font(.caption)
                Spacer()
            }
            .foregroundStyle(Palette.textMeta)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // No animation: the menu window resizes to the content and must not lag behind it.
            .onTapGesture { isExpanded.toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) { content() }
            }
        }
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
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private static let maxChips = 5

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.status.symbol)
                .foregroundStyle(theme.status(session.status))
                .symbolEffect(.pulse, isActive: session.status == .working)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayName).fontWeight(.semibold).lineLimit(1)
                    if session.displayName != session.project {
                        Label(session.folderLabel, systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(Palette.textMeta)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    if let branch = session.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(Palette.textMeta)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(theme.status(session.status))
                        .lineLimit(1)
                        .fixedSize()
                }
                if session.status == .waiting, let message = session.message {
                    Text(message).font(.caption).foregroundStyle(theme.waiting).lineLimit(2)
                }
                if let summary = session.summary {
                    Text(summary).font(.caption).foregroundStyle(Palette.textBody).lineLimit(2).truncationMode(.tail)
                }
                if let activity = session.activity, let tool = session.lastTool {
                    HStack(spacing: 4) {
                        Image(systemName: toolSymbol(tool))
                            .font(.caption2)
                            .foregroundStyle(theme.status(session.status))
                            .frame(width: 12)
                        Text(activity)
                            .font(.caption)
                            .foregroundStyle(Palette.textMeta)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if session.model != nil || session.contextTokens != nil || session.git != nil {
                    // Set apart from the prompt / reply above: these lines describe the session, not the turn.
                    VStack(alignment: .leading, spacing: 3) {
                        if session.model != nil || session.contextTokens != nil {
                            ContextLine(session: session)
                        }
                        if let git = session.git {
                            GitLine(git: git)
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack(spacing: 4) {
                    Label(session.host.label, systemImage: session.host.symbol)
                        .font(.caption2)
                        .foregroundStyle(Palette.textFaint)
                    ForEach(session.ports.prefix(Self.maxChips)) { listener in
                        PortChip(listener: listener, model: model)
                    }
                    if session.ports.count > Self.maxChips {
                        Text("+\(session.ports.count - Self.maxChips)").font(.caption2).foregroundStyle(Palette.textMeta)
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
            Button("Show in Control Center") { model.openControlCenter(session) }
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
        if let title = session.customTitle ?? session.aiTitle, title != session.displayName { lines.append("Title: \(title)") }
        if let tty = session.tty, tty != "??" { lines.append("\(session.host.label) · \(tty)") }
        if let pid = session.pid { lines.append("pid \(pid)") }
        if let prompt = session.lastPrompt { lines.append("You: \(prompt)") }
        if let response = session.lastResponse { lines.append("Claude: \(response)") }
        if let activity = session.activity { lines.append("Now: \(activity)") }
        if session.status == .untracked { lines.append("Started before the status hook was installed.") }
        lines.append("Click to jump to this session.")
        return lines.joined(separator: "\n")
    }
}

private struct PortChip: View {
    let listener: Listener
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        Button { model.openPort(listener) } label: {
            Text(":\(String(listener.port))")
                .font(.caption2.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(theme.isNative ? Palette.chipText : theme.accent)
                .background(Capsule().fill(
                    theme.isNative
                        ? Palette.chipFill(sameFolder: listener.viaCwd == true)
                        : theme.accent.opacity(listener.viaCwd == true ? 0.08 : 0.15)
                ))
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
            Text("pid \(listener.pid)").font(.caption2).foregroundStyle(Palette.textFaint)
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
