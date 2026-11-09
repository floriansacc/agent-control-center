import AgentCore
import Foundation

// CLI over AgentCore. The VS Code extension ships this binary and uses it for all scanning and
// out-of-window focusing, so the logic lives only in AgentCore.

let usage = """
usage:
  agentctl list                                   human-readable sessions and ports
  agentctl snapshot [--no-ports] [--ignore a,b] [--show-ephemeral] [--pretty]
                                                  JSON snapshot (contract with the VS Code extension)
  agentctl focus <pid|session-id>                 bring the session's terminal / window to the front
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
    if snap.sessions.isEmpty { print("No Claude Code sessions running.") }
    for s in snap.sessions {
        let status = s.statusSince != nil ? "\(s.status.label) \(ago(s.statusSince))" : s.status.label
        let parts = [s.branch, status, s.host.label, s.tty.map { "tty \($0)" }, s.pid.map { "pid \($0)" }].compactMap { $0 }
        print("● \(s.project)  \(parts.joined(separator: " · "))")
        if let prompt = s.lastPrompt { print("    “\(prompt.prefix(90))”") }
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

case "ancestors":
    guard let raw = args.first, let pid = Int32(raw) else { fail("ancestors needs a pid") }
    let table = ProcessTable.read()
    printJSON([pid] + table.ancestors(of: pid).map(\.pid))

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
