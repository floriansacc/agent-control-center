import AgentCore
import SwiftUI

/// What a waiting session asks permission for, with Allow / Always allow / Deny when the app can answer.
/// Shown under the conversation in place of the "Needs your input" banner.
struct PermissionCard: View {
    let session: Session
    let request: PermissionRequest
    @ObservedObject var app: AppModel
    @Environment(\.theme) private var theme
    @State private var reason = ""
    @State private var showFullInput = false
    /// The request just answered: its buttons stay disabled until the next scan replaces the card.
    @State private var sentId: String?

    private static let foldedLines = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let input = request.input, input != request.detail { inputBox(input) }
            if let why = app.whyNotAnswerable(request) {
                HStack {
                    Text(why).font(.callout).foregroundStyle(theme.textSecondary)
                    Spacer()
                    Button(openLabel(session)) { app.focus(session) }
                }
            } else {
                actions
            }
        }
        .padding(14)
        .background(theme.waiting.opacity(0.1))
        .overlay(alignment: .top) { theme.border.frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: toolSymbol(request.tool))
                .foregroundStyle(theme.waiting)
                .frame(width: 18)
            Text("Claude asks to use").foregroundStyle(theme.textSecondary)
            Text(request.toolLabel).fontWeight(.semibold)
            if let detail = request.detail {
                Text(detail).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let since = request.requestedAt {
                Text("\(ago(since)) ago").font(.caption).foregroundStyle(theme.textFaint)
            }
        }
        .font(.callout)
    }

    private func inputBox(_ input: String) -> some View {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let long = lines.count > Self.foldedLines
        return VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((showFullInput ? lines[...] : lines.prefix(Self.foldedLines)).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .foregroundStyle(lineColor(line))
                    }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: showFullInput ? 320 : nil)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.card))
            if long {
                Button(showFullInput ? "Show less" : "Show all \(lines.count) lines") { showFullInput.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    /// Edits are shown as -/+ lines (see the hook's `full`): color them like a diff.
    private func lineColor(_ line: Substring) -> Color {
        guard request.tool == "Edit" || request.tool == "MultiEdit" else { return theme.text }
        if line.hasPrefix("- ") { return theme.error }
        if line.hasPrefix("+ ") { return theme.done }
        return theme.textSecondary
    }

    private var actions: some View {
        let sent = sentId == request.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Reason for Claude, if you deny (optional)", text: $reason)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer(minLength: 8)
                Button("Deny") { send(.deny(message: reason.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    .help("Claude does not run it and gets your reason, if any.")
                if !request.alwaysAllow.isEmpty {
                    Button("Always Allow") { send(.allowAlways) }
                        .help("Allow, and don't ask again: " + request.alwaysAllow.joined(separator: "; "))
                }
                Button("Allow") { send(.allow) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Allow this once (⌘↩)")
            }
            .disabled(sent)
            if !request.alwaysAllow.isEmpty {
                Text("Always allow: " + request.alwaysAllow.joined(separator: "; "))
                    .font(.caption)
                    .foregroundStyle(theme.textFaint)
                    .lineLimit(2)
            }
            if sent {
                Text("Sent. Waiting for Claude Code…").font(.caption).foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func send(_ decision: Approvals.Decision) {
        sentId = request.id
        app.answer(session, decision)
    }
}
