import AgentCore
import Foundation

// CLI over AgentCore. The VS Code extension ships this binary and uses it for all scanning and
// out-of-window focusing, so the logic lives only in AgentCore.

let usage = """
usage:
  agentctl list                                   human-readable sessions and ports
  agentctl snapshot [--no-ports] [--no-git] [--ignore a,b] [--show-ephemeral] [--pretty]
                                                  JSON snapshot (contract with the VS Code extension)
  agentctl focus <pid|session-id>                 bring the session's terminal / window to the front
  agentctl transcript <session-id> [-n count]     the session's last turns (prompts, replies, tool calls)
  agentctl approve <session-id> [--always]        allow what the session asks permission for (app running)
  agentctl deny <session-id> [message]            deny it; the message tells Claude what to do instead
  agentctl ancestors <pid>                        JSON array: pid and its ancestors, nearest first
"""

func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func printJSON<T: Encodable>(_ value: T, pretty: Bool = false) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { fail("encoding failed", code: 1) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
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

func tokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
}

func contextLine(_ s: Session) -> String? {
    var parts = [s.model, s.effort].compactMap { $0 }
    if let used = s.contextTokens {
        if let size = s.contextSize, let pct = s.contextPercent {
            parts.append("context \(Int(pct))% (\(tokens(used)) / \(tokens(size)))")
        } else {
            parts.append("context \(tokens(used)) tokens")
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

func gitLine(_ g: GitStatus) -> String {
    var parts: [String] = []
    if let ahead = g.ahead, ahead > 0 { parts.append("↑\(ahead)") }
    if let behind = g.behind, behind > 0 { parts.append("↓\(behind)") }
    if g.stagedCount > 0 { parts.append("\(g.stagedCount) staged") }
    if g.changedCount > 0 { parts.append("\(g.changedCount) changed") }
    return parts.isEmpty ? "clean" : parts.joined(separator: " · ")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

switch command {
case "snapshot":
    var options = ScanOptions()
    var pretty = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--no-ports": options.includePorts = false
        case "--no-git": options.includeGit = false
        case "--show-ephemeral": options.hideEphemeralPorts = false
        case "--pretty": pretty = true
        case "--ignore":
            i += 1
            guard i < args.count else { fail("--ignore needs a comma-separated list") }
            options.ignoredProcesses = args[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default: fail("unknown option \(args[i])\n\n\(usage)")
        }
        i += 1
    }
    printJSON(Scanner.shared.snapshot(options), pretty: pretty)

case "list":
    let snap = Scanner.shared.snapshot()
    if let limits = snap.rateLimits {
        let parts = [limits.fiveHour.map { "5h \(Int($0.usedPercent))%" }, limits.sevenDay.map { "week \(Int($0.usedPercent))%" }]
        print("Plan usage: " + parts.compactMap { $0 }.joined(separator: " · ") + "\n")
    }
    if snap.sessions.isEmpty { print("No Claude Code sessions running.") }
    for s in snap.sessions {
        let status = s.statusSince != nil ? "\(s.status.label) \(ago(s.statusSince))" : s.status.label
        let parts = [s.branch, status, s.host.label, s.tty.map { "tty \($0)" }, s.pid.map { "pid \($0)" }].compactMap { $0 }
        let folder = s.displayName == s.project ? "" : "  [\(s.folderLabel)]"
        print("● \(s.displayName)\(folder)  \(parts.joined(separator: " · "))")
        if let activity = s.activity { print("    now: \(activity.prefix(90))") }
        if let request = s.permission {
            print("    asks: \(request.toolLabel)\(request.detail.map { " · \($0)" } ?? "")"
                + (request.answerable ? "  (agentctl approve|deny \(s.sessionId ?? s.key))" : ""))
        }
        if let context = contextLine(s) { print("    \(context)") }
        if let git = s.git { print("    git: \(gitLine(git))") }
        if let prompt = s.lastPrompt { print("    you: \(prompt.prefix(90))") }
        if let response = s.lastResponse { print("    claude: \(response.prefix(90))") }
        for p in s.ports { print("    :\(p.port)  \(p.command) (pid \(p.pid))\(p.viaCwd == true ? " · same folder" : "")") }
    }
    if !snap.otherPorts.isEmpty {
        print("\nOther ports: " + snap.otherPorts.map { ":\($0.port) \($0.command)" }.joined(separator: ", "))
    }

case "focus":
    guard let target = args.first else { fail("focus needs a pid or session id") }
    let snap = Scanner.shared.snapshot(ScanOptions(includePorts: false))
    guard let session = snap.sessions.first(where: { s in
        s.sessionId == target || s.key == target || s.pid.map(String.init) == target
    }) else { fail("no session matching \(target)", code: 1) }
    let result = Focus.focus(session)
    print(result.rawValue)
    exit(result == .focused ? 0 : 2)

case "transcript":
    guard let target = args.first else { fail("transcript needs a session id") }
    var count = 30
    if let i = args.firstIndex(of: "-n"), i + 1 < args.count, let n = Int(args[i + 1]) { count = n }
    // A live session (its reported path, or a pid), else any transcript with that id.
    let live = Scanner.shared.snapshot(ScanOptions(includePorts: false, includeGit: false)).sessions
        .first { $0.sessionId == target || $0.pid.map(String.init) == target }
    guard let url = live.flatMap(Transcript.url(for:)) ?? Transcript.url(sessionId: target) else {
        fail("no transcript for \(target)", code: 1)
    }
    let reader = TranscriptReader(url: url)
    reader.update()
    for entry in reader.entries.suffix(count) {
        switch entry.kind {
        case let .prompt(text): print("\nYou: \(text)")
        case let .reply(text): print("\nClaude: \(text)")
        case let .tool(call):
            let mark = call.result.map { $0.isError ? " ✗" : "" } ?? " …"
            print("  · \(call.label)\(call.detail.map { " \($0)" } ?? "")\(mark)")
        case let .event(text): print("\n— \(text) —")
        }
    }

case "approve", "deny":
    guard let target = args.first else { fail("\(command) needs a session id") }
    let snap = Scanner.shared.snapshot(ScanOptions(includePorts: false, includeGit: false))
    guard let session = snap.sessions.first(where: { $0.sessionId == target || $0.pid.map(String.init) == target }),
          let sessionId = session.sessionId
    else { fail("no session matching \(target)", code: 1) }
    guard let request = session.permission else { fail("\(session.displayName) is not waiting on a permission", code: 1) }
    let decision: Approvals.Decision = command == "deny"
        ? .deny(message: args.dropFirst().joined(separator: " "))
        : args.contains("--always") ? .allowAlways : .allow
    do {
        try Approvals.answer(sessionId: sessionId, request: request, decision)
        print("\(command == "deny" ? "Denied" : "Allowed"): \(request.toolLabel)\(request.detail.map { " · \($0)" } ?? "")")
    } catch {
        fail(error.localizedDescription + " Answer in the session itself.", code: 2)
    }

case "ancestors":
    guard let raw = args.first, let pid = Int32(raw) else { fail("ancestors needs a pid") }
    let table = ProcessTable.read()
    printJSON([pid] + table.ancestors(of: pid).map(\.pid))

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
