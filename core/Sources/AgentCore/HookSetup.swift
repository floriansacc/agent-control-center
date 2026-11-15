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

    /// Copies `bundledScript` to a stable location and registers it for every event.
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

        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: settingsURL.path) { try Data("{}\n".utf8).write(to: settingsURL) }

        let command = "\"\(installedScript.path)\""
        let filter = """
        reduce ($events | split(" "))[] as $e (.;
          .hooks[$e] = ((.hooks[$e] // [])
            | if any(.[]; any(.hooks[]?; .command == $cmd)) then .
              else . + [{ hooks: [{ type: "command", command: $cmd, timeout: 5 }] }] end))
        """
        let result = Shell.run(jq, [
            "--arg", "cmd", command, "--arg", "events", events.joined(separator: " "), filter, settingsURL.path,
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
        guard let bundledScript, FileManager.default.fileExists(atPath: installedScript.path),
              let new = try? Data(contentsOf: bundledScript),
              (try? Data(contentsOf: installedScript)) != new
        else { return }
        try? copyScript(from: bundledScript, to: installedScript)
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
