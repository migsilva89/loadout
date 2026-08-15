import Foundation

/// A deliberately small YAML reader for the frontmatter block of a `SKILL.md`.
///
/// Skills use a flat `key: value` shape with folded continuation lines, so a full YAML
/// parser would be a dependency bought for nothing. Anything it cannot understand is
/// reported as a warning rather than thrown away, because the file on disk is the truth
/// and the app's job is to show it (AC1.2).
public struct Frontmatter: Equatable, Sendable {
    public var fields: [String: String]
    public var body: String
    public var warning: String?
    /// Only what is wrong with the block itself — an opening that never closes, a line with no
    /// colon. Missing `name` or `description` is not in here.
    ///
    /// Skills require both fields; commands require neither, and are named after their file. Both
    /// still have to be readable, and that is what this reports. Without the split, every one of
    /// the 29 commands wore an amber banner about a field it is not supposed to have, which is how
    /// a warning colour stops meaning anything.
    public var structuralWarning: String?

    public var name: String? { fields["name"] }
    public var description: String? { fields["description"] }

    public init(
        fields: [String: String] = [:], body: String = "", warning: String? = nil,
        structuralWarning: String? = nil
    ) {
        self.fields = fields
        self.body = body
        self.warning = warning
        self.structuralWarning = structuralWarning
    }

    public static func parse(_ text: String) -> Frontmatter {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            let missing = "Missing frontmatter: add a --- block at the start."
            return Frontmatter(body: text, warning: missing, structuralWarning: missing)
        }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            let unclosed = "The frontmatter opens but never closes with ---."
            return Frontmatter(body: text, warning: unclosed, structuralWarning: unclosed)
        }

        var fields: [String: String] = [:]
        var lastKey: String?
        var warning: String?

        for raw in lines[1..<closing] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let isContinuation = raw.first == " " || raw.first == "\t"
            if isContinuation, let key = lastKey, !looksLikeKey(trimmed) {
                // Folded value: YAML joins these with a space.
                let existing = fields[key] ?? ""
                fields[key] = existing.isEmpty ? trimmed : existing + " " + trimmed
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else {
                warning = warning ?? "Ignored a frontmatter line without a colon: \(trimmed)"
                continue
            }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                warning = warning ?? "Ignored a frontmatter line without a key."
                continue
            }
            // `description: >` (or `|`) means the real value is the indented block below.
            // Left as-is, the marker itself would show up in the UI as the description.
            fields[key] = isBlockScalarMarker(value) ? "" : unquote(value)
            lastKey = key
        }

        let body = lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Everything gathered so far is about the block being readable; the two field rules below
        // are the skills' own, and only skills are held to them.
        let structural = warning
        if fields["name"] == nil {
            warning = warning ?? "The frontmatter is missing the name field."
        } else if fields["description"] == nil {
            warning = warning ?? "The frontmatter is missing the description field."
        }

        return Frontmatter(fields: fields, body: body, warning: warning, structuralWarning: structural)
    }

    // MARK: - The nested shape

    /// The frontmatter as it is actually written: maps inside maps, lists of maps, scalars.
    ///
    /// The flat `fields` above answers "what is the description", which is all most of the app
    /// needs. This answers "what does this file say", which is what the inspector shows — and a
    /// flat reading of a nested file does not merely lose the nesting, it overwrites: two `validate`
    /// rules with a `severity` each left one `severity` on screen, looking like a field of the
    /// skill. Wrong while looking right.
    public indirect enum Value: Equatable, Sendable {
        case scalar(String)
        case list([Value])
        case map([(String, Value)])

        public static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.scalar(let a), .scalar(let b)): return a == b
            case (.list(let a), .list(let b)): return a == b
            case (.map(let a), .map(let b)):
                return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: return false
            }
        }
    }

    /// Reads the block as a tree. Same tolerance as `parse`: what it cannot understand is left as
    /// text rather than dropped, because the file on disk is the truth.
    public static func tree(_ text: String) -> [(String, Value)] {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return [] }

        var index = 0
        // Blank lines go; comments do not go here, because a `#` inside a folded block value is
        // part of the text and dropping it silently loses a line of the file.
        let block = Array(lines[1..<closing]).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard case .map(let pairs) = readMap(block, &index, indent: -1) else { return [] }
        return pairs
    }

    /// One map, consuming every line indented further than its parent.
    private static func readMap(_ lines: [String], _ index: inout Int, indent parentIndent: Int) -> Value {
        var pairs: [(String, Value)] = []
        while index < lines.count {
            let line = lines[index]
            let indent = indentation(of: line)
            guard indent > parentIndent else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { index += 1; continue }

            // A dash at this level means the parent is a list, not a map; hand it back.
            if trimmed.hasPrefix("- ") || trimmed == "-" { break }

            guard let colon = trimmed.firstIndex(of: ":") else {
                // A line that is not a pair inside a map: keep it as a scalar of its own rather
                // than dropping it, so nothing in the file goes missing from the screen.
                pairs.append((trimmed, .scalar("")))
                index += 1
                continue
            }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            index += 1

            if !rest.isEmpty, !isBlockScalarMarker(rest) {
                // A description that wraps over two lines is one value, not a value and a stray
                // field: the continuation is folded in exactly as `parse` folds it.
                var value = rest
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard indentation(of: next) > indent, !looksLikeKey(nextTrimmed),
                          !nextTrimmed.hasPrefix("- "), nextTrimmed != "-", !nextTrimmed.hasPrefix("#")
                    else { break }
                    value += " " + nextTrimmed
                    index += 1
                }
                pairs.append((key, value == rest ? scalarOrInlineList(rest) : .scalar(unquote(value))))
                continue
            }
            pairs.append((key, readChildren(lines, &index, indent: indent, blockScalar: isBlockScalarMarker(rest))))
        }
        return .map(pairs)
    }

    /// What follows a `key:` with nothing after it: a nested map, a list, a folded block, or
    /// nothing at all.
    private static func readChildren(
        _ lines: [String], _ index: inout Int, indent: Int, blockScalar: Bool
    ) -> Value {
        guard index < lines.count, indentation(of: lines[index]) > indent else { return .scalar("") }

        if blockScalar {
            // `description: >` — the value is the indented text below, joined the way YAML folds it.
            var parts: [String] = []
            while index < lines.count, indentation(of: lines[index]) > indent {
                parts.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            return .scalar(parts.joined(separator: " "))
        }

        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed == "-" {
            return readList(lines, &index, indent: indent)
        }
        return readMap(lines, &index, indent: indent)
    }

    /// A dashed list. An entry can be a scalar, or a map whose first pair sits on the dash line.
    private static func readList(_ lines: [String], _ index: inout Int, indent parentIndent: Int) -> Value {
        var items: [Value] = []
        while index < lines.count {
            let line = lines[index]
            let indent = indentation(of: line)
            guard indent > parentIndent else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A comment between two entries is not the end of the list. Treating it as one cut
            // every remaining line of the block, in the real Vercel skill above all — its phrases
            // list is written with a note in the middle explaining what is deliberately not there.
            if trimmed.hasPrefix("#") { index += 1; continue }
            guard trimmed.hasPrefix("- ") || trimmed == "-" else { break }

            let head = trimmed == "-" ? "" : String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1

            // `- pattern: x` starts a map whose remaining pairs are indented under the dash.
            if let colon = head.firstIndex(of: ":"), looksLikeKey(head) {
                let key = String(head[head.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = String(head[head.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                var pairs: [(String, Value)] = [(key, scalarOrInlineList(rest))]
                if case .map(let more) = readMap(lines, &index, indent: indent) {
                    pairs += more
                }
                items.append(.map(pairs))
                continue
            }

            if head.isEmpty, index < lines.count, indentation(of: lines[index]) > indent {
                items.append(readMap(lines, &index, indent: indent))
                continue
            }
            items.append(.scalar(unquote(head)))
        }
        return .list(items)
    }

    /// `[a, b]` is a list written on one line; anything else at this point is a scalar.
    private static func scalarOrInlineList(_ raw: String) -> Value {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return .scalar(unquote(raw)) }
        let inner = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return .list([]) }
        return .list(splitTopLevel(inner).map { .scalar(unquote($0.trimmingCharacters(in: .whitespaces))) })
    }

    /// Splits on commas that are not inside quotes, so `['a, b', c]` stays two entries.
    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// A continuation line can itself contain a colon ("Use when: …"), so we only treat it
    /// as a new key when it reads like `word-word:` at the start.
    private static func looksLikeKey(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let candidate = line[line.startIndex..<colon]
        if candidate.isEmpty { return false }
        // The colon has to be followed by a space or nothing at all, or every unquoted URL in a
        // list — `https://vercel.com/docs` — reads as a key called `https`.
        let after = line.index(after: colon)
        if after != line.endIndex, line[after] != " " { return false }
        return candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// `>`, `|`, `>-`, `|+` and friends: the value is the block that follows, not the marker.
    private static func isBlockScalarMarker(_ value: String) -> Bool {
        guard let first = value.first, first == ">" || first == "|" else { return false }
        return value.dropFirst().allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first!, last = value.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// Skill folder names double as identifiers, so they follow the same rule Claude Code uses.
public func isValidSkillName(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 64 else { return false }
    guard name.first!.isLetter || name.first!.isNumber else { return false }
    guard name.last! != "-" else { return false }
    return name.allSatisfy { ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" }
}

/// The starting point for a skill created inside the app (AC4.3).
public func skillTemplate(name: String, description: String) -> String {
    """
    ---
    name: \(name)
    description: \(description)
    ---

    # \(name)

    Write what the skill does and how to use it here.

    ## When to use

    ## Steps
    """
}
