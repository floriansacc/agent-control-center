import AgentCore
import SwiftUI

/// Sidebar of sessions grouped by what they need from you, the selected session's conversation in the
/// middle, its details in the inspector on the right.
struct ControlCenterView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: ControlCenterModel
    @State private var search = ""
    @State private var showInspector = true
    @State private var showIdle = false
    @State private var showPorts = false

    private var selected: Session? {
        model.selection.flatMap { key in app.snapshot.sessions.first { $0.key == key } }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            detail
                .inspector(isPresented: $showInspector) {
                    Group {
                        if let session = selected {
                            SessionInspector(session: session, app: app)
                        } else {
                            Color.clear
                        }
                    }
                    .inspectorColumnWidth(min: 240, ideal: 290, max: 400)
                }
        }
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
        .background { numberShortcuts }
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

    // MARK: - Sidebar

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

    /// The sessions in sidebar order, for ⌘1–9.
    private var ordered: [Session] {
        let g = groups
        return g.needsYou + g.running + g.recent + (showIdle ? g.idle : [])
    }

    private var sidebar: some View {
        let g = groups
        return List(selection: $model.selection) {
            if !app.hookInstalled {
                Section { hookNotice }
            }
            section("Needs you", g.needsYou)
            section("Running", g.running)
            section("Recent", g.recent)
            if !g.idle.isEmpty {
                Section(isExpanded: $showIdle) {
                    ForEach(g.idle) { SidebarRow(session: $0).tag($0.key) }
                } header: {
                    Text("Idle (\(g.idle.count))")
                        .help("Idle for more than \(foldIdleLabel). Change it in the menu bar settings.")
                }
            }
            if !app.snapshot.otherPorts.isEmpty, search.isEmpty {
                Section(isExpanded: $showPorts) {
                    ForEach(app.snapshot.otherPorts) { listener in
                        PortRow(listener: listener, app: app).selectionDisabled()
                    }
                } header: {
                    Text("Other ports (\(app.snapshot.otherPorts.count))")
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Filter sessions")
        .onKeyPress(.return) {
            guard let session = selected else { return .ignored }
            app.focus(session)
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { keys in
            if let key = keys.first, let session = app.snapshot.sessions.first(where: { $0.key == key }) {
                SessionActions(session: session, app: app)
            }
        } primaryAction: { keys in
            // Double-click jumps to the session.
            if let key = keys.first, let session = app.snapshot.sessions.first(where: { $0.key == key }) {
                app.focus(session)
            }
        }
        .overlay {
            if app.snapshot.sessions.isEmpty {
                ContentUnavailableView(
                    "No Claude Code sessions",
                    systemImage: "terminal",
                    description: Text("Start `claude` in a terminal, in VS Code or in the Claude app.")
                )
            } else if !search.isEmpty, ordered.isEmpty, g.idle.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let limits = app.snapshot.rateLimits {
                VStack(spacing: 0) {
                    Divider()
                    PlanUsageRow(limits: limits).padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ sessions: [Session]) -> some View {
        if !sessions.isEmpty {
            Section("\(title) (\(sessions.count))") {
                ForEach(sessions) { SidebarRow(session: $0).tag($0.key) }
            }
        }
    }

    private var hookNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude Code hook not set up", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.orange)
            Text("Sessions show up, but without their status or conversation.").font(.caption)
            Button("Set Up…") { app.setUpHook() }.controlSize(.small)
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }

    private var foldIdleLabel: String {
        AppModel.foldIdleChoices.first { $0.seconds == app.foldIdleAfter }?.label ?? "a while"
    }

    /// ⌘1–⌘9 select the sessions in sidebar order.
    private var numberShortcuts: some View {
        ZStack {
            ForEach(1...9, id: \.self) { n in
                Button("") {
                    let sessions = ordered
                    if n <= sessions.count { model.selection = sessions[n - 1].key }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Detail

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
        var parts = [session.cwd == Scanner.home ? "~" : session.cwd.replacingOccurrences(of: Scanner.home, with: "~")]
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

/// Nothing in the window animates (no pulsing icons, no spinners): an animation redraws the whole window
/// every frame, which took the app from ~1% to ~20% CPU while a session was working.
private struct SidebarRow: View {
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.status.symbol)
                .foregroundStyle(session.status.color)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.displayName).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ago(session.statusSince ?? session.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let line = line {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(session.status == .waiting || session.status == .error ? session.status.color : .secondary)
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
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .help("\(session.cwd)\n\(session.host.label) · \(session.status.label)")
    }

    /// What the session needs, else what it is doing, else what it last said.
    private var line: String? {
        if session.status == .waiting || session.status == .error, let message = session.message { return message }
        return session.activity ?? session.summary
    }
}

private struct PortRow: View {
    let listener: Listener
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text(":\(String(listener.port))").font(.caption.monospaced())
            Text(listener.command).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { app.openPort(listener) } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless)
                .help("Open in browser")
        }
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
