import SwiftUI

/// Renders the markdown Claude writes: paragraphs, headings, lists, quotes, fenced code, tables and rules,
/// with inline styles (bold, italics, code, links) from Foundation's markdown parser.
struct MarkdownText: View {
    @Environment(\.theme) private var theme
    private let blocks: [Block]

    init(_ markdown: String) {
        blocks = Self.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Blocks

    enum Block {
        case paragraph(String)
        case heading(level: Int, String)
        case listItem(indent: Int, marker: String, String)
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .paragraph(text):
            Text(Self.inline(text))
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case let .listItem(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(theme.textSecondary).monospacedDigit()
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .quote(text):
            Text(Self.inline(text))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 3) }
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.callout.monospaced()).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.card))
        case let .table(rows):
            table(rows)
        case .rule:
            Divider()
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inline(cell))
                            .fontWeight(index == 0 ? .semibold : nil)
                            .frame(maxWidth: 360, alignment: .leading)
                    }
                }
                if index == 0 { Divider() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
    }

    // MARK: - Parsing

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| line under the header.
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if trimmed.hasPrefix("```") {
                flushParagraph()
                code = []
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flushParagraph()
                blocks.append(.heading(level: heading.1.count, String(heading.2)))
            } else if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), trimmed.count >= 3 {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+(.*)$/#) {
                flushParagraph()
                let marker = item.2.first.map { "-*+".contains($0) } == true ? "•" : String(item.2)
                blocks.append(.listItem(indent: item.1.count / 2, marker: marker, String(item.3)))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }
}
