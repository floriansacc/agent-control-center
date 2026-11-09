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

    func testSplitFields() {
        let (fields, rest) = splitFields("  12   34 ttys001   /a b/c d  ", count: 3)
        XCTAssertEqual(fields, ["12", "34", "ttys001"])
        XCTAssertEqual(rest, "/a b/c d")
    }
}
