import SwiftUI
import LoadoutCore

/// One heading of the rendered document. Deliberately position-free: where a heading *is* changes
/// on every frame of a scroll, and a list that changed that often would republish itself — and
/// re-evaluate everything reading it — sixty times a second.
struct DocumentHeading: Equatable, Identifiable {
    /// Its position among the document's headings, which is also its scroll anchor.
    var id: Int
    var level: Int
    var title: String
    /// The first prose underneath, for the tick rail's card to quote. Both this and `progress` are
    /// facts about the text, so they cost the list nothing: it still changes only when the text does.
    var preview: String
    /// How far into the document it sits, 0 to 1 — the "45% in" a card can say without measuring
    /// anything on screen.
    var progress: Double
}

/// Stable targets inside the lazy document. `ScrollViewProxy` can materialize a heading that has
/// not been drawn yet, so a tick-rail press stays exact without eagerly laying out every block.
enum DocumentAnchor: Hashable {
    case frontmatter
    case heading(Int)
    case block(Int)
}

/// The document's outline, in order. Published once by the renderer rather than a heading at a
/// time, and only when the text changes.
struct DocumentHeadingsKey: PreferenceKey {
    static let defaultValue: [DocumentHeading] = []

    static func reduce(value: inout [DocumentHeading], nextValue: () -> [DocumentHeading]) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// Where each heading sits in the document, by heading index.
///
/// Measured in the scrolling content's own space rather than the viewport's, which is what makes it
/// affordable: a heading's offset down the document doesn't change when you scroll, so this arrives
/// once per layout instead of once per frame. It is what lets the tick rail scrub — dragging has to
/// land the page between two headings, and `scrollTo(anchor:)` can only ever land on one.
struct HeadingOffsetsKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// The scroll-spy: the last heading the reader has scrolled past, as one number rather than a
/// list of positions. Each heading reports only whether it is above the line, so the value moves
/// when a heading is actually crossed and stays put for every frame in between.
struct ActiveHeadingKey: PreferenceKey {
    static let defaultValue: Int? = nil

    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        if let next = nextValue() { value = max(value ?? next, next) }
    }
}

/// Renders a `SKILL.md` as something pleasant to read.
///
/// Deliberately small: headings, lists, quotes, fenced code and horizontal rules, with inline
/// emphasis and code handled by `AttributedString`'s own markdown reader. A full CommonMark
/// engine would be a dependency bought to render documents that are, in practice, this simple.
struct MarkdownView: View {
    let text: String
    /// Reading preferences from the card's Aa popover. Everything scales from the base size —
    /// H1 at 1.66×, H2 at 1.14×, code 2.5pt under the body, the room above an H2 at 2× — so
    /// growing the type keeps the hierarchy instead of collapsing it into one size.
    var fontSize: CGFloat = 15
    var design: Font.Design = .default

    /// The prose cap, and the wider container that holds it. Code blocks and the frontmatter
    /// strip are allowed the full 96, because a wrapped command line is worse than a wide one.
    ///
    /// `nonisolated`, both of them and the formula below: these are facts about the measure, not
    /// about a view, and the pane asks for them while deciding its own layout.
    nonisolated static let proseCharacters: CGFloat = 84
    nonisolated static let containerCharacters: CGFloat = 96

    /// A width in characters, at a given size — one character being a digit's advance in SF, the
    /// 0.6em the reading column has always been drawn against.
    ///
    /// The one place the measure is derived. The prose column inside and the container the pane
    /// asks for outside both come through here, so the two can never drift apart.
    nonisolated static func width(fontSize: CGFloat, characters: CGFloat) -> CGFloat {
        fontSize * 0.6 * characters
    }

    /// How wide running text is drawn — headings, paragraphs, bullets, quotes.
    ///
    /// The pane hands this in, because only the pane knows what is left after the reading rail
    /// and the margins. Absent, it falls back to the 84-character measure, which is what a
    /// preview or any other caller with no layout of its own should get.
    var proseWidth: CGFloat?

    var measure: CGFloat {
        proseWidth ?? Self.width(fontSize: fontSize, characters: Self.proseCharacters)
    }
    /// line-height ≈ 1.75 expressed as SwiftUI's between-lines spacing.
    private var leading: CGFloat { fontSize * 0.75 }
    private var body_: Color { Color.white.opacity(0.84) }
    private var secondary: Color { Color.white.opacity(0.72) }

    var body: some View {
        // Spacing between blocks now lives on each block itself (headings need generous room
        // above and little below; list items want a tight, even rhythm) rather than one
        // uniform gap that made every heading read like the paragraph before it.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(laidOut, id: \.offset) { entry in
                view(for: entry.block, headingIndex: entry.heading)
                    .id(anchor(for: entry))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .preference(key: DocumentHeadingsKey.self, value: outline)
    }

    private func anchor(
        for entry: (offset: Int, block: Block, heading: Int?)
    ) -> DocumentAnchor {
        if case .frontmatter = entry.block { return .frontmatter }
        if let heading = entry.heading { return .heading(heading) }
        return .block(entry.offset)
    }

    /// The outline, built from the parsed blocks: each heading with the prose that follows it and
    /// where in the document it falls.
    private var outline: [DocumentHeading] {
        let blocks = Self.blocks(in: text)
        var result: [DocumentHeading] = []
        // The frontmatter earns the first mark. It is the name and the description — the two things
        // that are in context in every session — so an outline that starts below it starts late.
        if case .frontmatter(let fields) = blocks.first {
            result.append(DocumentHeading(
                id: Self.frontmatterAnchor,
                level: 1,
                title: Self.scalar(fields, "name") ?? "Frontmatter",
                preview: Self.scalar(fields, "description") ?? "",
                progress: 0
            ))
        }
        var index = -1
        for (position, block) in blocks.enumerated() {
            guard case .heading(let level, let title) = block else { continue }
            // Counted before the depth test, because the id is the scroll anchor and the anchors
            // are numbered over every heading the renderer drew.
            index += 1
            guard level <= Self.tableOfContentsDepth else { continue }
            result.append(DocumentHeading(
                id: index,
                level: level,
                title: title,
                preview: Self.prose(after: position, in: blocks),
                progress: blocks.count > 1 ? Double(position) / Double(blocks.count - 1) : 0
            ))
        }
        return result
    }

    /// The first thing under a heading that has words in it. A rule or the frontmatter is skipped;
    /// a run of headings falls through to the first prose below them, which beats quoting nothing
    /// for every section that opens with a subsection.
    private static func prose(after position: Int, in blocks: [Block]) -> String {
        guard position + 1 < blocks.count else { return "" }
        for block in blocks[(position + 1)...] {
            let text: String
            switch block {
            case .paragraph(let value), .quote(let value), .bullet(let value): text = value
            case .numbered(_, let value): text = value
            case .code(let code): text = code.components(separatedBy: "\n").first ?? ""
            case .heading, .rule, .frontmatter: continue
            }
            // The card clamps to three lines; carrying a whole section past that is waste.
            return String(text.prefix(300))
        }
        return ""
    }

    /// The blocks, each heading carrying its position among the headings — the number the rail's
    /// "On this page" counts in and the scroll anchor is named after.
    private var laidOut: [(offset: Int, block: Block, heading: Int?)] {
        var heading = -1
        return Self.blocks(in: text).enumerated().map { offset, block in
            guard case .heading = block else { return (offset, block, nil) }
            heading += 1
            return (offset, block, heading)
        }
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
        /// The YAML block at the top: shown as its own key/value tree rather than as prose. A
        /// tree, not a list, because a flat rendering of a nested block puts inner keys on the
        /// same footing as the skill's own — and drops all but the last of a repeated one.
        case frontmatter([(String, Frontmatter.Value)])

        /// Compared field by field. It used to be `String(describing:)` on both sides, which is
        /// reflection — and SwiftUI compares every block of the document against its previous self
        /// on every redraw, which on a 550-line skill is thousands of descriptions built and thrown
        /// away while the pane is being scrolled.
        static func == (lhs: Block, rhs: Block) -> Bool {
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

    @ViewBuilder
    private func view(for block: Block, headingIndex: Int? = nil) -> some View {
        switch block {
        case .frontmatter(let fields):
            VStack(alignment: .leading, spacing: 5) {
                FrontmatterTree(pairs: fields)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HeadingOffsetsKey.self,
                        value: [Self.frontmatterAnchor:
                            proxy.frame(in: readingContentSpace).minY.rounded()]
                    )
                }
            }

        case .heading(let level, let text):
            let style = headingStyle(level)
            Text(inline(text))
                .font(.system(size: style.size, weight: .semibold, design: design))
                .foregroundStyle(Color.white)
                // Headings hold the same 84ch measure as the prose under them: a title that
                // ran wider than its own paragraphs read as a different column.
                .frame(maxWidth: measure, alignment: .leading)
                .padding(.top, style.spaceAbove)
                .padding(.bottom, style.spaceBelow)
                .textSelection(.enabled)
                .background(headingReport(index: headingIndex, level: level))

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: fontSize, design: design))
                .lineSpacing(leading)
                .foregroundStyle(body_)
                .frame(maxWidth: measure, alignment: .leading)
                .padding(.bottom, 6)
                .textSelection(.enabled)

        case .bullet(let text):
            // A hanging indent, not a first-line one: the bullet sits in its own column, and
            // wrapped lines fall under the text rather than back under the dot.
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.system(size: fontSize, design: design))
                    .foregroundStyle(secondary)
                Text(inline(text))
                    .font(.system(size: fontSize, design: design))
                    .lineSpacing(leading)
                    .foregroundStyle(body_)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: measure, alignment: .leading)
            .padding(.leading, 4)
            .padding(.bottom, 6)

        case .numbered(let marker, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(marker)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(secondary)
                Text(inline(text))
                    .font(.system(size: fontSize, design: design))
                    .lineSpacing(leading)
                    .foregroundStyle(body_)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: measure, alignment: .leading)
            .padding(.leading, 4)
            .padding(.bottom, 6)

        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(V2.accent.opacity(0.5)).frame(width: 3)
                Text(inline(text))
                    .font(.system(size: fontSize, design: design))
                    .lineSpacing(leading)
                    .italic()
                    .foregroundStyle(secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: measure, alignment: .leading)
            .padding(.bottom, 6)

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize - 2.5, design: .monospaced))
                    .foregroundStyle(V2.code)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 9)

        case .rule:
            Hairline(color: Color.white.opacity(0.07)).padding(.vertical, 8)
        }
    }

    /// The frontmatter's own id in the outline, outside the range the headings number in.
    nonisolated static let frontmatterAnchor = -1

    /// Publishes this heading twice over: into the document's table of contents, which depends only
    /// on the text, and into the scroll-spy, which gets a bare "am I above the line yet" rather
    /// than a position. Splitting them is what keeps a scroll from republishing the whole list.
    @ViewBuilder
    private func headingReport(index: Int?, level: Int) -> some View {
        // H1 to H3. Deeper than that is the document's own business, not a table of contents' —
        // and a heading no entry stands for must not be able to become the active entry either,
        // which is why the depth is decided here rather than filtered by whoever reads the list.
        if let index, level <= Self.tableOfContentsDepth {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: ActiveHeadingKey.self,
                        value: proxy.frame(in: readingViewportSpace).minY <= Self.activeHeadingLine
                            ? index : nil
                    )
                    .preference(
                        key: HeadingOffsetsKey.self,
                        value: [index: proxy.frame(in: readingContentSpace).minY.rounded()]
                    )
            }
        }
    }

    /// How far down the pane a heading has to have travelled to count as the one being read.
    static let activeHeadingLine: CGFloat = 100
    static let tableOfContentsDepth = 3

    /// Font size and the space above/below a heading. h2 gets the most contrast with the body
    /// text around it — a clear gap above, almost none below — because that's the level doing
    /// the actual work of breaking a document into sections; h1 only ever appears once, and h3
    /// is closer in weight to the paragraphs it introduces.
    private func headingStyle(_ level: Int) -> (size: CGFloat, spaceAbove: CGFloat, spaceBelow: CGFloat) {
        switch level {
        case 1: return (fontSize * 1.66, fontSize * 1.5, 9)
        case 2: return (fontSize * 1.14, fontSize * 2, 7)
        default: return (fontSize, fontSize * 1.1, 5)
        }
    }

    /// Bold, italics, links and inline code, via Foundation's own markdown reader. Inline code
    /// spans get the theme's code hue and a faint tint of it behind them here too — the reader marks up `inline code` the same way
    /// whether it's read as a run of an `AttributedString` or a full fenced block.
    private func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].foregroundColor = V2.code
            attributed[run.range].backgroundColor = V2.code.opacity(0.14)
            attributed[run.range].font = .system(size: fontSize - 2, design: .monospaced)
        }
        // Links, in the theme's link hue rather than the system accent an `AttributedString`
        // would otherwise reach for — which in a themed window is a colour from nowhere.
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = V2.link
            attributed[run.range].underlineStyle = .single
        }
        return attributed
    }

    /// A top-level scalar out of the frontmatter tree, for the two fields the outline names.
    static func scalar(_ pairs: [(String, Frontmatter.Value)], _ key: String) -> String? {
        guard case .scalar(let text)? = pairs.first(where: { $0.0 == key })?.1 else { return nil }
        return text
    }

    // MARK: - Parsing

    /// The last few documents, parsed.
    ///
    /// A view is rebuilt for every state change, and reading the pane produces a stream of them —
    /// the scroll-spy reporting which heading is being read, the offsets the rail scrubs against.
    /// Each rebuild used to parse the whole document twice, at about two milliseconds a pass on a
    /// real skill, which is a quarter of a frame's budget spent re-reading text that had not
    /// changed. Small and fixed: this is a cache of a screenful of work, not a store.
    @MainActor private static var cache: [(text: String, blocks: [Block])] = []
    @MainActor private static let cacheSize = 4

    static func blocks(in text: String) -> [Block] {
        if let hit = MainActor.assumeIsolated({ cache.first { $0.text == text }?.blocks }) {
            return hit
        }
        let parsed = parseBlocks(in: text)
        MainActor.assumeIsolated {
            cache.removeAll { $0.text == text }
            cache.append((text, parsed))
            if cache.count > cacheSize { cache.removeFirst(cache.count - cacheSize) }
        }
        return parsed
    }

    private static func parseBlocks(in text: String) -> [Block] {
        var blocks: [Block] = []
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

/// The frontmatter block, drawn as the tree it is.
///
/// A nested key is indented under its parent and a list entry is numbered, so `metadata`'s
/// `minScore` reads as living inside `promptSignals` rather than as a field of the skill — and two
/// `validate` rules read as two rules instead of one overwriting the other.
struct FrontmatterTree: View {
    let pairs: [(String, Frontmatter.Value)]
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                row(key: pair.0, value: pair.1)
            }
        }
    }

    @ViewBuilder
    private func row(key: String, value: Frontmatter.Value) -> some View {
        switch value {
        case .scalar(let text):
            HStack(alignment: .top, spacing: 8) {
                keyLabel(key)
                Text(text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
            }
        case .list(let items) where items.allSatisfy { if case .scalar = $0 { return true } else { return false } }:
            // A list of plain values fits on the value side, comma-separated: a bullet each for
            // eleven path patterns turns the block into a page of its own.
            HStack(alignment: .top, spacing: 8) {
                keyLabel(key)
                Text(items.compactMap { if case .scalar(let text) = $0 { return text } else { return nil } }
                    .joined(separator: ", "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(items.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                keyLabel(key, standalone: true)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, alignment: .trailing)
                        if case .map(let inner) = item {
                            FrontmatterTree(pairs: inner, depth: depth + 1)
                        } else if case .scalar(let text) = item {
                            Text(text).font(.system(size: 12.5))
                        }
                    }
                    .padding(.leading, 10)
                }
            }
        case .map(let inner):
            VStack(alignment: .leading, spacing: 5) {
                keyLabel(key, standalone: true)
                FrontmatterTree(pairs: inner, depth: depth + 1)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        // One hairline down the left of a nested block: cheaper to read than
                        // indentation alone once there are three levels of it.
                        Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
                    }
            }
        }
    }

    /// A key column that is at least wide enough to line the values up, and wider when the key
    /// needs it. Fixed at 84 it wrapped: `pathPatterns` came out as "pathPatter / ns".
    private func keyLabel(_ key: String, standalone: Bool = false) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: standalone ? nil : max(92 - CGFloat(depth) * 8, 56), alignment: .leading)
    }
}
