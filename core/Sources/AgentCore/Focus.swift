// Foundation only, not AppKit: linking AppKit adds ~100ms to every agentctl launch.
import Foundation

public enum FocusResult: String, Sendable {
    case focused
    case automationDenied = "automation-denied"
    case notFound = "not-found"
}

/// Brings the terminal / window hosting a session to the front, from outside VS Code.
///
/// VS Code tabs cannot be selected from outside, so for VS Code sessions this raises the window
/// for the session's folder and drops a focus request that the extension in that window picks up
/// to reveal the exact terminal (or Claude panel).
public enum Focus {
    static let itermScript = """
    on run argv
      set targetId to item 1 of argv
      set targetTty to item 2 of argv
      tell application "iTerm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if (unique id of s is targetId) or (tty of s is targetTty) then
                select w
                select t
                select s
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
      end tell
      return "notfound"
    end run
    """

    public static func focus(_ session: Session) -> FocusResult {
        switch session.host {
        case .iterm:
            return focusIterm(session)
        case .vscodeTerminal, .vscodePanel:
            // The window's own root, not the session folder: `code <subfolder>` would open a new window.
            let target = VSCodeWindows.window(for: session, ProcessTable.read())?.openTarget ?? session.cwd
            writeFocusRequest(session)
            return openInVSCode(target) ? .focused : .notFound
        case .other:
            return .notFound
        }
    }

    static func focusIterm(_ session: Session) -> FocusResult {
        // ITERM_SESSION_ID looks like "w0t1p0:<uuid>"; AppleScript's `unique id` is the uuid part.
        let uuid = session.itermSessionId?.split(separator: ":").last.map(String.init) ?? ""
        let tty = session.tty.flatMap { $0 == "??" ? nil : "/dev/\($0)" } ?? ""
        let res = Shell.run("/usr/bin/osascript", ["-e", itermScript, uuid, tty], timeout: 10)
        if res.ok, res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" { return .focused }
        if res.stderr.contains("-1743") || res.stderr.contains("not allowed") { return .automationDenied }
        return .notFound
    }

    static func writeFocusRequest(_ session: Session) {
        let request: [String: Any] = [
            "pid": session.pid.map { Int($0) } ?? NSNull(),
            "sessionId": session.sessionId ?? NSNull(),
            "cwd": session.cwd,
            "host": session.host.rawValue,
            "at": (Date().timeIntervalSince1970 * 1000).rounded(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        try? FileManager.default.createDirectory(at: Paths.statusDir, withIntermediateDirectories: true)
        try? data.write(to: Paths.focusRequest, options: .atomic)
    }

    /// Opens a folder (or .code-workspace) in VS Code; when a window already has it open, that window is
    /// focused instead.
    ///
    /// Uses LaunchServices (`open -b`), which hands the path to the running VS Code. The `code` CLI is
    /// avoided on purpose: it starts the VS Code binary itself, which macOS shows as a second VS Code
    /// launching (Dock icon / blank window flash) before it forwards to the running instance and exits.
    @discardableResult
    public static func openInVSCode(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if Shell.run("/usr/bin/open", ["-b", "com.microsoft.VSCode", path]).ok { return true }
        // Fallback for an unregistered VS Code install: the CLI. Inherited VSCODE_* / ELECTRON_* variables
        // (when called from inside VS Code) would route it to the calling window, so drop them.
        let cli = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return false }
        let env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("VSCODE_") && !$0.key.hasPrefix("ELECTRON_") }
        return Shell.run(cli, [path], timeout: 10, environment: env).ok
    }

    public static func openPort(_ port: Int) {
        _ = Shell.run("/usr/bin/open", ["http://localhost:\(port)"])
    }

    /// Sends SIGTERM. Returns an error message on failure.
    public static func terminate(pid: Int32) -> String? {
        kill(pid, SIGTERM) == 0 ? nil : String(cString: strerror(errno))
    }
}
