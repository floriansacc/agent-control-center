import Foundation

/// Answering a session's permission request from outside it (the Control Center window, `agentctl`).
///
/// The hook (`agent-status.sh`) records each request in `.permissions/<session>.json`. While the app runs with
/// approvals on (`.approvals` holds its pid), the hook also waits for an answer in `.decisions/<session>.json`
/// and hands it to Claude Code. Claude Code shows its own prompt meanwhile: whichever answers first wins.
public enum Approvals {
    public enum Decision: Sendable, Equatable {
        case allow
        /// Allow, and add Claude Code's suggested rule so it does not ask again.
        case allowAlways
        /// Deny; the message (optional) tells Claude what to do instead.
        case deny(message: String?)
    }

    public enum AnswerError: LocalizedError {
        case notWaiting

        public var errorDescription: String? {
            "This request can no longer be answered from here (it was answered elsewhere, or the hook stopped waiting)."
        }
    }

    /// Turns approvals on (the hook waits for the app's answers) or off, for the process `pid`.
    public static func setEnabled(_ enabled: Bool, pid: Int32 = getpid()) {
        let url = Paths.approvalsFlag
        if enabled {
            try? FileManager.default.createDirectory(at: Paths.statusDir, withIntermediateDirectories: true)
            try? Data("\(pid)\n".utf8).write(to: url, options: .atomic)
        } else if let text = try? String(contentsOf: url, encoding: .utf8),
                  let owner = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  owner == pid || kill(owner, 0) != 0 {
            // Our own flag, or one left by an instance that is gone; not a running instance's.
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Sends the answer to the hook waiting on `request` for `sessionId`.
    public static func answer(sessionId: String, request: PermissionRequest, _ decision: Decision) throws {
        guard request.answerable, !sessionId.contains("/") else { throw AnswerError.notWaiting }
        var answer: [String: Any] = ["id": request.id]
        switch decision {
        case .allow:
            answer["behavior"] = "allow"
        case .allowAlways:
            answer["behavior"] = "allow"
            answer["always"] = true
        case let .deny(message):
            answer["behavior"] = "deny"
            if let message, !message.isEmpty { answer["message"] = message }
        }
        let data = try JSONSerialization.data(withJSONObject: answer)
        try FileManager.default.createDirectory(at: Paths.decisionsDir, withIntermediateDirectories: true)
        try data.write(to: Paths.decisionsDir.appendingPathComponent("\(sessionId).json"), options: .atomic)
    }

    /// The request recorded for a session waiting on a permission. Requests of tools that need the person
    /// themselves (questions, plan approval) are never answerable from outside.
    static func read(sessionId: String) -> PermissionRequest? {
        let url = Paths.permissionsDir.appendingPathComponent("\(sessionId).json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["id"] as? String, let tool = json["tool"] as? String
        else { return nil }
        let waiter = (json["waiter_pid"] as? NSNumber)?.int32Value
        let answerable = waiter.map { kill($0, 0) == 0 } ?? false
        return PermissionRequest(
            id: id,
            tool: tool,
            detail: Scanner.nonEmpty(json["detail"]),
            input: Scanner.nonEmpty(json["input"]),
            alwaysAllow: describe(suggestions: json["suggestions"] as? [[String: Any]] ?? []),
            answerable: answerable && !["AskUserQuestion", "ExitPlanMode"].contains(tool),
            requestedAt: (json["requested_at"] as? NSNumber)?.doubleValue
        )
    }

    /// Claude Code's permission suggestions in words: "Bash(npm test:*) in this project", "Switch to accept
    /// edits mode", "Access to ~/data".
    static func describe(suggestions: [[String: Any]]) -> [String] {
        suggestions.compactMap { suggestion in
            let scope: String? = switch suggestion["destination"] as? String {
            case "session": "for this session"
            case "localSettings", "projectSettings": "in this project"
            case "userSettings": "everywhere"
            default: nil
            }
            var text: String?
            switch suggestion["type"] as? String {
            case "addRules", "replaceRules":
                let rules = (suggestion["rules"] as? [[String: Any]] ?? []).compactMap { rule -> String? in
                    guard let tool = rule["toolName"] as? String else { return nil }
                    let content = (rule["ruleContent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    return content.map { "\(tool)(\($0))" } ?? tool
                }
                text = rules.isEmpty ? nil : rules.joined(separator: ", ")
            case "setMode":
                let mode = (suggestion["mode"] as? String) ?? ""
                let names = ["acceptEdits": "accept edits", "bypassPermissions": "bypass permissions", "plan": "plan"]
                text = "Switch to \(names[mode] ?? mode) mode"
            case "addDirectories":
                let dirs = (suggestion["directories"] as? [String] ?? []).map { $0.replacingOccurrences(of: Scanner.home, with: "~") }
                text = dirs.isEmpty ? nil : "Access to " + dirs.joined(separator: ", ")
            default:
                text = nil
            }
            guard let text else { return nil }
            return scope.map { "\(text) \($0)" } ?? text
        }
    }
}
