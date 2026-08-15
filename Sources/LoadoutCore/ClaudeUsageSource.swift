import Foundation

/// Claude Code's session transcripts, under `~/.claude/projects`.
///
/// The only format on this machine that announces an activation outright: a skill fires through a
/// tool call named `Skill`, so nothing here is inferred. The parsing is the one Loadout already
/// shipped, moved behind the source protocol without a change in behaviour — the reference snapshot
/// of 174 skill activations across 38 names has to come out the same.
public struct ClaudeUsageSource: UsageSource {
    public let id = "claude"
    public let assistant = "claude"
    public let label = "Claude Code"
    public let parserVersion = 1
    public let isSupported = true

    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func historyFiles() -> [URL] { jsonlFiles(under: paths.transcripts) }

    public func events(in file: URL, since: Date) -> [UsageEvent] {
        var factory = UsageEventFactory()
        var events: [UsageEvent] = []
        JSONLReader.forEachLine(of: file) { line in
            events += Self.events(inLine: line, since: since, file: file.path, factory: &factory)
        }
        return events
    }

    static func events(
        inLine line: Data, since: Date, file: String, factory: inout UsageEventFactory
    ) -> [UsageEvent] {
        guard !line.isEmpty else { return [] }
        // Cheap prefilter: parsing every line as JSON would dominate the run.
        guard let hint = String(data: line.prefix(1 << 16), encoding: .utf8),
              hint.contains("Skill") || hint.contains("subagent_type")
                || hint.contains("mcp__") || hint.contains("<command-name>")
        else { return [] }

        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return []
        }
        guard let stamp = object["timestamp"] as? String,
              let date = Timestamp.iso(stamp), date >= since
        else { return [] }

        let project = projectName(fromCWD: object["cwd"] as? String)
        let session = object["sessionId"] as? String
        var events: [UsageEvent] = []

        func event(_ kind: ItemKind, _ key: String) -> UsageEvent {
            factory.make(
                assistant: "claude", kind: kind, key: key, timestamp: date, project: project,
                sessionID: session, sourceFile: file, evidence: .explicit
            )
        }

        guard let message = object["message"] as? [String: Any] else { return [] }

        // Slash commands arrive as plain text inside a user message.
        if let text = message["content"] as? String {
            events += commandKeys(in: text).map { event(.command, $0) }
        }

        guard let content = message["content"] as? [[String: Any]] else { return events }
        for block in content {
            if let text = block["text"] as? String {
                events += commandKeys(in: text).map { event(.command, $0) }
            }
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String
            else { continue }
            let input = block["input"] as? [String: Any] ?? [:]

            if name == "Skill", let skill = input["skill"] as? String {
                // Plugin skills are invoked as "plugin:skill"; count them under the bare name.
                events.append(event(.skill, normalizedKey(skill)))
            }
            if let agent = input["subagent_type"] as? String {
                events.append(event(.agent, agent))
            }
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                if let server = parts.first, !server.isEmpty { events.append(event(.mcp, server)) }
            }
        }
        return events
    }

    static func commandKeys(in text: String) -> [String] {
        guard text.contains("<command-name>") else { return [] }
        var keys: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<command-name>"),
              let close = rest.range(of: "</command-name>", range: open.upperBound..<rest.endIndex) {
            let key = normalizedKey(String(rest[open.upperBound..<close.lowerBound]))
            if !key.isEmpty { keys.append(key) }
            rest = rest[close.upperBound...]
        }
        return keys
    }
}
