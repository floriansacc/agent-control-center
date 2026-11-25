import Foundation

/// One file's changes, as `git diff` shows them, parsed into lines with their line numbers.
public struct FileDiff: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// "@@ -12,7 +12,9 @@ func x()": where a block of changes starts.
        case hunk
        case added
        case removed
        case context
        /// "\ No newline at end of file".
        case note
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public var id: Int
        public var kind: Kind
        /// Without the leading "+", "-" or " ".
        public var text: String
        /// Line numbers before and after the change (nil on the side the line is not on).
        public var oldNumber: Int?
        public var newNumber: Int?
    }

    public var lines: [Line] = []
    public var added = 0
    public var removed = 0
    public var isBinary = false
    /// More lines than shown.
    public var truncated = false

    public var isEmpty: Bool { lines.isEmpty && !isBinary }
}

/// `git diff` for one file of a session's working tree.
public enum GitDiff {
    /// The changes of `path` (relative to the repository root, as `git status` lists it): staged ones (index
    /// against HEAD) or not (working tree against the index). An untracked file shows as entirely added.
    /// nil when git fails (not a repository, git missing).
    public static func diff(in dir: String, path: String, staged: Bool, maxLines: Int = 5000) -> FileDiff? {
        let git = "/usr/bin/git"
        // ":(top)" makes the path relative to the repository root, whatever folder `dir` is in it.
        let pathspec = ":(top)" + path
        var args = ["--no-optional-locks", "-C", dir, "diff", "--no-color", "--no-ext-diff"]
        if staged { args.append("--cached") }
        let result = Shell.run(git, args + ["--", pathspec], timeout: 5)
        guard result.ok else { return nil }
        if !result.stdout.isEmpty || staged { return parse(result.stdout, maxLines: maxLines) }

        // Nothing against the index: untracked files are not in it. Compare with nothing instead.
        let untracked = Shell.run(git, ["-C", dir, "ls-files", "--others", "--exclude-standard", "--", pathspec], timeout: 5)
        guard untracked.ok, !untracked.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let root = Shell.run(git, ["-C", dir, "rev-parse", "--show-toplevel"], timeout: 5).stdout
                  .split(separator: "\n").first.map(String.init)
        else { return parse("", maxLines: maxLines) }
        // --no-index exits with 1 when the files differ, which they always do here: read the output anyway.
        let added = Shell.run(git, ["-C", root, "diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", path], timeout: 5)
        return parse(added.stdout, maxLines: maxLines)
    }

    /// Unified diff text → lines. File headers (diff --git, index, ---, +++) are dropped: the view shows the
    /// file name itself.
    static func parse(_ text: String, maxLines: Int) -> FileDiff {
        var diff = FileDiff()
        var old = 0
        var new = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                diff.isBinary = true
                continue
            }
            if line.hasPrefix("diff --git ") {
                inHunk = false
                continue
            }
            if line.hasPrefix("@@"), let match = line.firstMatch(of: #/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/#) {
                old = Int(match.1) ?? 0
                new = Int(match.2) ?? 0
                inHunk = true
                append(.hunk, line, nil, nil)
                continue
            }
            guard inHunk, let first = line.first else { continue }
            switch first {
            case "+":
                diff.added += 1
                append(.added, String(line.dropFirst()), nil, new)
                new += 1
            case "-":
                diff.removed += 1
                append(.removed, String(line.dropFirst()), old, nil)
                old += 1
            case " ":
                append(.context, String(line.dropFirst()), old, new)
                old += 1
                new += 1
            case "\\":
                append(.note, String(line.dropFirst(2)), nil, nil)
            default:
                continue
            }
        }
        return diff

        func append(_ kind: FileDiff.Kind, _ text: String, _ oldNumber: Int?, _ newNumber: Int?) {
            guard diff.lines.count < maxLines else {
                diff.truncated = true
                return
            }
            diff.lines.append(FileDiff.Line(id: diff.lines.count, kind: kind, text: text, oldNumber: oldNumber, newNumber: newNumber))
        }
    }
}
