import Foundation

/// Registers the status hook in Claude Code's user settings, for installs without the repository
/// (the menu bar app from the DMG ships the hook script in its bundle).
///
/// Mirrors `install.sh hook`: same events, same jq transform (which keeps the user's key order and
/// formatting), a timestamped backup before any change, and other hooks left untouched.
public enum HookSetup {
    public enum SetupError: LocalizedError {
        case missingScript
        case missingJq
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .missingScript: "The hook script is missing from the app bundle."
            case .missingJq: "jq was not found. It ships with macOS 15 and later, or install it with Homebrew."
            case let .failed(message): message
            }
        }
    }

    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "PermissionRequest", "Stop", "StopFailure", "SubagentStop",
    ]

    public static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Stable location for the app's copy of the hook: the app itself may be moved or replaced.
    public static var installedScript: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agent Control Center/agent-status.sh")
    }

    static let jqCandidates = ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"]

    /// Seconds Claude Code lets the PermissionRequest hook wait for an answer from the app.
    public static let permissionTimeout = 1800

    /// Whether the registered PermissionRequest hook may wait long enough to take answers from the app
    /// (registrations from before approvals used 5 seconds).
    public static func approvalsReady(settingsURL: URL = settingsURL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let groups = (json["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        else { return false }
        for group in groups {
            for case let hook as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                guard (hook["command"] as? String)?.contains("agent-status.sh") == true else { continue }
                // No timeout means Claude Code's default (60 s or more): long enough.
                let timeout = (hook["timeout"] as? NSNumber)?.intValue ?? 60
                return timeout >= 60
            }
        }
        return false
    }

    /// True when some registered hook runs an `agent-status.sh` (the repository's or the app's copy).
    public static func isInstalled(settingsURL: URL = settingsURL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else { return false }
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                for case let hook as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                    if (hook["command"] as? String)?.contains("agent-status.sh") == true { return true }
                }
            }
        }
        return false
    }

    /// The status line script ships next to the hook script.
    static func statusLineScript(nextTo script: URL) -> URL {
        script.deletingLastPathComponent().appendingPathComponent("agent-statusline.sh")
    }

    /// Copies `bundledScript` to a stable location and registers it for every event. The status line
    /// script next to it is registered too, unless the user already has a status line.
    public static func install(
        bundledScript: URL?,
        settingsURL: URL = settingsURL,
        installedScript: URL = installedScript
    ) throws {
        guard let bundledScript, FileManager.default.fileExists(atPath: bundledScript.path) else { throw SetupError.missingScript }
        guard let jq = jqCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SetupError.missingJq
        }
        try copyScript(from: bundledScript, to: installedScript)
        let bundledStatusLine = statusLineScript(nextTo: bundledScript)
        let installedStatusLine = statusLineScript(nextTo: installedScript)
        let hasStatusLine = FileManager.default.fileExists(atPath: bundledStatusLine.path)
        if hasStatusLine { try copyScript(from: bundledStatusLine, to: installedStatusLine) }

        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: settingsURL.path) { try Data("{}\n".utf8).write(to: settingsURL) }

        let command = "\"\(installedScript.path)\""
        // Same transform as install.sh: PermissionRequest may wait for the app's answer (30 min), and an
        // agent-status.sh already registered (the repository's or the app's) is updated, never doubled.
        let filter = """
        reduce ($events | split(" "))[] as $e (.;
          (if $e == "PermissionRequest" then \(permissionTimeout) else 5 end) as $t
          | .hooks[$e] = ((.hooks[$e] // [])
            | if any(.[]; any(.hooks[]?; (.command // "") | contains("agent-status.sh")))
              then map(if .hooks == null then . else .hooks |= map(
                     if (.command // "") | contains("agent-status.sh") then .timeout = $t else . end) end)
              else . + [{ hooks: [{ type: "command", command: $cmd, timeout: $t }] }] end))
        | if $statusline != "" and .statusLine == null then .statusLine = { type: "command", command: $statusline } else . end
        """
        let result = Shell.run(jq, [
            "--arg", "cmd", command, "--arg", "events", events.joined(separator: " "),
            "--arg", "statusline", hasStatusLine ? "\"\(installedStatusLine.path)\"" : "",
            filter, settingsURL.path,
        ], timeout: 10)
        guard result.ok, !result.stdout.isEmpty else {
            throw SetupError.failed("Could not update \(settingsURL.path): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let current = try Data(contentsOf: settingsURL)
        let updated = Data(result.stdout.utf8)
        guard updated != current else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let backup = settingsURL.appendingPathExtension("bak-\(stamp.string(from: Date()))")
        try fm.copyItem(at: settingsURL, to: backup)
        try updated.write(to: settingsURL, options: .atomic)
    }

    /// Keeps the installed copy in step with the app's bundled script after an app update.
    /// Does nothing when the app's copy was never installed (e.g. the hook runs from the repository).
    public static func refreshInstalledScript(from bundledScript: URL?) {
        guard let bundledScript else { return }
        let pairs = [
            (bundledScript, installedScript),
            (statusLineScript(nextTo: bundledScript), statusLineScript(nextTo: installedScript)),
        ]
        for (source, target) in pairs {
            guard FileManager.default.fileExists(atPath: target.path),
                  let new = try? Data(contentsOf: source),
                  (try? Data(contentsOf: target)) != new
            else { continue }
            try? copyScript(from: source, to: target)
        }
    }

    private static func copyScript(from source: URL, to installedScript: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: installedScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = installedScript.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(installedScript, withItemAt: tmp)
    }
}
