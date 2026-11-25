import AgentCore
import SwiftUI

/// The selected session's panel, in two tabs. Details: status, model and context, git, ports, where it runs,
/// and the actions on it. Changes: its changed files and the selected one's diff.
struct SessionInspector: View {
    enum Tab: Hashable { case details, changes }

    @Environment(\.theme) private var theme
    let session: Session
    @ObservedObject var app: AppModel
    @State private var tab = Tab.details
    /// The file whose diff the Changes tab shows.
    @State private var selectedFile: DiffTarget?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                Text("Details").tag(Tab.details)
                Text(changesTitle).tag(Tab.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            switch tab {
            case .details:
                ColumnScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusSection
                        if session.model != nil || session.contextTokens != nil { modelSection }
                        if session.branch != nil || session.git != nil { gitSection }
                        if !session.ports.isEmpty { portsSection }
                        sessionSection
                        actions
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .changes:
                ChangesTab(session: session, selection: $selectedFile)
            }
        }
        // Another session: its own files.
        .onChange(of: session.key) { _, _ in selectedFile = nil }
    }

    private var changesTitle: String {
        let count = (session.git?.stagedCount ?? 0) + (session.git?.changedCount ?? 0)
        return count > 0 ? "Changes \(count)" : "Changes"
    }

    /// From the Details tab's Git section: that file's diff in the Changes tab.
    private func showDiff(_ path: String, staged: Bool) {
        selectedFile = DiffTarget(dir: session.cwd, path: path, staged: staged)
        tab = .changes
    }

    // MARK: - Sections

    private var statusSection: some View {
        InspectorSection("Status") {
            HStack(spacing: 6) {
                Image(systemName: session.status.symbol).foregroundStyle(theme.status(session.status))
                Text(session.status.label.capitalized(with: nil)).fontWeight(.medium)
                if let since = session.statusSince {
                    Text("for \(ago(since))").foregroundStyle(theme.textSecondary)
                }
            }
            if let activity = session.activity {
                Text(activity).font(.callout).foregroundStyle(theme.textSecondary).lineLimit(3)
            }
        }
    }

    private var modelSection: some View {
        InspectorSection("Model") {
            HStack(spacing: 6) {
                if let model = session.model { Text(model).fontWeight(.medium) }
                if let effort = session.effort {
                    Text(effort)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.card))
                        .help("Reasoning effort")
                }
            }
            if let tokens = session.contextTokens {
                if let percent = session.contextPercent, let size = session.contextSize {
                    HStack(spacing: 8) {
                        UsageBar(percent: percent, width: 120)
                        Text("\(Int(percent.rounded()))%").foregroundStyle(theme.usage(percent)).monospacedDigit()
                    }
                    Text("\(tokens.formatted()) of \(size.formatted()) tokens in context")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    Text("\(tokens.formatted()) tokens in context").font(.caption).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var gitSection: some View {
        InspectorSection("Git") {
            if let branch = session.branch {
                HStack(spacing: 8) {
                    Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                    if let ahead = session.git?.ahead, ahead > 0 {
                        Label("\(ahead)", systemImage: "arrow.up").help("\(ahead) to push")
                    }
                    if let behind = session.git?.behind, behind > 0 {
                        Label("\(behind)", systemImage: "arrow.down").help("\(behind) to pull")
                    }
                }
                .labelStyle(.titleAndIcon)
            }
            if let git = session.git {
                if git.isClean {
                    Text("No changes").font(.callout).foregroundStyle(theme.textSecondary)
                }
                FileList(title: "Staged", color: theme.done, paths: git.staged, total: git.stagedCount) {
                    showDiff($0, staged: true)
                }
                FileList(title: "Changes", color: theme.waiting, paths: git.changed, total: git.changedCount) {
                    showDiff($0, staged: false)
                }
            }
        }
    }

    private var portsSection: some View {
        InspectorSection("Ports") {
            ForEach(session.ports) { listener in
                HStack(spacing: 6) {
                    Button(":\(String(listener.port))") { app.openPort(listener) }
                        .buttonStyle(.link)
                        .font(.callout.monospaced())
                        .help("Open in browser")
                    Text(listener.command).foregroundStyle(theme.textSecondary).lineLimit(1)
                    Spacer()
                    Text("pid \(String(listener.pid))").font(.caption).foregroundStyle(theme.textFaint)
                }
                .contextMenu {
                    Button("Open in Browser") { app.openPort(listener) }
                    Button("Stop \(listener.command)…") { app.stop(listener) }
                }
            }
        }
    }

    private var sessionSection: some View {
        InspectorSection("Session") {
            Field("Runs in") { Label(session.host.label, systemImage: session.host.symbol) }
            Field("Folder") {
                Text(session.cwd.replacingOccurrences(of: Scanner.home, with: "~"))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let title = session.customTitle ?? session.aiTitle, title != session.displayName {
                Field("Title") { Text(title).lineLimit(2) }
            }
            if let started = session.startedAt {
                Field("Started") { Text("\(ago(started)) ago") }
            }
            if let pid = session.pid {
                Field("Process") {
                    Text("pid \(String(pid))" + (session.tty.map { $0 == "??" ? "" : " · \($0)" } ?? ""))
                        .textSelection(.enabled)
                }
            }
            if let id = session.sessionId {
                Field("Session ID") {
                    Text(id).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { app.focus(session) } label: {
                Label(openLabel(session), systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(theme.isNative ? .white : theme.accentForeground)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            HStack(spacing: 8) {
                Button("VS Code") { app.openFolder(session) }.help("Open the folder in VS Code")
                Button("Finder") { app.revealInFinder(session) }.help("Reveal the folder in Finder")
                if session.sessionId != nil {
                    Button("Resume…") { app.copyResumeCommand(session) }
                        .help("Copy `claude --resume` for this session")
                }
            }
            .frame(maxWidth: .infinity)
            if session.pid != nil {
                Button("Stop Session…", role: .destructive) { app.stop(session) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.error)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.textSecondary)
            content()
        }
    }
}

private struct Field<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(theme.textFaint)
            content().font(.callout)
        }
    }
}

/// "Staged (3)" and its paths, folded past a few.
private struct FileList: View {
    @Environment(\.theme) private var theme
    let title: String
    let color: Color
    let paths: [String]
    let total: Int
    /// Opens a path's diff.
    let open: (String) -> Void
    @State private var showAll = false

    private static let shown = 8

    var body: some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) (\(total))").font(.callout.weight(.medium)).foregroundStyle(color)
                ForEach(showAll ? paths : Array(paths.prefix(Self.shown)), id: \.self) { path in
                    FileRow(path: path) { open(path) }
                }
                if paths.count > Self.shown {
                    Button(showAll ? "Show less" : "Show all") { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if total > paths.count, showAll || paths.count <= Self.shown {
                    Text("… and \(total - paths.count) more").font(.caption).foregroundStyle(theme.textFaint)
                }
            }
        }
    }
}

/// A changed file: click to see its diff.
private struct FileRow: View {
    let path: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? theme.text.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(path)\nClick to see the diff")
    }
}

/// The Changes tab: the changed files, staged first, and the selected one's diff below.
private struct ChangesTab: View {
    let session: Session
    @Binding var selection: DiffTarget?
    @Environment(\.theme) private var theme

    private static let rowHeight: CGFloat = 20
    private static let maxListHeight: CGFloat = 220

    var body: some View {
        if let git = session.git, !git.isClean {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        group("Staged", git.staged, total: git.stagedCount, staged: true, color: theme.done)
                        group("Changes", git.changed, total: git.changedCount, staged: false, color: theme.waiting)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(height: listHeight(git))
                theme.border.frame(height: 1)
                if let selection {
                    DiffView(target: selection, reloadKey: git.hashValue)
                } else {
                    ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass")
                }
            }
            .onAppear { if selection == nil { selection = first(git) } }
        } else {
            ContentUnavailableView(
                "No changes",
                systemImage: "checkmark.circle",
                description: Text(session.git == nil ? "This folder is not in a git repository." : "The working tree is clean.")
            )
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ paths: [String], total: Int, staged: Bool, color: Color) -> some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(title) \(total)").font(.caption.weight(.semibold)).foregroundStyle(color).padding(.bottom, 2)
                ForEach(paths, id: \.self) { path in
                    let target = DiffTarget(dir: session.cwd, path: path, staged: staged)
                    ChangeRow(path: path, selected: selection == target) { selection = target }
                }
                if total > paths.count {
                    Text("… and \(total - paths.count) more").font(.caption).foregroundStyle(theme.textFaint)
                }
            }
        }
    }

    /// Fits the files, up to a cap that leaves most of the height to the diff.
    private func listHeight(_ git: GitStatus) -> CGFloat {
        let groups = (git.stagedCount > 0 ? 1 : 0) + (git.changedCount > 0 ? 1 : 0)
        let rows = git.staged.count + git.changed.count
        return min(CGFloat(rows) * Self.rowHeight + CGFloat(groups) * 22 + 12, Self.maxListHeight)
    }

    private func first(_ git: GitStatus) -> DiffTarget? {
        if let path = git.staged.first { return DiffTarget(dir: session.cwd, path: path, staged: true) }
        return git.changed.first.map { DiffTarget(dir: session.cwd, path: $0, staged: false) }
    }
}

/// A file in the Changes tab: its name first (the part that tells files apart), then its folder.
private struct ChangeRow: View {
    let path: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text((path as NSString).lastPathComponent).lineLimit(1)
                Text((path as NSString).deletingLastPathComponent)
                    .foregroundStyle(selected ? theme.accentForeground.opacity(0.75) : theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(selected ? theme.accentForeground : theme.text)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? theme.accent : hovering ? theme.text.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(path)
    }
}
