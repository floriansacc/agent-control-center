import Foundation

/// Reads the Claude desktop app's own records of its Code sessions.
///
/// The app keeps one JSON file per session under
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`.
/// Its `sessionId` (`local_…`) is what the app's `claude://` links take; `cliSessionId` is the Claude Code
/// session id our hook sees. Resuming a session gives it a new CLI id; the older ones are kept in
/// `priorCliSessionIds`.
public enum ClaudeDesktop {
    public static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// The desktop app's `local_…` id for a Claude Code session id, or nil when it is not a desktop session.
    public static func localSessionId(forCliSession cliId: String, in dir: URL = sessionsDir) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        var priorMatch: String?
        for case let url as URL in enumerator where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            // Each record holds a whole session (messages included); only read when the id appears in it.
            guard let data = try? Data(contentsOf: url), data.range(of: Data(cliId.utf8)) != nil,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let localId = json["sessionId"] as? String
            else { continue }
            if json["cliSessionId"] as? String == cliId { return localId }
            if (json["priorCliSessionIds"] as? [String])?.contains(cliId) == true { priorMatch = localId }
        }
        return priorMatch
    }
}
