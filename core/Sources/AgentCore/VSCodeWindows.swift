import Foundation

/// Registry of open VS Code windows, written by the extension in each window
/// (`~/.claude/agent-status/.windows/<extension host pid>.json`, see vscode/windows.js).
///
/// Lets agentctl raise the exact window owning a session: `code <folder>` only focuses an existing
/// window when given that window's root, and a session's folder is not always the root.
public struct VSCodeWindow: Codable, Sendable {
    /// The window's extension host. Claude panel sessions are its direct children.
    public var extHostPid: Int32
    public var roots: [String]
    public var workspaceFile: String?
    /// Shell pids of the window's integrated terminals.
    public var terminalShellPids: [Int32]

    /// What to pass to `code` so VS Code focuses this window instead of opening a new one.
    public var openTarget: String? { workspaceFile ?? roots.first }
}

public enum VSCodeWindows {
    static var dir: URL { Paths.statusDir.appendingPathComponent(".windows") }

    /// Registered windows whose extension host is still alive; stale entries are deleted.
    static func all(_ procs: ProcessTable) -> [VSCodeWindow] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let window = try? JSONDecoder().decode(VSCodeWindow.self, from: data) else { return nil }
            guard procs[window.extHostPid] != nil else {
                // Window closed or VS Code quit without deactivating the extension.
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return window
        }
    }

    /// The window hosting a session: by process ancestry first (exact), then by folder.
    public static func window(for session: Session, _ procs: ProcessTable) -> VSCodeWindow? {
        let windows = all(procs)
        if let pid = session.pid {
            let chain = Set([pid] + procs.ancestors(of: pid).map(\.pid))
            if let exact = windows.first(where: { chain.contains($0.extHostPid) || !chain.isDisjoint(with: $0.terminalShellPids) }) {
                return exact
            }
        }
        guard !session.cwd.isEmpty else { return nil }
        return windows
            .compactMap { w in w.roots.filter { Scanner.isWithin($0, session.cwd) }.max { $0.count < $1.count }.map { (w, $0.count) } }
            .max { $0.1 < $1.1 }?.0
    }
}
