import Foundation

public struct ProcInfo: Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var tty: String
    public var comm: String

    public var isClaude: Bool { (comm as NSString).lastPathComponent == "claude" }
}

public struct ProcessTable: Sendable {
    public let byPid: [Int32: ProcInfo]

    public subscript(pid: Int32) -> ProcInfo? { byPid[pid] }
    public var all: Dictionary<Int32, ProcInfo>.Values { byPid.values }

    public static func read() -> ProcessTable {
        parse(Shell.output("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="]))
    }

    /// Parses `ps -axo pid=,ppid=,tty=,comm=`. comm is last and may contain spaces.
    static func parse(_ output: String) -> ProcessTable {
        var procs: [Int32: ProcInfo] = [:]
        for line in output.split(separator: "\n") {
            let (fields, rest) = splitFields(Substring(line), count: 3)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), !rest.isEmpty else { continue }
            procs[pid] = ProcInfo(pid: pid, ppid: ppid, tty: String(fields[2]), comm: rest)
        }
        return ProcessTable(byPid: procs)
    }

    /// pid's ancestors, nearest first.
    public func ancestors(of pid: Int32) -> [ProcInfo] {
        var result: [ProcInfo] = []
        var current = byPid[pid]
        while let cur = current, cur.ppid > 1, result.count < 64 {
            guard let parent = byPid[cur.ppid] else { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    public func isSelfOrDescendant(ancestor: Int32, pid: Int32) -> Bool {
        pid == ancestor || ancestors(of: pid).contains { $0.pid == ancestor }
    }
}

/// Splits off the first `count` whitespace-separated fields and returns the trimmed remainder.
func splitFields(_ line: Substring, count: Int) -> ([Substring], String) {
    var fields: [Substring] = []
    var rest = line[...]
    while fields.count < count {
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            if !rest.isEmpty { fields.append(rest) }
            rest = ""
            break
        }
        fields.append(rest[..<end])
        rest = rest[end...]
    }
    return (fields, rest.trimmingCharacters(in: .whitespaces))
}
