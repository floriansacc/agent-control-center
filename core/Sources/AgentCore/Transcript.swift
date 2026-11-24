import Foundation

/// One item of a session's conversation, read from its Claude Code transcript.
public struct TranscriptEntry: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// What you sent.
        case prompt(String)
        /// Claude's text, in markdown.
        case reply(String)
        case tool(ToolCall)
        /// Something that happened to the conversation, e.g. "Conversation compacted".
        case event(String)
    }

    public var id: String
    /// Unix seconds.
    public var timestamp: Double?
    public var kind: Kind
}

public struct ToolCall: Sendable, Hashable {
    /// The API's tool_use id; its result refers to it.
    public var id: String
    public var name: String
    /// One line about the call, like the hook's `tool_detail`: a command's description, a file name…
    public var detail: String?
    /// The input worth reading in full (the whole command, the file path, the subagent's prompt…).
    public var input: String?
    public var result: ToolResult?

    public var label: String { Session.toolLabel(name) }
}

/// What a tool call returned.
public struct ToolResult: Sendable, Hashable {
    public var isError: Bool
    /// The start of the output. Not shown yet: it is kept for a later version that shows tool outputs.
    public var preview: String
}

/// Reads a Claude Code transcript (`~/.claude/projects/<folder>/<session>.jsonl`) incrementally: the first
/// `update()` reads the file's tail, later ones only the lines appended since.
///
/// Not thread-safe: use it from one queue at a time.
public final class TranscriptReader: @unchecked Sendable {
    public let url: URL
    public private(set) var entries: [TranscriptEntry] = []

    /// Older entries are dropped past this: the window shows recent turns, not the whole history.
    public static let maxEntries = 400
    /// The first read starts this far from the end. Transcripts reach tens of MB (tool outputs, request logs).
    static let initialTail: UInt64 = 4 << 20
    static let previewLength = 2000

    private var offset: UInt64 = 0
    private var pending = Data()
    /// tool_use id → index in `entries`, to attach results.
    private var toolIndex: [String: Int] = [:]
    private var anonymous = 0
    private let dates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL) {
        self.url = url
    }

    /// Reads what was appended since the last call. Returns true when `entries` changed.
    @discardableResult
    public func update() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var changed = false
        if size < offset {
            // Rewritten from scratch: start over.
            reset()
            changed = true
        }
        guard size > offset else { return changed }

        var start = offset
        var skipPartialLine = false
        if offset == 0, size > Self.initialTail {
            start = size - Self.initialTail
            skipPartialLine = true
        }
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.read(upToCount: Int(size - start))
        else { return changed }
        offset = start + UInt64(data.count)
        if skipPartialLine {
            guard let newline = data.firstIndex(of: 0x0A) else { return changed }
            data = data[data.index(after: newline)...]
        }
        pending.append(data)

        // Complete lines only; a line still being written stays in `pending`.
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            if ingest(pending[lineStart..<newline]) { changed = true }
            lineStart = pending.index(after: newline)
        }
        pending = Data(pending[lineStart...])

        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            reindexTools()
        }
        return changed
    }

    private func reset() {
        offset = 0
        pending = Data()
        entries = []
        toolIndex = [:]
    }

    private func reindexTools() {
        toolIndex = [:]
        for (i, entry) in entries.enumerated() {
            if case let .tool(call) = entry.kind { toolIndex[call.id] = i }
        }
    }

    // MARK: - Parsing

    private static let markers = ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"subtype\":\"compact_boundary\""]
        .map { Data($0.utf8) }

    /// Returns true when the line added or changed an entry.
    private func ingest(_ line: Data) -> Bool {
        // Most lines are bookkeeping (titles, request logs, file snapshots): skip them before parsing.
        guard Self.markers.contains(where: { line.range(of: $0) != nil }),
              let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return false }
        // Subagents' own turns: their parent shows them as one Task / Agent call.
        if json["isSidechain"] as? Bool == true { return false }
        let id = (json["uuid"] as? String) ?? nextAnonymousId()
        let time = (json["timestamp"] as? String).flatMap { dates.date(from: $0)?.timeIntervalSince1970 }

        switch json["type"] as? String {
        case "user":
            return ingestUser(json, id: id, time: time)
        case "assistant":
            return ingestAssistant(json, id: id, time: time)
        case "system":
            guard json["subtype"] as? String == "compact_boundary" else { return false }
            entries.append(TranscriptEntry(id: id, timestamp: time, kind: .event("Conversation compacted")))
            return true
        default:
            return false
        }
    }

    private func ingestUser(_ json: [String: Any], id: String, time: Double?) -> Bool {
        // Meta messages (injected context) and the compaction summary are not something you typed.
        if json["isMeta"] as? Bool == true || json["isCompactSummary"] as? Bool == true { return false }
        guard let message = json["message"] as? [String: Any] else { return false }

        var texts: [String] = []
        var images = 0
        var changed = false
        if let text = message["content"] as? String {
            texts.append(text)
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                case "image":
                    images += 1
                case "tool_result":
                    if attachResult(block) { changed = true }
                default:
                    break
                }
            }
        }

        let raw = texts.joined(separator: "\n")
        if raw.hasPrefix("[Request interrupted by user") {
            entries.append(TranscriptEntry(id: id, timestamp: time, kind: .event("Interrupted")))
            return true
        }
        var prompt = Self.cleanPrompt(raw)
        if images > 0 {
            let note = images == 1 ? "[image]" : "[\(images) images]"
            prompt = prompt.isEmpty ? note : "\(prompt)\n\(note)"
        }
        guard !prompt.isEmpty else { return changed }
        entries.append(TranscriptEntry(id: id, timestamp: time, kind: .prompt(prompt)))
        return true
    }

    private func ingestAssistant(_ json: [String: Any], id: String, time: Double?) -> Bool {
        guard let message = json["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return false }
        var changed = false
        for (i, block) in blocks.enumerated() {
            let entryId = "\(id):\(i)"
            switch block["type"] as? String {
            case "text":
                let text = ((block["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Claude Code's placeholder when a turn produced nothing.
                guard !text.isEmpty, text != "No response requested." else { continue }
                entries.append(TranscriptEntry(id: entryId, timestamp: time, kind: .reply(text)))
                changed = true
            case "tool_use":
                guard let toolId = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = (block["input"] as? [String: Any]) ?? [:]
                let described = Self.describe(tool: name, input: input)
                let call = ToolCall(id: toolId, name: name, detail: described.detail, input: described.input)
                toolIndex[toolId] = entries.count
                entries.append(TranscriptEntry(id: entryId, timestamp: time, kind: .tool(call)))
                changed = true
            default:
                // Thinking blocks are not shown.
                continue
            }
        }
        return changed
    }

    private func attachResult(_ block: [String: Any]) -> Bool {
        guard let toolId = block["tool_use_id"] as? String,
              let index = toolIndex[toolId], index < entries.count,
              case var .tool(call) = entries[index].kind
        else { return false }
        var text = ""
        if let content = block["content"] as? String {
            text = content
        } else if let parts = block["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        call.result = ToolResult(isError: block["is_error"] as? Bool == true, preview: String(text.prefix(Self.previewLength)))
        entries[index].kind = .tool(call)
        return true
    }

    private func nextAnonymousId() -> String {
        anonymous += 1
        return "line-\(anonymous)"
    }

    // MARK: - Text helpers

    /// What you typed, without the context Claude Code and the IDEs add around it: IDE selections, system
    /// reminders, the output of local commands. Slash commands read as you typed them ("/model opus").
    static func cleanPrompt(_ raw: String) -> String {
        var text = raw
        if let name = firstMatch(#"<command-name>(.*?)</command-name>"#, in: text) {
            let args = firstMatch(#"<command-args>(.*?)</command-args>"#, in: text) ?? ""
            text = args.isEmpty ? name : "\(name) \(args)"
        }
        if let command = firstMatch(#"<bash-input>(.*?)</bash-input>"#, in: text) {
            text = "! \(command)"
        }
        text = text.replacingOccurrences(
            of: #"<(ide_[a-z_]+|system-reminder|local-command-[a-z]+|bash-std[a-z]+|task-notification|command-[a-z]+)>[\s\S]*?</\1>"#,
            with: "",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return text[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A one-line detail and the input worth reading in full, per tool (mirrors the hook's `detail`).
    static func describe(tool: String, input: [String: Any]) -> (detail: String?, input: String?) {
        func string(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let detail: String?
        let full: String?
        switch tool {
        case "Bash":
            detail = string("description") ?? string("command")
            full = string("command")
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = string("file_path") ?? string("notebook_path")
            detail = path.map { ($0 as NSString).lastPathComponent }
            full = path
        case "Grep", "Glob":
            detail = string("pattern")
            full = [string("pattern"), string("path").map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
        case "WebFetch":
            let url = string("url")
            detail = url.flatMap { URL(string: $0)?.host } ?? url
            full = url
        case "WebSearch":
            detail = string("query")
            full = detail
        case "Task", "Agent":
            detail = string("description") ?? string("subagent_type")
            full = string("prompt")
        case "TodoWrite":
            let todos = (input["todos"] as? [[String: Any]]) ?? []
            detail = todos.first { $0["status"] as? String == "in_progress" }
                .flatMap { ($0["activeForm"] as? String) ?? ($0["content"] as? String) }
            full = todos.map { todo in
                let mark = switch todo["status"] as? String {
                case "completed": "☑"
                case "in_progress": "▸"
                default: "☐"
                }
                return "\(mark) \((todo["content"] as? String) ?? "")"
            }.joined(separator: "\n")
        case "Skill":
            detail = string("skill") ?? string("command")
            full = detail
        default:
            detail = nil
            full = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { $0 == "{}" ? nil : $0 }
        }
        let line = detail?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (line.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }, full.map { String($0.prefix(4000)) })
    }
}

public enum Transcript {
    /// The transcript of a session: the path the hook reported, else Claude Code's usual location.
    public static func url(for session: Session) -> URL? {
        url(sessionId: session.sessionId, transcriptPath: session.transcriptPath, dirs: [session.rootDir, session.cwd].compactMap { $0 })
    }

    /// `dirs`: folders the session may have started in, tried first.
    public static func url(sessionId: String?, transcriptPath: String? = nil, dirs: [String] = []) -> URL? {
        let fm = FileManager.default
        if let path = transcriptPath, fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard let sessionId, !sessionId.isEmpty, !sessionId.contains("/") else { return nil }
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let file = "\(sessionId).jsonl"
        for dir in dirs where !dir.isEmpty {
            let candidate = projects.appendingPathComponent(projectFolderName(dir)).appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // The folder name scheme may change: look in every project.
        let folders = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent(file) }.first { fm.fileExists(atPath: $0.path) }
    }

    /// Claude Code names a project's folder after its path, with every character other than an ASCII letter
    /// or digit replaced by "-": "/Users/me/my.app" → "-Users-me-my-app".
    static func projectFolderName(_ dir: String) -> String {
        String(dir.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
}
