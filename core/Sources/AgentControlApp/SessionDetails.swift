import AgentCore
import SwiftUI

/// "124k", "1.2M".
func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1000 { return "\(n / 1000)k" }
    return "\(n)"
}

/// A small horizontal gauge.
struct UsageBar: View {
    let percent: Double
    var width: CGFloat = 54
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(theme.textFaint.opacity(0.3))
            Capsule()
                .fill(theme.usage(percent))
                .frame(width: max(3, width * min(percent, 100) / 100))
        }
        .frame(width: width, height: 5)
        .accessibilityHidden(true)
    }
}

/// Model · effort · context gauge, e.g. "Opus 5.5 · high · ▓▓▓░ 62% · 124k / 200k".
struct ContextLine: View {
    let session: Session
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.caption2).foregroundStyle(Palette.textMeta).frame(width: 12)
            if let model = session.model {
                Text(model).font(.caption.weight(.medium)).foregroundStyle(Palette.textBody)
            }
            if let effort = session.effort {
                Text(effort)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.textFaint.opacity(0.2)))
                    .foregroundStyle(Palette.textMeta)
                    .help("Reasoning effort")
            }
            if let tokens = session.contextTokens {
                if let percent = session.contextPercent, let size = session.contextSize {
                    UsageBar(percent: percent)
                    Text("\(Int(percent.rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(theme.usage(percent))
                    Text("\(formatTokens(tokens)) / \(formatTokens(size))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.textMeta)
                } else {
                    Text("\(formatTokens(tokens)) tokens").font(.caption.monospacedDigit()).foregroundStyle(Palette.textMeta)
                }
            }
        }
        .lineLimit(1)
        .help(help)
    }

    private var help: String {
        guard let tokens = session.contextTokens else { return "Model" }
        if let size = session.contextSize {
            return "Context: \(tokens.formatted()) of \(size.formatted()) tokens. Claude Code compacts the conversation when it gets full."
        }
        return "Context: \(tokens.formatted()) tokens. The window size shows once a terminal session on this model reports it (status line)."
    }
}

/// "↑2 ↓1 · ● 3 staged · ✎ 5 changed", like VS Code's Source Control.
struct GitLine: View {
    let git: GitStatus
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.caption2)
                .foregroundStyle(Palette.textMeta)
                .frame(width: 12)
            if git.isClean, (git.ahead ?? 0) == 0, (git.behind ?? 0) == 0 {
                Text("No changes").font(.caption).foregroundStyle(Palette.textFaint)
            }
            if let ahead = git.ahead, ahead > 0 {
                Label("\(ahead)", systemImage: "arrow.up")
                    .help("\(ahead) commit\(ahead == 1 ? "" : "s") to push")
            }
            if let behind = git.behind, behind > 0 {
                Label("\(behind)", systemImage: "arrow.down")
                    .help("\(behind) commit\(behind == 1 ? "" : "s") to pull")
            }
            if git.stagedCount > 0 {
                Label("\(git.stagedCount) staged", systemImage: "circle.fill")
                    .foregroundStyle(theme.done)
                    .help(fileList("Staged", git.staged, total: git.stagedCount))
            }
            if git.changedCount > 0 {
                Label("\(git.changedCount) changed", systemImage: "pencil")
                    .foregroundStyle(theme.waiting)
                    .help(fileList("Changes (including new files)", git.changed, total: git.changedCount))
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption.monospacedDigit())
        .foregroundStyle(Palette.textMeta)
        .lineLimit(1)
    }

    private func fileList(_ title: String, _ paths: [String], total: Int) -> String {
        var lines = ["\(title):"] + paths.map { "  \($0)" }
        if total > paths.count { lines.append("  … and \(total - paths.count) more") }
        return lines.joined(separator: "\n")
    }
}

/// Icon and title close together, the icon scaled down.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Plan usage under the header: "Plan usage   5h ▓▓░░ 34%   Week ▓▓▓░ 61%   3m ago", reset times on hover.
///
/// The numbers come from the API replies of terminal sessions (via the status line), so they can lag behind
/// usage from the VS Code panel or the desktop app: the row says how old they are and greys out when stale.
struct PlanUsageRow: View {
    let limits: RateLimits
    @Environment(\.theme) private var theme

    /// Older than this, the numbers are shown greyed out.
    private static let staleAfter: Double = 15 * 60

    var body: some View {
        let age = max(0, Date().timeIntervalSince1970 - limits.updatedAt)
        let stale = age > Self.staleAfter
        // Two lines: on one, the header's width (beside the title and badges) truncated the labels.
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Plan usage").font(.caption).foregroundStyle(theme.textSecondary)
                Spacer(minLength: 4)
                Text(age < 60 ? "just now" : "\(ago(limits.updatedAt)) ago")
                    .font(.caption2)
                    .foregroundStyle(theme.textFaint)
                    .help("Updated when a terminal Claude Code session gets a reply (its status line reports the usage).")
            }
            HStack(spacing: 18) {
                if let window = limits.fiveHour { gauge("5h", window, stale: stale) }
                if let window = limits.sevenDay { gauge("Week", window, stale: stale) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func gauge(_ label: String, _ window: UsageWindow, stale: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(theme.text)
            UsageBar(percent: window.usedPercent, width: 90)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.usage(window.usedPercent))
        }
        // Never squeezed into "5…" / "W…": the gauges keep their natural width.
        .fixedSize()
        .saturation(stale ? 0 : 1)
        .opacity(stale ? 0.55 : 1)
        .help(help(label, window))
    }

    private func help(_ label: String, _ window: UsageWindow) -> String {
        var text = "\(label == "5h" ? "5-hour" : "Weekly") limit: \(Int(window.usedPercent.rounded()))% used."
        if let resets = window.resetsAt {
            let date = Date(timeIntervalSince1970: resets)
            let style: Date.FormatStyle = Calendar.current.isDateInToday(date)
                ? .dateTime.hour().minute()
                : .dateTime.weekday(.abbreviated).hour().minute()
            text += " Resets \(date.formatted(style)) (in \(remaining(resets)))."
        }
        text += "\nAs of \(ago(limits.updatedAt)) ago: updated when a terminal session gets a reply, so usage from the "
            + "VS Code panel or the Claude app shows up later, and it can differ by about 1% from claude.ai."
        return text
    }

    private func remaining(_ resets: Double) -> String {
        let s = max(0, Int(resets - Date().timeIntervalSince1970))
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 60)m"
    }
}
