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
        case (.frontmatter(let a), .frontmatter(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

/// The block reader behind the reading pane: headings, lists, quotes, fenced code and horizontal
/// rules. Deliberately small — a full CommonMark engine would be a dependency bought to render
/// documents that are, in practice, this simple.
public enum MarkdownBlocks {
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
        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushParagraph()
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
                flushParagraph()
            } else if line == "---" || line == "***" || line.hasPrefix("___") {
                flushParagraph()
                blocks.append(.rule)
            } else if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(
                    level: level,
                    text: String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                ))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("> ") || line == ">" {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
            } else if let marker = numberedMarker(line) {
                flushParagraph()
                blocks.append(.numbered(
                    marker: marker,
                    text: String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                ))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
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
