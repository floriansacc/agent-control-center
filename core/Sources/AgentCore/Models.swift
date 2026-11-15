import Foundation

// JSON shape is the contract with the VS Code extension (vscode/core.js typedefs): keep them in sync.

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case working, waiting, error, done, idle, untracked

    /// Sort order: what needs attention first.
    public var rank: Int {
        switch self {
        case .waiting: 0
        case .error: 1
        case .working: 2
        case .done: 3
        case .idle: 4
        case .untracked: 5
        }
    }

    public var label: String {
        switch self {
        case .working: "working"
        case .waiting: "needs input"
        case .error: "error"
        case .done: "done"
        case .idle: "idle"
        case .untracked: "no status yet"
        }
    }
}

public enum SessionHost: String, Codable, Sendable {
    case iterm
    case vscodeTerminal = "vscode-terminal"
    case vscodePanel = "vscode-panel"
    /// The Code tab of the Claude desktop app.
    case claudeDesktop = "claude-desktop"
    case other

    public var label: String {
        switch self {
        case .iterm: "iTerm"
        case .vscodeTerminal: "VS Code terminal"
        case .vscodePanel: "VS Code panel"
        case .claudeDesktop: "Claude app"
        case .other: "terminal"
        }
    }
}

public struct Listener: Codable, Sendable, Hashable, Identifiable {
    public var port: Int
    public var address: String
    public var pid: Int32
    public var command: String
    public var cwd: String?
    /// Attributed to a session because it runs inside the session's folder, not because the agent spawned it.
    public var viaCwd: Bool?

    public var id: String { "\(pid):\(port)" }
}

public struct Session: Codable, Sendable, Identifiable {
    public var key: String
    public var sessionId: String?
    public var pid: Int32?
    public var cwd: String
    public var project: String
    public var branch: String?
    public var status: SessionStatus
    /// Unix seconds.
    public var statusSince: Double?
    public var updatedAt: Double?
    public var startedAt: Double?
    public var lastPrompt: String?
    /// Claude's reply at the end of the last turn, as plain text.
    public var lastResponse: String?
    public var lastTool: String?
    /// What the current tool call is about: a command's description, a file name, a search pattern…
    public var toolDetail: String?
    public var message: String?
    public var host: SessionHost
    public var tty: String?
    public var itermSessionId: String?
    public var statusFile: String?
    public var ports: [Listener]

    public var id: String { key }

    /// The line describing the session: what Claude is working on while a turn runs, what it answered once
    /// the turn is over.
    public var summary: String? {
        switch status {
        case .working, .waiting: return lastPrompt
        default: return lastResponse ?? lastPrompt
        }
    }

    /// The step Claude is on while a turn runs, e.g. "Bash · Run the tests" or "figma · get_screenshot".
    public var activity: String? {
        guard status == .working || status == .waiting, let tool = lastTool else { return nil }
        let label = Self.toolLabel(tool)
        guard let detail = toolDetail, !detail.isEmpty else { return label }
        return "\(label) · \(detail)"
    }

    /// MCP tools are named `mcp__<server>__<tool>`; show them as "<server> <tool>".
    public static func toolLabel(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return tool }
        return "\(parts[1]) \(parts[2...].joined(separator: "__"))"
    }

    /// Idle or finished for longer than `seconds`: shown folded away. Sessions that need you never are.
    public func isIdle(longerThan seconds: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard status == .idle || status == .done, let since = statusSince ?? updatedAt else { return false }
        return now - since > seconds
    }
}

public struct Snapshot: Codable, Sendable {
    public var sessions: [Session]
    public var otherPorts: [Listener]
    public var portsScanned: Bool
    /// Unix milliseconds.
    public var scannedAt: Double
    /// Lets the VS Code extension skip its own notifications when the menu bar app already sends them.
    public var menuBarAppRunning: Bool

    public static let empty = Snapshot(sessions: [], otherPorts: [], portsScanned: false, scannedAt: 0, menuBarAppRunning: false)
}

public enum Paths {
    public static var statusDir: URL {
        if let dir = ProcessInfo.processInfo.environment["AGENT_STATUS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/agent-status")
    }

    /// Written by `Focus` to ask the VS Code window that owns a session to reveal its terminal / Claude tab.
    /// Dot-prefixed and without .json so the scanner never mistakes it for a session.
    public static var focusRequest: URL { statusDir.appendingPathComponent(".focus-request") }

    /// Executable name of the menu bar app, used to detect whether it is running.
    public static let appExecutableName = "AgentControlApp"
}
