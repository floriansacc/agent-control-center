import AgentCore
import SwiftUI

/// A changed file of a session, to show its diff.
struct DiffTarget: Identifiable, Hashable {
    /// The session's folder: git finds the repository from it.
    let dir: String
    /// Relative to the repository root, as `git status` lists it.
    let path: String
    let staged: Bool

    var id: String { "\(staged ? "staged" : "changes"):\(path)" }
}

/// One file's `git diff`, read-only: line numbers before and after, removed lines in the error color, added
/// ones in the done color, like the permission card's edits.
struct DiffSheet: View {
    let target: DiffTarget
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var diff: FileDiff?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            theme.border.frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.isNative ? Color(nsColor: .textBackgroundColor) : theme.background)
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 360, idealHeight: 620)
        .foregroundStyle(theme.text)
        .task(id: target) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text((target.path as NSString).lastPathComponent).font(.headline)
                let folder = (target.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(1).truncationMode(.head)
                }
            }
            Text(target.staged ? "Staged" : "Changes")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill((target.staged ? theme.done : theme.waiting).opacity(0.15)))
                .foregroundStyle(target.staged ? theme.done : theme.waiting)
            Spacer()
            if let diff, !diff.isBinary {
                Text("+\(diff.added)").foregroundStyle(theme.done)
                Text("−\(diff.removed)").foregroundStyle(theme.error)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .font(.callout.monospacedDigit())
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if failed {
            ContentUnavailableView("Could not read the diff", systemImage: "exclamationmark.triangle",
                                   description: Text("git did not answer for this folder."))
        } else if let diff {
            if diff.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc", description: Text("git does not show its changes as text."))
            } else if diff.isEmpty {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                       description: Text("The file has no \(target.staged ? "staged " : "")changes any more."))
            } else {
                lines(diff)
            }
        } else {
            Color.clear
        }
    }

    private func lines(_ diff: FileDiff) -> some View {
        // Wide enough for the largest line number.
        let largest = diff.lines.map { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0
        let digits = String(max(largest, 99)).count
        let numberWidth = CGFloat(digits) * 8 + 8
        // Every line at least as wide as the view, so the added / removed backgrounds line up on the right.
        return GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        DiffLineView(line: line, numberWidth: numberWidth)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if diff.truncated {
                        Text("… the rest of the diff is not shown (too long).")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: geo.size.width, alignment: .leading)
                .textSelection(.enabled)
            }
        }
    }

    private func load() async {
        let target = target
        let result = await Task.detached(priority: .userInitiated) {
            GitDiff.diff(in: target.dir, path: target.path, staged: target.staged)
        }.value
        diff = result
        failed = result == nil
    }
}

private struct DiffLineView: View {
    let line: FileDiff.Line
    let numberWidth: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .frame(width: 18)
                .foregroundStyle(markerColor)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(textColor)
                .fixedSize()
            Spacer(minLength: 12)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, line.kind == .hunk ? 4 : 0.5)
        .background(background)
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(theme.textFaint)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var markerColor: Color {
        line.kind == .added ? theme.done : theme.error
    }

    private var textColor: Color {
        switch line.kind {
        case .hunk, .note: theme.textSecondary
        default: theme.text
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: theme.done.opacity(0.14)
        case .removed: theme.error.opacity(0.14)
        case .hunk: theme.card
        default: .clear
        }
    }
}
