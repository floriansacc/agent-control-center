// CoreServices, not AppKit: linking AppKit adds ~100ms to every agentctl launch.
import CoreServices
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

    /// Opens a folder in VS Code; when a window already has it open, that window is focused instead.
    @discardableResult
    public static func openInVSCode(_ folder: String) -> Bool {
        guard !folder.isEmpty else { return false }
        let appURL = (LSCopyApplicationURLsForBundleIdentifier("com.microsoft.VSCode" as CFString, nil)?
            .takeRetainedValue() as? [URL])?.first
            ?? URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let cli = appURL.appendingPathComponent("Contents/Resources/app/bin/code").path
        if FileManager.default.isExecutableFile(atPath: cli) {
            // When called from inside VS Code (extension host / integrated terminal), inherited VSCODE_* and
            // ELECTRON_* variables would route the CLI to the calling window instead of the folder's window.
            let env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("VSCODE_") && !$0.key.hasPrefix("ELECTRON_") }
            if Shell.run(cli, [folder], timeout: 10, environment: env).ok { return true }
        }
        return Shell.run("/usr/bin/open", ["-b", "com.microsoft.VSCode", folder]).ok
    }

    public static func openPort(_ port: Int) {
        _ = Shell.run("/usr/bin/open", ["http://localhost:\(port)"])
    }

    /// Sends SIGTERM. Returns an error message on failure.
    public static func terminate(pid: Int32) -> String? {
        kill(pid, SIGTERM) == 0 ? nil : String(cString: strerror(errno))
    }
}
