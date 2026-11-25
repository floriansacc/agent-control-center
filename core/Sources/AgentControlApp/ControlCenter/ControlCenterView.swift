import AgentCore
import SwiftUI

/// Sidebar of sessions grouped by what they need from you, the selected session's conversation in the
/// middle, its details in the inspector on the right.
struct ControlCenterView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: ControlCenterModel
    @Environment(\.theme) private var theme
    @State private var search = ""
    @State private var showInspector = true

    private var selected: Session? {
        model.selection.flatMap { key in app.snapshot.sessions.first { $0.key == key } }
    }

    var body: some View {
        NavigationSplitView {
            SessionSidebar(app: app, model: model, search: search)
                .searchable(text: $search, placement: .sidebar, prompt: "Filter sessions")
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { if !theme.isNative { theme.background.ignoresSafeArea() } }
                .inspector(isPresented: $showInspector) {
                    Group {
                        if let session = selected {
                            SessionInspector(session: session, app: app)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { if !theme.isNative { theme.sidebar.ignoresSafeArea() } }
                    // Wide enough to read diffs in the Changes tab when dragged out.
                    .inspectorColumnWidth(min: 240, ideal: 320, max: 900)
                }
        }
        .foregroundStyle(theme.text)
        .navigationTitle(selected?.displayName ?? "Agent Control Center")
        .navigationSubtitle(selected.map(subtitle) ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let session = selected {
                    Button { app.focus(session) } label: {
                        Label(openLabel(session), systemImage: "arrow.up.forward.app")
                    }
                    .help("Jump to this session (Return)")
                    .disabled(session.host == .other && session.itermSessionId == nil)
                }
                Button { app.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh (⌘R)")
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(showInspector ? "Hide details (⌥⌘I)" : "Show details (⌥⌘I)")
            }
        }
        .onAppear {
            app.viewAppeared()
            if model.selection == nil { model.selection = app.snapshot.sessions.first?.key }
            model.sync(with: selected)
        }
        .onDisappear { app.viewDisappeared() }
        .onChange(of: model.selection) { _, _ in model.sync(with: selected) }
        // A hook event (new prompt, tool call, reply) or a newly reported transcript path.
        .onChange(of: selected?.updatedAt) { _, _ in model.sync(with: selected) }
        .onChange(of: selected?.transcriptPath) { _, _ in model.sync(with: selected) }
        .onChange(of: app.snapshot.sessions.isEmpty) { _, empty in
            if !empty, model.selection == nil { model.selection = app.snapshot.sessions.first?.key }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = selected {
            ConversationView(session: session, conversation: model.conversation, app: app)
                .id(session.key)
        } else if model.selection != nil {
            ContentUnavailableView(
                "Session ended",
                systemImage: "checkmark.circle",
                description: Text("This Claude Code session is no longer running.")
            )
        } else {
            ContentUnavailableView("Select a session", systemImage: "sidebar.left")
        }
    }

    private func subtitle(_ session: Session) -> String {
        var parts = [session.cwd.replacingOccurrences(of: Scanner.home, with: "~")]
        if let branch = session.branch { parts.append(branch) }
        return parts.joined(separator: " · ")
    }
}

/// "Open in iTerm", "Open in VS Code", "Open in Claude".
func openLabel(_ session: Session) -> String {
    switch session.host {
    case .iterm: "Open in iTerm"
    case .vscodeTerminal, .vscodePanel: "Open in VS Code"
    case .claudeDesktop: "Open in Claude"
    case .other: "Focus Terminal"
    }
}

/// The session list. Drawn by hand rather than with a `List`: a list's selection always uses the macOS
/// accent color, and the theme's accent should apply. Keyboard: ↑ / ↓, Return to jump, ⌘1–9 (the window).
private struct SessionSidebar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: ControlCenterModel
    let search: String
    @Environment(\.theme) private var theme
    @State private var showIdle = false
    @State private var showPorts = false
    @FocusState private var focused: Bool

    private struct Groups {
        var needsYou: [Session] = []
        var running: [Session] = []
        var recent: [Session] = []
        var idle: [Session] = []
    }

    private var groups: Groups {
        let query = search.trimmingCharacters(in: .whitespaces)
        var groups = Groups()
        let now = Date().timeIntervalSince1970
        for s in app.snapshot.sessions where query.isEmpty || matches(s, query) {
            switch s.status {
            case .waiting, .error: groups.needsYou.append(s)
            case .working: groups.running.append(s)
            default:
                if app.foldIdleAfter > 0, s.isIdle(longerThan: app.foldIdleAfter, now: now) {
                    groups.idle.append(s)
                } else {
                    groups.recent.append(s)
                }
            }
        }
        return groups
    }

    private func matches(_ s: Session, _ query: String) -> Bool {
        [s.displayName, s.project, s.cwd, s.branch, s.lastPrompt, s.lastResponse, s.customTitle, s.aiTitle]
            .contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    /// The sessions in the order shown (folded ones left out), for the keyboard.
    private func ordered(_ g: Groups) -> [Session] {
        g.needsYou + g.running + g.recent + (showIdle ? g.idle : [])
    }

    var body: some View {
        let g = groups
        let sessions = ordered(g)
        ScrollViewReader { proxy in
            ColumnScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !app.hookInstalled { hookNotice }
                    section("Needs you", g.needsYou)
                    section("Running", g.running)
                    section("Recent", g.recent)
                    if !g.idle.isEmpty {
                        FoldingHeader(title: "Idle", count: g.idle.count, isExpanded: $showIdle)
                            .help("Idle for more than \(foldIdleLabel). Change it in Settings.")
                        if showIdle { rows(g.idle) }
                    }
                    if !app.snapshot.otherPorts.isEmpty, search.isEmpty {
                        FoldingHeader(title: "Other ports", count: app.snapshot.otherPorts.count, isExpanded: $showPorts)
                        if showPorts {
                            ForEach(app.snapshot.otherPorts) { PortRow(listener: $0, app: app) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, in: sessions, proxy) }
            .onKeyPress(.downArrow) { move(1, in: sessions, proxy) }
            .onKeyPress(.return) {
                guard let session = sessions.first(where: { $0.key == model.selection }) else { return .ignored }
                app.focus(session)
                return .handled
            }
            // ⌘1–9 (handled by the window) pick from this order.
            .onChange(of: sessions.map(\.key), initial: true) { _, keys in model.orderedKeys = keys }
        }
        .foregroundStyle(theme.text)
        .background { if !theme.isNative { theme.sidebar.ignoresSafeArea() } }
        .overlay {
            if app.snapshot.sessions.isEmpty {
                ContentUnavailableView(
                    "No Claude Code sessions",
                    systemImage: "terminal",
                    description: Text("Start `claude` in a terminal, in VS Code or in the Claude app.")
                )
            } else if !search.isEmpty, sessions.isEmpty, g.idle.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                theme.border.frame(height: 1)
                if let limits = app.snapshot.rateLimits {
                    PlanUsageRow(limits: limits).padding(.top, 8)
                }
                SettingsButton()
            }
            .background { if !theme.isNative { theme.sidebar.ignoresSafeArea() } }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ sessions: [Session]) -> some View {
        if !sessions.isEmpty {
            SectionHeader(title: title, count: sessions.count)
            rows(sessions)
        }
    }

    private func rows(_ sessions: [Session]) -> some View {
        ForEach(sessions) { session in
            SidebarRow(session: session, selected: session.key == model.selection)
                .id(session.key)
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { app.focus(session) })
                .simultaneousGesture(TapGesture().onEnded {
                    model.selection = session.key
                    focused = true
                })
                .contextMenu { SessionActions(session: session, app: app) }
        }
    }

    private func move(_ step: Int, in sessions: [Session], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !sessions.isEmpty else { return .ignored }
        let current = sessions.firstIndex { $0.key == model.selection }
        let next = current.map { min(max($0 + step, 0), sessions.count - 1) } ?? 0
        model.selection = sessions[next].key
        proxy.scrollTo(sessions[next].key)
        return .handled
    }

    private var hookNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude Code hook not set up", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(theme.waiting)
            Text("Sessions show up, but without their status or conversation.")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Button("Set Up…") { app.setUpHook() }.controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.waiting.opacity(0.12)))
        .padding(.vertical, 4)
    }

    private var foldIdleLabel: String {
        AppModel.foldIdleChoices.first { $0.seconds == app.foldIdleAfter }?.label ?? "a while"
    }

}

/// "Settings" at the foot of the sidebar.
private struct SettingsButton: View {
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { SettingsWindow.shared.show() } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").frame(width: 16)
                Text("Settings")
                Spacer()
                Text("⌘,").font(.caption).foregroundStyle(theme.textFaint)
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.text.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text("\(count)").monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(theme.textFaint)
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

private struct FoldingHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
                Text("\(count)").monospacedDigit()
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(hovering ? theme.textSecondary : theme.textFaint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.text.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 7)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

/// Nothing in the window animates (no pulsing icons, no spinners): an animation redraws the whole window
/// every frame, which took the app from ~1% to ~20% CPU while a session was working.
private struct SidebarRow: View {
    let session: Session
    let selected: Bool
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        // On the accent-colored selection, everything takes the accent's text color.
        let onAccent = selected ? theme.accentForeground : nil
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.status.symbol)
                .foregroundStyle(onAccent ?? theme.status(session.status))
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.displayName).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ago(session.statusSince ?? session.updatedAt))
                        .font(.caption)
                        .foregroundStyle(onAccent?.opacity(0.8) ?? theme.textSecondary)
                        .monospacedDigit()
                }
                if let line {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(onAccent?.opacity(0.9) ?? lineColor)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Image(systemName: session.host.symbol)
                    if session.displayName != session.project {
                        Text(session.folderLabel).lineLimit(1)
                    }
                    if let branch = session.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(onAccent?.opacity(0.75) ?? theme.textFaint)
            }
        }
        .foregroundStyle(onAccent ?? theme.text)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? theme.accent : hovering ? theme.text.opacity(0.06) : .clear)
        )
        .onHover { hovering = $0 }
        .help("\(session.cwd)\n\(session.host.label) · \(session.status.label)")
    }

    /// What the session needs, else what it is doing, else what it last said.
    private var line: String? {
        if session.status == .waiting || session.status == .error, let message = session.message { return message }
        return session.activity ?? session.summary
    }

    private var lineColor: Color {
        session.status == .waiting || session.status == .error ? theme.status(session.status) : theme.textSecondary
    }
}

private struct PortRow: View {
    let listener: Listener
    @ObservedObject var app: AppModel
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(":\(String(listener.port))").font(.caption.monospaced())
            Text(listener.command).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(1)
            Spacer()
            Button { app.openPort(listener) } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless)
                .help("Open in browser")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.text.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.openPort(listener) }
        .help("\(listener.command) · pid \(listener.pid)\nClick to open in the browser")
        .contextMenu {
            Button("Open in Browser") { app.openPort(listener) }
            Button("Stop \(listener.command)…") { app.stop(listener) }
        }
    }
}

/// The actions on a session, shared by the sidebar's context menu and the inspector.
struct SessionActions: View {
    let session: Session
    @ObservedObject var app: AppModel

    var body: some View {
        Button(openLabel(session)) { app.focus(session) }
        Button("Open Folder in VS Code") { app.openFolder(session) }
        Button("Reveal in Finder") { app.revealInFinder(session) }
        Divider()
        Button("Copy Path") { app.copyPath(session) }
        if session.sessionId != nil {
            Button("Copy Resume Command") { app.copyResumeCommand(session) }
        }
        if session.pid != nil {
            Divider()
            Button("Stop Session…") { app.stop(session) }
        }
    }
}
