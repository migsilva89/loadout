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

    public var name: String? { fields["name"] }
    public var description: String? { fields["description"] }

    public init(fields: [String: String] = [:], body: String = "", warning: String? = nil) {
        self.fields = fields
        self.body = body
        self.warning = warning
    }

    public static func parse(_ text: String) -> Frontmatter {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return Frontmatter(body: text, warning: "Missing frontmatter: add a --- block at the start.")
        }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return Frontmatter(body: text, warning: "The frontmatter opens but never closes with ---.")
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

        if fields["name"] == nil {
            warning = warning ?? "The frontmatter is missing the name field."
        } else if fields["description"] == nil {
            warning = warning ?? "The frontmatter is missing the description field."
        }

        return Frontmatter(fields: fields, body: body, warning: warning)
    }

    /// A continuation line can itself contain a colon ("Use when: …"), so we only treat it
    /// as a new key when it reads like `word-word:` at the start.
    private static func looksLikeKey(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let candidate = line[line.startIndex..<colon]
        if candidate.isEmpty { return false }
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
