import Foundation

public struct ScanOptions: Sendable {
    /// lsof is the expensive part of a scan; UIs skip it while nothing shows ports.
    public var includePorts: Bool
    /// Process-name prefixes hidden from `otherPorts`. Ports owned by a session are always kept.
    public var ignoredProcesses: [String]
    /// Hide ports >= 49152 from `otherPorts`: almost always app IPC, not dev servers.
    public var hideEphemeralPorts: Bool

    public static let defaultIgnored = [
        "ControlCenter", "rapportd", "Code Helper", "Electron", "Google Drive", "figma_agent",
        "Notion", "Spotify", "Dropbox", "Slack", "Discord", "Claude", Paths.appExecutableName,
    ]

    public init(includePorts: Bool = true, ignoredProcesses: [String] = ScanOptions.defaultIgnored, hideEphemeralPorts: Bool = true) {
        self.includePorts = includePorts
        self.ignoredProcesses = ignoredProcesses
        self.hideEphemeralPorts = hideEphemeralPorts
    }
}

/// Builds a snapshot of Claude Code sessions (from hook status files + ps) and listening TCP ports.
public final class Scanner: @unchecked Sendable {
    public static let shared = Scanner()

    /// Status files without a pid (hook could not find the claude process) are dropped after this long.
    static let orphanTTL: TimeInterval = 12 * 3600
    static let branchTTL: TimeInterval = 15

    private let lock = NSLock()
    private var branchCache: [String: (at: Date, branch: String?)] = [:]

    public init() {}

    public func snapshot(_ options: ScanOptions = ScanOptions()) -> Snapshot {
        let now = Date().timeIntervalSince1970
        let procs = ProcessTable.read()

        var sessions: [Session] = []
        var trackedPids = Set<Int32>()

        for (url, data) in readStatusFiles() {
            let pid = (data["pid"] as? NSNumber)?.int32Value
            let proc = pid.flatMap { procs[$0] }
            let alive = proc?.isClaude ?? false
            let updatedAt = (data["updated_at"] as? NSNumber)?.doubleValue ?? 0
            if (pid != nil && !alive) || (pid == nil && now - updatedAt > Self.orphanTTL) {
                // Session crashed or was killed, so SessionEnd never fired.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if let pid { trackedPids.insert(pid) }
            let dir = Self.sessionDir(projectDir: data["project_dir"] as? String, cwd: data["cwd"] as? String)
            sessions.append(Session(
                key: (data["session_id"] as? String) ?? url.path,
                sessionId: data["session_id"] as? String,
                pid: pid,
                cwd: dir,
                project: Self.projectName(dir),
                status: SessionStatus(rawValue: (data["status"] as? String) ?? "") ?? .idle,
                statusSince: (data["status_since"] as? NSNumber)?.doubleValue,
                updatedAt: updatedAt == 0 ? nil : updatedAt,
                startedAt: (data["started_at"] as? NSNumber)?.doubleValue,
                lastPrompt: Self.nonEmpty(data["last_prompt"]),
                lastTool: Self.nonEmpty(data["last_tool"]),
                message: Self.nonEmpty(data["message"]),
                host: Self.detectHost(procs, pid: pid, termProgram: data["term_program"] as? String),
                tty: proc?.tty ?? Self.nonEmpty(data["tty"]),
                itermSessionId: Self.nonEmpty(data["iterm_session_id"]),
                statusFile: url.path,
                ports: []
            ))
        }

        // claude processes the hook has not reported yet (e.g. started before the hook was installed).
        let untracked = procs.all.filter { p in
            p.isClaude && !trackedPids.contains(p.pid) && !procs.ancestors(of: p.pid).contains { $0.isClaude }
        }

        let listeners = options.includePorts ? Self.readListeners() : []
        let cwds = Self.readCwds(Set(untracked.map(\.pid) + listeners.map(\.pid)))

        for p in untracked {
            let cwd = cwds[p.pid] ?? ""
            sessions.append(Session(
                key: "pid:\(p.pid)", pid: p.pid, cwd: cwd,
                project: cwd.isEmpty ? "pid \(p.pid)" : Self.projectName(cwd),
                status: .untracked, host: Self.detectHost(procs, pid: p.pid, termProgram: nil),
                tty: p.tty, ports: []
            ))
        }

        var otherPorts: [Listener] = []
        for var listener in listeners {
            // claude's own listeners (IDE bridge, OAuth callback) are noise.
            if procs[listener.pid]?.isClaude == true { continue }
            listener.cwd = cwds[listener.pid]
            var owner = sessions.firstIndex { s in
                s.pid.map { procs.isSelfOrDescendant(ancestor: $0, pid: listener.pid) } ?? false
            }
            if owner == nil, let lcwd = listener.cwd {
                // Not spawned by an agent but running inside an agent's project, e.g. a dev server from another tab.
                owner = sessions.indices
                    .filter { !Self.isBroadDir(sessions[$0].cwd) && Self.isWithin(sessions[$0].cwd, lcwd) }
                    .max { sessions[$0].cwd.count < sessions[$1].cwd.count }
                if owner != nil { listener.viaCwd = true }
            }
            if let owner {
                sessions[owner].ports.append(listener)
            } else if !Self.isNoise(listener, options) {
                otherPorts.append(listener)
            }
        }

        for i in sessions.indices where !sessions[i].cwd.isEmpty {
            sessions[i].branch = gitBranch(sessions[i].cwd)
        }

        sessions.sort {
            ($0.status.rank, -($0.updatedAt ?? 0), $0.key) < ($1.status.rank, -($1.updatedAt ?? 0), $1.key)
        }

        return Snapshot(
            sessions: sessions,
            otherPorts: otherPorts,
            portsScanned: options.includePorts,
            scannedAt: (now * 1000).rounded(),
            menuBarAppRunning: procs.all.contains { ($0.comm as NSString).lastPathComponent == Paths.appExecutableName }
        )
    }

    // MARK: - Status files

    private func readStatusFiles() -> [(URL, [String: Any])] {
        let dir = Paths.statusDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            // Half-written or corrupt files are skipped this round.
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (url, obj)
        }
    }

    // MARK: - Ports

    static func readListeners() -> [Listener] {
        parseListeners(Shell.output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]))
    }

    /// Parses `lsof -F pcn` field output: p<pid>, c<command>, n<address:port> lines.
    static func parseListeners(_ output: String) -> [Listener] {
        var seen = Set<String>()
        var result: [Listener] = []
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                guard seen.insert("\(pid):\(port)").inserted else { continue }
                result.append(Listener(port: port, address: String(value[..<colon]), pid: pid, command: command))
            default: break
            }
        }
        return result.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    static func readCwds(_ pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let out = Shell.output("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids.map(String.init).joined(separator: ",")])
        var result: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) ?? 0 }
            else if line.first == "n", pid != 0 { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    static func isNoise(_ l: Listener, _ options: ScanOptions) -> Bool {
        if options.ignoredProcesses.contains(where: { !$0.isEmpty && l.command.hasPrefix($0) }) { return true }
        return options.hideEphemeralPorts && l.port >= 49152
    }

    // MARK: - Session helpers

    static func detectHost(_ procs: ProcessTable, pid: Int32?, termProgram: String?) -> SessionHost {
        if let pid, let proc = procs[pid] {
            for a in procs.ancestors(of: pid) {
                if a.comm.contains("/iTerm.app/") || a.comm.contains("/iTermServer") { return .iterm }
                if a.comm.contains("/Visual Studio Code") { return proc.tty == "??" ? .vscodePanel : .vscodeTerminal }
            }
        }
        switch termProgram {
        case "vscode": return .vscodeTerminal
        case "iTerm.app": return .iterm
        default: return .other
        }
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func isWithin(_ dir: String, _ child: String) -> Bool {
        child == dir || child.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// True for "/", "/Users", $HOME: too broad to name a session after or to claim ports by folder.
    static func isBroadDir(_ dir: String?) -> Bool {
        guard let dir, !dir.isEmpty else { return true }
        return isWithin(dir, home)
    }

    /// The folder a session is about: its project root (stable across `cd`), unless that root
    /// is $HOME (claude launched from ~), in which case the current directory says more.
    static func sessionDir(projectDir: String?, cwd: String?) -> String {
        let root = projectDir?.isEmpty == false ? projectDir : nil
        let current = cwd?.isEmpty == false ? cwd : nil
        if isBroadDir(root), let current, !isBroadDir(current) { return current }
        return root ?? current ?? ""
    }

    static func projectName(_ dir: String) -> String {
        let name = (dir as NSString).lastPathComponent
        return name.isEmpty ? dir : name
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private func gitBranch(_ dir: String) -> String? {
        lock.lock()
        if let hit = branchCache[dir], Date().timeIntervalSince(hit.at) < Self.branchTTL {
            lock.unlock()
            return hit.branch
        }
        lock.unlock()
        let out = Shell.output("/usr/bin/git", ["-C", dir, "branch", "--show-current"], timeout: 2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty output means detached HEAD or not a repo.
        let branch = out.isEmpty ? nil : out
        lock.lock()
        branchCache[dir] = (Date(), branch)
        lock.unlock()
        return branch
    }
}
