@testable import AgentCore
import XCTest

final class AgentCoreTests: XCTestCase {
    func testParseProcessTableKeepsSpacesInComm() {
        let table = ProcessTable.parse("""
              1     0 ??       /sbin/launchd
           2650  1253 ??       /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)
           9894  2650 ??       /Users/me/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude
          56700  3245 ttys000  claude
        """)
        XCTAssertEqual(table[2650]?.comm, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)")
        XCTAssertEqual(table[56700]?.tty, "ttys000")
        XCTAssertTrue(table[9894]!.isClaude)
        XCTAssertTrue(table[56700]!.isClaude)
        XCTAssertTrue(table.isSelfOrDescendant(ancestor: 2650, pid: 9894))
        XCTAssertFalse(table.isSelfOrDescendant(ancestor: 56700, pid: 9894))
    }

    func testParseListenersDedupesIPv4AndIPv6() {
        let listeners = Scanner.parseListeners("""
        p962
        crapportd
        f14
        n*:54495
        f15
        n*:54495
        p300
        cnode
        f20
        n[::1]:5173
        f21
        n127.0.0.1:3000
        """)
        XCTAssertEqual(listeners.map(\.port), [3000, 5173, 54495])
        XCTAssertEqual(listeners.first { $0.port == 5173 }?.address, "[::1]")
        XCTAssertEqual(listeners.first { $0.port == 3000 }?.command, "node")
    }

    func testSessionDirPrefersRootUnlessRootIsHome() {
        let home = Scanner.home
        XCTAssertEqual(Scanner.sessionDir(projectDir: "/work/app", cwd: "/work/app/src"), "/work/app")
        XCTAssertEqual(Scanner.sessionDir(projectDir: home, cwd: "\(home)/code/app"), "\(home)/code/app")
        XCTAssertEqual(Scanner.sessionDir(projectDir: home, cwd: home), home)
        XCTAssertEqual(Scanner.sessionDir(projectDir: nil, cwd: "/work/app"), "/work/app")
        XCTAssertEqual(Scanner.sessionDir(projectDir: "", cwd: "/work/app"), "/work/app")
    }

    func testBroadDirs() {
        XCTAssertTrue(Scanner.isBroadDir("/"))
        XCTAssertTrue(Scanner.isBroadDir(Scanner.home))
        XCTAssertTrue(Scanner.isBroadDir(nil))
        XCTAssertFalse(Scanner.isBroadDir("\(Scanner.home)/code/app"))
        XCTAssertFalse(Scanner.isWithin("/work/app", "/work/application"))
        XCTAssertTrue(Scanner.isWithin("/work/app", "/work/app/web"))
    }

    func testNoiseFilter() {
        let options = ScanOptions()
        func l(_ port: Int, _ cmd: String) -> Listener { Listener(port: port, address: "*", pid: 1, command: cmd) }
        XCTAssertTrue(Scanner.isNoise(l(8828, "Code Helper (Plugin)"), options))
        XCTAssertTrue(Scanner.isNoise(l(57171, "dart"), options))
        XCTAssertFalse(Scanner.isNoise(l(3306, "com.docker.backend"), options))
        XCTAssertFalse(Scanner.isNoise(l(57171, "dart"), ScanOptions(hideEphemeralPorts: false)))
    }

    func testVSCodeWindowMatchesByAncestryBeforeFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acc-\(UUID().uuidString)")
        setenv("AGENT_STATUS_DIR", dir.path, 1)
        defer {
            unsetenv("AGENT_STATUS_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: VSCodeWindows.dir, withIntermediateDirectories: true)
        // Window 100 has the parent folder open; window 200 owns the session (its extension host spawned claude).
        let windows = [
            VSCodeWindow(extHostPid: 100, roots: ["/work"], workspaceFile: nil, terminalShellPids: [101]),
            VSCodeWindow(extHostPid: 200, roots: ["/work/app"], workspaceFile: "/work/app.code-workspace", terminalShellPids: []),
        ]
        for w in windows {
            try JSONEncoder().encode(w).write(to: VSCodeWindows.dir.appendingPathComponent("\(w.extHostPid).json"))
        }
        let procs = ProcessTable.parse("""
          100 1 ?? /Applications/Visual Studio Code.app/Code Helper (Plugin)
          101 100 ttys001 -zsh
          200 1 ?? /Applications/Visual Studio Code.app/Code Helper (Plugin)
          201 200 ?? /x/native-binary/claude
          202 101 ttys001 claude
        """)
        func session(_ pid: Int32?, _ cwd: String) -> Session {
            Session(key: "k", pid: pid, cwd: cwd, project: "p", status: .idle, host: .vscodePanel, ports: [])
        }
        XCTAssertEqual(VSCodeWindows.window(for: session(201, "/work/app"), procs)?.openTarget, "/work/app.code-workspace")
        XCTAssertEqual(VSCodeWindows.window(for: session(202, "/work/app"), procs)?.extHostPid, 100, "terminal shell pid wins over folder")
        XCTAssertEqual(VSCodeWindows.window(for: session(nil, "/work/app/src"), procs)?.extHostPid, 200, "deepest root by folder")
        XCTAssertEqual(VSCodeWindows.window(for: session(nil, "/work/lib"), procs)?.openTarget, "/work")
    }

    func testSummaryShowsPromptDuringTurnAndReplyAfter() {
        var s = Session(key: "k", cwd: "/w", project: "w", status: .working, host: .iterm, ports: [])
        s.lastPrompt = "fix the colors"
        s.lastResponse = "Fixed the color mapping"
        XCTAssertEqual(s.summary, "fix the colors")
        s.status = .done
        XCTAssertEqual(s.summary, "Fixed the color mapping")
        s.lastResponse = nil
        XCTAssertEqual(s.summary, "fix the colors")
    }

    func testClaudeDesktopHost() {
        let procs = ProcessTable.parse("""
          10 1 ?? /Applications/Claude.app/Contents/MacOS/Claude
          11 10 ?? /Applications/Claude.app/Contents/Helpers/disclaimer
          12 11 ?? /Users/me/Library/Application Support/Claude/claude-code/2.1.325/x/claude.app/Contents/MacOS/claude
          20 1 ?? /Applications/iTerm.app/Contents/MacOS/iTerm2
          21 20 ttys001 claude
        """)
        XCTAssertEqual(Scanner.detectHost(procs, pid: 12, termProgram: nil, entrypoint: nil), .claudeDesktop)
        XCTAssertEqual(Scanner.detectHost(procs, pid: nil, termProgram: nil, entrypoint: "claude-desktop"), .claudeDesktop)
        XCTAssertEqual(Scanner.detectHost(procs, pid: 21, termProgram: nil, entrypoint: "cli"), .iterm)
    }

    func testClaudeDesktopLocalSessionId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acc-desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let org = dir.appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        let record = #"{"sessionId":"local_aaa","cliSessionId":"cli-new","priorCliSessionIds":["cli-old"]}"#
        try Data(record.utf8).write(to: org.appendingPathComponent("local_aaa.json"))
        XCTAssertEqual(ClaudeDesktop.localSessionId(forCliSession: "cli-new", in: dir), "local_aaa")
        XCTAssertEqual(ClaudeDesktop.localSessionId(forCliSession: "cli-old", in: dir), "local_aaa")
        XCTAssertNil(ClaudeDesktop.localSessionId(forCliSession: "cli-unknown", in: dir))
    }

    func testHookSetupRegistersOnceAndKeepsOtherHooks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acc-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        let script = dir.appendingPathComponent("bundle/agent-status.sh")
        let installed = dir.appendingPathComponent("support/agent-status.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try Data("#!/bin/sh\necho line\n".utf8).write(to: HookSetup.statusLineScript(nextTo: script))
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/cc-status"}]}]}}"#
        try Data(original.utf8).write(to: settings)

        XCTAssertFalse(HookSetup.isInstalled(settingsURL: settings))
        try HookSetup.install(bundledScript: script, settingsURL: settings, installedScript: installed)
        XCTAssertTrue(HookSetup.isInstalled(settingsURL: settings))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "opus")
        let hooks = try XCTUnwrap(json["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks.count, HookSetup.events.count)
        let stopCommands = hooks["Stop"]?.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        XCTAssertEqual(stopCommands, ["/x/cc-status", "\"\(installed.path)\""])
        let statusLine = try XCTUnwrap(json["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "\"\(HookSetup.statusLineScript(nextTo: installed).path)\"")

        // Running it again changes nothing and makes no second backup.
        try HookSetup.install(bundledScript: script, settingsURL: settings, installedScript: installed)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(backups[0]), encoding: .utf8), original)
    }

    func testIdleFoldingAndActivity() {
        var s = Session(key: "k", cwd: "/w", project: "w", status: .done, host: .iterm, ports: [])
        s.statusSince = 1000
        XCTAssertTrue(s.isIdle(longerThan: 3600, now: 1000 + 3601))
        XCTAssertFalse(s.isIdle(longerThan: 3600, now: 1000 + 60))
        s.status = .waiting
        XCTAssertFalse(s.isIdle(longerThan: 3600, now: 1000 + 99999), "sessions that need you are never folded")

        s.status = .working
        s.lastTool = "Bash"
        s.toolDetail = "Run the tests"
        XCTAssertEqual(s.activity, "Bash · Run the tests")
        s.lastTool = "mcp__figma__get_screenshot"
        s.toolDetail = nil
        XCTAssertEqual(s.activity, "figma get_screenshot")
        s.status = .done
        XCTAssertNil(s.activity)
    }

    func testHookSetupKeepsAnExistingStatusLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acc-sl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        let script = dir.appendingPathComponent("bundle/agent-status.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try Data("#!/bin/sh\n".utf8).write(to: HookSetup.statusLineScript(nextTo: script))
        try Data(#"{"statusLine":{"type":"command","command":"mine.sh"}}"#.utf8).write(to: settings)
        try HookSetup.install(bundledScript: script, settingsURL: settings, installedScript: dir.appendingPathComponent("support/agent-status.sh"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual((json["statusLine"] as? [String: Any])?["command"] as? String, "mine.sh")
    }

    func testParseGitStatus() {
        let out = [
            "# branch.oid abc", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 h1 h2 Sources/staged only.swift",
            "1 .M N... 100644 100644 100644 h1 h2 README.md",
            "1 MM N... 100644 100644 100644 h1 h2 both.txt",
            "2 R. N... 100644 100644 100644 h1 h2 R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt",
            "? untracked dir/file.txt",
            "! ignored.log",
        ].joined(separator: "\0") + "\0"
        let info = Scanner.parseGitStatus(out)
        XCTAssertEqual(info.branch, "main")
        XCTAssertEqual(info.status?.ahead, 2)
        XCTAssertEqual(info.status?.behind, 1)
        XCTAssertEqual(info.status?.staged, ["Sources/staged only.swift", "both.txt", "new name.txt"])
        XCTAssertEqual(info.status?.changed, ["README.md", "both.txt", "conflict.txt", "untracked dir/file.txt"])
        XCTAssertEqual(Scanner.parseGitStatus("# branch.head (detached)\0").branch, nil)
    }

    func testModelNamesAndContext() {
        XCTAssertEqual(Session.modelDisplayName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(Session.modelDisplayName("claude-sonnet-4-5-20250929[1m]"), "Sonnet 4.5")
        XCTAssertEqual(Session.modelDisplayName("claude-fable-5"), "Fable 5")
        XCTAssertEqual(Session.modelDisplayName("gpt-x"), "gpt-x")

        // A size reported by one session's status line applies to other sessions on the same model.
        var sessions = [
            Session(key: "a", sessionId: "a", cwd: "/a", project: "a", status: .idle, host: .iterm, ports: [], model: "Opus 5.5", contextTokens: 50000),
            Session(key: "b", sessionId: "b", cwd: "/b", project: "b", status: .idle, host: .vscodePanel, ports: [], model: "Opus 5.5", contextTokens: 100_000),
            Session(key: "c", sessionId: "c", cwd: "/c", project: "c", status: .idle, host: .vscodePanel, ports: [], model: "Opus 5.5", contextTokens: 300_000),
        ]
        let lines: [String: [String: Any]] = ["a": ["model": "Opus 5.5", "effort": "high", "context_tokens": 60000, "context_size": 200_000]]
        Scanner.applyContext(&sessions, statusLines: lines)
        XCTAssertEqual(sessions[0].contextTokens, 60000)
        XCTAssertEqual(sessions[0].effort, "high")
        XCTAssertEqual(sessions[1].contextPercent, 50)
        XCTAssertNil(sessions[2].contextSize, "more tokens than the known size: a bigger window, size unknown")

        let limits = Scanner.rateLimits(from: ["a": [
            "updated_at": 100.0,
            "rate_limits": ["five_hour": ["used_percentage": 34, "resets_at": 50], "seven_day": ["used_percentage": 61, "resets_at": 999]],
        ]], now: 100)
        XCTAssertNil(limits?.fiveHour, "a window that already reset is dropped")
        XCTAssertEqual(limits?.sevenDay?.usedPercent, 61)
    }

    func testSplitFields() {
        let (fields, rest) = splitFields("  12   34 ttys001   /a b/c d  ", count: 3)
        XCTAssertEqual(fields, ["12", "34", "ttys001"])
        XCTAssertEqual(rest, "/a b/c d")
    }
}
