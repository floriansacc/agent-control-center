import AgentCore
import SwiftUI

/// The selected session's recent turns, read-only: your prompts, Claude's replies, and its tool calls folded
/// into one line each. A banner at the bottom says what the session needs or is doing.
struct ConversationView: View {
    let session: Session
    let conversation: ControlCenterModel.Conversation
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            switch conversation {
            case .none, .loading:
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                ContentUnavailableView(
                    "No conversation yet",
                    systemImage: "text.bubble",
                    description: Text(session.status == .untracked
                        ? "This session started before the status hook was set up. Its conversation shows after its next prompt."
                        : "The conversation shows once something has been sent.")
                )
            case let .loaded(entries):
                if entries.isEmpty {
                    ContentUnavailableView("No conversation yet", systemImage: "text.bubble")
                } else {
                    TranscriptList(entries: entries, running: session.status == .working)
                }
            }
            StatusBanner(session: session, app: app)
        }
    }
}

/// Consecutive tool calls are shown as one group.
private enum Row: Identifiable {
    case entry(TranscriptEntry)
    case tools(id: String, [ToolCall])

    var id: String {
        switch self {
        case let .entry(entry): entry.id
        case let .tools(id, _): id
        }
    }

    static func build(_ entries: [TranscriptEntry]) -> [Row] {
        var rows: [Row] = []
        var calls: [ToolCall] = []
        var groupId = ""
        func flush() {
            if !calls.isEmpty { rows.append(.tools(id: groupId, calls)) }
            calls = []
        }
        for entry in entries {
            if case let .tool(call) = entry.kind {
                if calls.isEmpty { groupId = entry.id }
                calls.append(call)
            } else {
                flush()
                rows.append(.entry(entry))
            }
        }
        flush()
        return rows
    }
}

private struct TranscriptList: View {
    let entries: [TranscriptEntry]
    /// The last tool call without a result is still running.
    let running: Bool
    /// Tool groups and lines opened by a click, kept across updates.
    @State private var expanded: Set<String> = []
    @State private var atBottom = true

    var body: some View {
        let rows = Row.build(entries)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        switch row {
                        case let .entry(entry):
                            EntryView(entry: entry)
                        case let .tools(id, calls):
                            ToolGroup(id: id, calls: calls, running: running && row.id == rows.last?.id, expanded: $expanded)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(BottomTracker(atBottom: $atBottom))
            // Follow new messages, unless you scrolled up to read.
            .onChange(of: entries.last) { _, _ in
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

/// Whether the scroll view is at its end (macOS 15+; before, it always follows new messages).
private struct BottomTracker: ViewModifier {
    @Binding var atBottom: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40
            } action: { _, isAtBottom in
                atBottom = isAtBottom
            }
        } else {
            content
        }
    }
}

private struct EntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case let .prompt(text):
            PromptBubble(text: text, time: entry.timestamp)
        case let .reply(text):
            MarkdownText(text)
        case let .event(text):
            HStack(spacing: 8) {
                VStack { Divider() }
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize()
                VStack { Divider() }
            }
        case .tool:
            // Grouped by `Row`.
            EmptyView()
        }
    }
}

private struct PromptBubble: View {
    let text: String
    let time: Double?
    @State private var showAll = false

    private static let foldLength = 600

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .textSelection(.enabled)
                    .lineLimit(long && !showAll ? 8 : nil)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.blue.opacity(0.13)))
                HStack(spacing: 8) {
                    if long {
                        Button(showAll ? "Show less" : "Show more") { showAll.toggle() }
                            .buttonStyle(.link)
                    }
                    if let time {
                        Text(Date(timeIntervalSince1970: time), format: .dateTime.hour().minute())
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
            }
        }
    }

    private var long: Bool { text.count > Self.foldLength || text.filter { $0 == "\n" }.count > 8 }
}

/// A run of tool calls. Up to three show as they are; longer runs fold into one summary line
/// ("12 steps · Bash ×5, Edit ×4…"), with the running call still visible below it.
private struct ToolGroup: View {
    let id: String
    let calls: [ToolCall]
    let running: Bool
    @Binding var expanded: Set<String>

    private static let foldAbove = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if calls.count > Self.foldAbove {
                let open = expanded.contains(id)
                Button {
                    if open { expanded.remove(id) } else { expanded.insert(id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 14)
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                        if failures > 0 {
                            Label("\(failures)", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Palette.red)
                                .help("\(failures) failed")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    lines(calls).padding(.leading, 20)
                } else if running, let last = calls.last, last.result == nil {
                    lines([last]).padding(.leading, 20)
                }
            } else {
                lines(calls)
            }
        }
    }

    private func lines(_ calls: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(calls, id: \.id) { call in
                ToolLine(call: call, running: running && call.id == self.calls.last?.id && call.result == nil, expanded: $expanded)
            }
        }
    }

    private var failures: Int { calls.filter { $0.result?.isError == true }.count }

    /// "12 steps · Bash ×5, Edit ×4, Read ×3".
    private var summary: String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for call in calls {
            if counts[call.label] == nil { order.append(call.label) }
            counts[call.label, default: 0] += 1
        }
        let tools = order.sorted { counts[$0]! > counts[$1]! }.prefix(4)
            .map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }
        return "\(calls.count) steps · " + tools.joined(separator: ", ") + (order.count > 4 ? "…" : "")
    }
}

/// One tool call: icon, tool, detail. A click shows the full input (the whole command, the path…).
// TODO: show the tool's output (ToolResult.preview) under the input once outputs are part of the view.
private struct ToolLine: View {
    let call: ToolCall
    let running: Bool
    @Binding var expanded: Set<String>

    var body: some View {
        let open = expanded.contains(call.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: toolSymbol(call.name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(call.label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                if let detail = call.detail {
                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if running {
                    // Static on purpose, like every status indicator in the window (see SidebarRow).
                    Image(systemName: "ellipsis").font(.caption).foregroundStyle(Palette.blue).help("Running")
                } else if call.result?.isError == true {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(Palette.red).help("Failed")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard call.input != nil else { return }
                if open { expanded.remove(call.id) } else { expanded.insert(call.id) }
            }
            .help(call.input == nil ? "" : open ? "Click to hide the input" : "Click to show the input")
            if open, let input = call.input {
                Text(input)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .padding(.leading, 20)
            }
        }
    }
}

/// What the session needs from you or is doing now, under the conversation.
private struct StatusBanner: View {
    let session: Session
    @ObservedObject var app: AppModel

    var body: some View {
        switch session.status {
        case .waiting, .error:
            HStack(spacing: 10) {
                Image(systemName: session.status.symbol).foregroundStyle(session.status.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.status == .waiting ? "Needs your input" : "Stopped with an error")
                        .font(.callout.weight(.semibold))
                    if let message = session.message {
                        Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
                    }
                }
                Spacer()
                Button(openLabel(session)) { app.focus(session) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(session.status.color.opacity(0.12))
            .overlay(alignment: .top) { Divider() }
        case .working:
            HStack(spacing: 8) {
                Image(systemName: SessionStatus.working.symbol).foregroundStyle(Palette.blue)
                if let activity = session.activity, let tool = session.lastTool {
                    Image(systemName: toolSymbol(tool)).foregroundStyle(.secondary)
                    Text(activity).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Working…")
                }
                Spacer()
                Text("for \(ago(session.statusSince))").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider() }
        default:
            EmptyView()
        }
    }
}
