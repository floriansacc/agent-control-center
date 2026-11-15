import Foundation

public struct ScanOptions: Sendable {
    /// lsof is the expensive part of a scan; UIs skip it while nothing shows ports.
    public var includePorts: Bool
    /// Process-name prefixes hidden from `otherPorts`. Ports owned by a session are always kept.
    public var ignoredProcesses: [String]
    /// Hide ports >= 49152 from `otherPorts`: almost always app IPC, not dev servers.
    public var hideEphemeralPorts: Bool
    /// Run `git status` per project (staged / changed files, ahead / behind). Without it, only the branch.
    public var includeGit: Bool

    public static let defaultIgnored = [
        "ControlCenter", "rapportd", "Code Helper", "Electron", "Google Drive", "figma_agent",
        "Notion", "Spotify", "Dropbox", "Slack", "Discord", "Claude", Paths.appExecutableName,
    ]

    public init(
        includePorts: Bool = true,
        ignoredProcesses: [String] = ScanOptions.defaultIgnored,
        hideEphemeralPorts: Bool = true,
        includeGit: Bool = true
    ) {
        self.includePorts = includePorts
        self.ignoredProcesses = ignoredProcesses
        self.hideEphemeralPorts = hideEphemeralPorts
        self.includeGit = includeGit
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
                lastResponse: Self.nonEmpty(data["last_response"]),
                lastTool: Self.nonEmpty(data["last_tool"]),
                toolDetail: Self.nonEmpty(data["tool_detail"]),
                message: Self.nonEmpty(data["message"]),
                host: Self.detectHost(
                    procs, pid: pid,
                    termProgram: data["term_program"] as? String,
                    entrypoint: data["entrypoint"] as? String
                ),
                tty: proc?.tty ?? Self.nonEmpty(data["tty"]),
                itermSessionId: Self.nonEmpty(data["iterm_session_id"]),
                statusFile: url.path,
                ports: [],
                model: Self.nonEmpty(data["model_id"]).map(Session.modelDisplayName),
                contextTokens: (data["context_tokens"] as? NSNumber)?.intValue,
                customTitle: Self.nonEmpty(data["custom_title"]),
                aiTitle: Self.nonEmpty(data["ai_title"]),
                rootDir: Self.nonEmpty(data["project_dir"])
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
                status: .untracked, host: Self.detectHost(procs, pid: p.pid, termProgram: nil, entrypoint: nil),
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

        let statusLines = readStatusLines(liveSessionIds: Set(sessions.compactMap(\.sessionId)), now: now)
        Self.applyContext(&sessions, statusLines: statusLines)

        // One git call per distinct folder, in parallel (30–100 ms each).
        let dirs = Array(Set(sessions.map(\.cwd).filter { !$0.isEmpty }))
        var results = [GitInfo?](repeating: nil, count: dirs.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
                out[i] = options.includeGit ? gitStatus(dirs[i]) : GitInfo(branch: gitBranch(dirs[i]), status: nil)
            }
        }
        let git = Dictionary(uniqueKeysWithValues: zip(dirs, results))
        for i in sessions.indices {
            guard let info = git[sessions[i].cwd] ?? nil else { continue }
            sessions[i].branch = info.branch
            sessions[i].git = info.status
        }

        sessions.sort {
            ($0.status.rank, -($0.updatedAt ?? 0), $0.key) < ($1.status.rank, -($1.updatedAt ?? 0), $1.key)
        }

        return Snapshot(
            sessions: sessions,
            otherPorts: otherPorts,
            portsScanned: options.includePorts,
            scannedAt: (now * 1000).rounded(),
            menuBarAppRunning: procs.all.contains { ($0.comm as NSString).lastPathComponent == Paths.appExecutableName },
            rateLimits: Self.rateLimits(from: statusLines, now: now),
            gitScanned: options.includeGit
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

    // MARK: - Status line data

    /// Files written by agent-statusline.sh, by session id. Stale ones are removed: the session ended, or
    /// the status line stopped running for it a day ago.
    private func readStatusLines(liveSessionIds: Set<String>, now: Double) -> [String: [String: Any]] {
        let dir = Paths.statusLineDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var result: [String: [String: Any]] = [:]
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["session_id"] as? String
            else { continue }
            let age = now - ((obj["updated_at"] as? NSNumber)?.doubleValue ?? 0)
            if age > 86400 || (!liveSessionIds.contains(sid) && age > 3600) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            result[sid] = obj
        }
        return result
    }

    /// Fills model, effort and context from the status line where it runs (exact), keeping the hook's
    /// transcript-based values otherwise. Window sizes reported for a model also apply to its other sessions.
    static func applyContext(_ sessions: inout [Session], statusLines: [String: [String: Any]]) {
        var sizeByModel: [String: Int] = [:]
        for line in statusLines.values {
            guard let size = (line["context_size"] as? NSNumber)?.intValue, size > 0 else { continue }
            if let name = nonEmpty(line["model"]) { sizeByModel[name] = max(sizeByModel[name] ?? 0, size) }
            if let id = nonEmpty(line["model_id"]) { sizeByModel[Session.modelDisplayName(id)] = max(sizeByModel[Session.modelDisplayName(id)] ?? 0, size) }
        }
        for i in sessions.indices {
            if let sid = sessions[i].sessionId, let line = statusLines[sid] {
                if let model = nonEmpty(line["model"]) ?? nonEmpty(line["model_id"]).map(Session.modelDisplayName) {
                    sessions[i].model = model
                }
                sessions[i].effort = nonEmpty(line["effort"])
                if let tokens = (line["context_tokens"] as? NSNumber)?.intValue, tokens > 0 { sessions[i].contextTokens = tokens }
                if let size = (line["context_size"] as? NSNumber)?.intValue, size > 0 { sessions[i].contextSize = size }
            }
            if sessions[i].contextSize == nil, let model = sessions[i].model, let size = sizeByModel[model] {
                // A transcript count above that size means a larger window than the one seen: leave it unknown.
                if (sessions[i].contextTokens ?? 0) <= size { sessions[i].contextSize = size }
            }
        }
    }

    /// The freshest plan limits any status line reported, without windows that already reset.
    static func rateLimits(from statusLines: [String: [String: Any]], now: Double) -> RateLimits? {
        let newest = statusLines.values
            .filter { $0["rate_limits"] is [String: Any] }
            .max { (($0["updated_at"] as? NSNumber)?.doubleValue ?? 0) < (($1["updated_at"] as? NSNumber)?.doubleValue ?? 0) }
        guard let newest, let limits = newest["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (w["resets_at"] as? NSNumber)?.doubleValue
            if let resets, resets <= now { return nil }
            return UsageWindow(usedPercent: used, resetsAt: resets)
        }
        let result = RateLimits(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            updatedAt: (newest["updated_at"] as? NSNumber)?.doubleValue ?? now
        )
        return result.fiveHour == nil && result.sevenDay == nil ? nil : result
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

    static func detectHost(_ procs: ProcessTable, pid: Int32?, termProgram: String?, entrypoint: String?) -> SessionHost {
        if entrypoint == "claude-desktop" { return .claudeDesktop }
        if let pid, let proc = procs[pid] {
            for a in procs.ancestors(of: pid) {
                // Before the terminals: a terminal launched from the desktop app is not hosted by it, but the
                // desktop app runs its sessions under /Applications/Claude.app/Contents/Helpers/disclaimer.
                if a.comm.contains("/Claude.app/Contents/") { return .claudeDesktop }
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

    struct GitInfo {
        var branch: String?
        var status: GitStatus?
    }

    /// Branch only (cheap): used when the full status is not wanted.
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

    /// Branch, ahead / behind, staged and changed files. `--no-optional-locks` keeps it from taking the
    /// index lock (and racing a commit the agent is making).
    private func gitStatus(_ dir: String) -> GitInfo? {
        let res = Shell.run("/usr/bin/git", [
            "--no-optional-locks", "-C", dir, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all",
        ], timeout: 3)
        guard res.ok else { return nil } // not a repository
        return Self.parseGitStatus(res.stdout)
    }

    /// Parses `git status --porcelain=v2 --branch -z`. Like VS Code's Source Control: a file can be both
    /// staged and changed; untracked and conflicted files count as changed.
    static func parseGitStatus(_ output: String, maxPaths: Int = 30) -> GitInfo {
        var branch: String?
        var status = GitStatus()
        var records = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        func add(_ path: Substring, staged: Bool, changed: Bool) {
            if staged {
                status.stagedCount += 1
                if status.staged.count < maxPaths { status.staged.append(String(path)) }
            }
            if changed {
                status.changedCount += 1
                if status.changed.count < maxPaths { status.changed.append(String(path)) }
            }
        }
        // Fields before the path: "1 XY sub mH mI mW hH hI path", "2 XY sub mH mI mW hH hI Xscore path\0orig",
        // "u XY sub m1 m2 m3 mW h1 h2 h3 path".
        func path(_ record: Substring, after fields: Int) -> Substring {
            record.split(separator: " ", maxSplits: fields, omittingEmptySubsequences: false).last ?? ""
        }
        while let record = records.next() {
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                if record.hasPrefix("# branch.head ") {
                    let head = record.dropFirst("# branch.head ".count)
                    branch = head == "(detached)" ? nil : String(head)
                } else if record.hasPrefix("# branch.ab ") {
                    let parts = record.split(separator: " ")
                    if parts.count >= 4 {
                        status.ahead = Int(parts[2].dropFirst())
                        status.behind = Int(parts[3].dropFirst())
                    }
                }
            case "1", "2":
                let xy = Array(record.dropFirst(2).prefix(2))
                guard xy.count == 2 else { continue }
                add(path(record, after: kind == "1" ? 8 : 9), staged: xy[0] != ".", changed: xy[1] != ".")
                if kind == "2" { _ = records.next() } // the rename's original path
            case "u":
                add(path(record, after: 10), staged: false, changed: true)
            case "?":
                add(record.dropFirst(2), staged: false, changed: true)
            default:
                continue // "!" ignored files
            }
        }
        return GitInfo(branch: branch, status: status)
    }
}
