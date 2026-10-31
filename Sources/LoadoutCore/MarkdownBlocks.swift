import Foundation

/// One block of a rendered `SKILL.md`. Inline markup inside a block's text is left as written; the
/// view reads it when it draws.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(marker: String, text: String)
    case quote(String)
    case code(String)
    case rule
    case table(MarkdownTable)
    /// The YAML block at the top: shown as its own key/value tree rather than as prose. A
    /// tree, not a list, because a flat rendering of a nested block puts inner keys on the
    /// same footing as the skill's own — and drops all but the last of a repeated one.
    case frontmatter([(String, Frontmatter.Value)])

    /// Compared field by field. It used to be `String(describing:)` on both sides, which is
    /// reflection — and SwiftUI compares every block of the document against its previous self
    /// on every redraw, which on a 550-line skill is thousands of descriptions built and thrown
    /// away while the pane is being scrolled.
    public static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        switch (lhs, rhs) {
        case (.heading(let a, let x), .heading(let b, let y)): return a == b && x == y
        case (.paragraph(let a), .paragraph(let b)): return a == b
        case (.bullet(let a), .bullet(let b)): return a == b
        case (.numbered(let a, let x), .numbered(let b, let y)): return a == b && x == y
        case (.quote(let a), .quote(let b)): return a == b
        case (.code(let a), .code(let b)): return a == b
        case (.rule, .rule): return true
        case (.table(let a), .table(let b)): return a == b
        case (.frontmatter(let a), .frontmatter(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

/// The block reader behind the reading pane: headings, lists, quotes, fenced code, horizontal
/// rules and tables. Deliberately small — a full CommonMark engine would be a dependency bought to
/// render documents that are, in practice, this simple.
public enum MarkdownBlocks {
    /// The document's blocks, top to bottom. Each line goes to the first rule that claims it; a line
    /// no rule claims joins the open table when it has a `|`, starts a table when a matching
    /// delimiter row follows it, and otherwise joins the open paragraph. A blank line or any other
    /// block closes whichever is open. Frontmatter counts only when the first line is `---` and a
    /// later `---` closes it.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = text.components(separatedBy: "\n")

        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---",
           let closing = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            // In the file's own order, not sorted: the author put `name` and `description` first
            // and grouped the rest for a reason, and a sorted rendering scatters that.
            blocks.append(.frontmatter(Frontmatter.tree(text)))
            lines = Array(lines[(closing + 1)...])
        }

        var paragraph: [String] = []
        var table: MarkdownTable?
        func closeOpenBlock() {
            if let open = table { blocks.append(.table(open)) }
            table = nil
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                closeOpenBlock()
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                index += 1
                continue
            }

            if line.isEmpty {
                closeOpenBlock()
            } else if line == "---" || line == "***" || line.hasPrefix("___") {
                closeOpenBlock()
                blocks.append(.rule)
            } else if line.hasPrefix("#") {
                closeOpenBlock()
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(
                    level: level,
                    text: String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                ))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                closeOpenBlock()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("> ") || line == ">" {
                closeOpenBlock()
                blocks.append(.quote(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
            } else if let marker = numberedMarker(line) {
                closeOpenBlock()
                blocks.append(.numbered(
                    marker: marker,
                    text: String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                ))
            } else if let width = table?.header.count, line.contains("|") {
                // Last among the rules, as on GitHub: a heading, bullet, quote or numbered
                // item that contains a pipe stays what it is, even inside or over a table.
                table?.rows.append(MarkdownTable.row(line, width: width))
            } else if let found = MarkdownTable.start(lines, at: index) {
                closeOpenBlock()
                table = found.table
                index = found.next
                continue
            } else {
                if table != nil { closeOpenBlock() }
                paragraph.append(line)
            }
            index += 1
        }
        closeOpenBlock()
        return blocks
    }

    /// `1.` or `12)` at the start of a line.
    static func numberedMarker(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        guard rest.dropFirst().first == " " else { return nil }
        return String(digits) + String(separator)
    }
}

/// A GitHub-flavoured pipe table. Not handled: a table inside a list item or a quote, and HTML
/// `<table>` markup.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    public var header: [String]
    public var alignments: [Alignment]
    /// Every row is exactly as wide as the header: short rows padded, long rows cut.
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    /// The empty table whose header is `lines[start]`, and the index of its first body line. Nil
    /// unless `lines[start + 1]` is a delimiter row with as many cells as the header.
    static func start(_ lines: [String], at start: Int) -> (table: MarkdownTable, next: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|"),
              let alignments = alignments(lines[start + 1]) else { return nil }
        let header = cells(lines[start])
        guard header.count == alignments.count else { return nil }
        return (MarkdownTable(header: header, alignments: alignments, rows: []), start + 2)
    }

    /// A body row cut or padded to `width` cells.
    static func row(_ line: String, width: Int) -> [String] {
        let cells = cells(line)
        return (0..<width).map { $0 < cells.count ? cells[$0] : "" }
    }

    private static func alignments(_ line: String) -> [Alignment]? {
        guard line.contains("|") else { return nil }
        var result: [Alignment] = []
        for cell in cells(line) {
            let leftColon = cell.hasPrefix(":"), rightColon = cell.count > 1 && cell.hasSuffix(":")
            let dashes = cell.dropFirst(leftColon ? 1 : 0).dropLast(rightColon ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(leftColon && rightColon ? .center : rightColon ? .trailing : .leading)
        }
        return result
    }

    /// `\|` becomes a literal pipe; every other backslash escape is left for the inline reader.
    static func cells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {   // handling backslash escape
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
