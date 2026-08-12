import SwiftUI
import LoadoutCore

/// Renders a `SKILL.md` as something pleasant to read.
///
/// Deliberately small: headings, lists, quotes, fenced code and horizontal rules, with inline
/// emphasis and code handled by `AttributedString`'s own markdown reader. A full CommonMark
/// engine would be a dependency bought to render documents that are, in practice, this simple.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Self.blocks(in: text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - Blocks

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(marker: String, text: String)
        case quote(String)
        case code(String)
        case rule
        /// The YAML block at the top: shown as a plain key/value list rather than as prose.
        case frontmatter([(String, String)])

        static func == (lhs: Block, rhs: Block) -> Bool { String(describing: lhs) == String(describing: rhs) }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .frontmatter(let fields):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .top, spacing: 8) {
                        Text(field.0)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .leading)
                        Text(field.1)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))

        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: [0: 20, 1: 20, 2: 17, 3: 15][level] ?? 13.5, weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 13))
                .lineSpacing(3)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).font(.system(size: 13)).lineSpacing(3)
            }
            .padding(.leading, 4)

        case .numbered(let marker, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(marker)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(inline(text)).font(.system(size: 13)).lineSpacing(3)
            }
            .padding(.leading, 4)

        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 3)
                Text(inline(text))
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    /// Bold, italics, links and inline code, via Foundation's own markdown reader.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Parsing

    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var lines = text.components(separatedBy: "\n")

        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---",
           let closing = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            let front = Frontmatter.parse(text)
            let order = ["name", "description"]
            let keys = order.filter { front.fields[$0] != nil }
                + front.fields.keys.filter { !order.contains($0) }.sorted()
            blocks.append(.frontmatter(keys.map { ($0, front.fields[$0] ?? "") }))
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
