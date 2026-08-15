import Foundation

/// Codex session logs, under `~/.codex/sessions` and `~/.codex/archived_sessions`.
///
/// Codex has no skill tool. It activates a skill by reading the file, so the evidence has to be the
/// read — but only the kind of read that means activation. The audit measured the difference on real
/// sessions: 78 skills are merely *named* in message text, because the whole catalogue sits in the
/// prompt, while only 30 are ever read by a command. Counting mentions would have inflated the
/// numbers roughly two and a half times.
///
/// So: a canonical full read (`cat`, `sed -n`, `head`, `less`) of `**/skills/<name>/SKILL.md` counts,
/// and a search, a listing or a write touching that same path does not. Every event is marked
/// `inferred`, because it is.
public struct CodexUsageSource: UsageSource {
    public let id = "codex"
    public let assistant = "codex"
    public let label = "Codex"
    public let parserVersion = 1
    public let isSupported = true

    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func historyFiles() -> [URL] {
        jsonlFiles(under: paths.codexSessions) + jsonlFiles(under: paths.codexArchivedSessions)
    }

    public func events(in file: URL, since: Date) -> [UsageEvent] {
        var factory = UsageEventFactory()
        var events: [UsageEvent] = []
        var session: String?
        var project = "?"
        var surface: String?

        JSONLReader.forEachLine(of: file) { line in
            guard !line.isEmpty else { return }
            // The metadata is the first line; everything else worth reading names a skill file.
            let hint = String(data: line.prefix(1 << 16), encoding: .utf8) ?? ""
            guard hint.contains("session_meta") || hint.contains("SKILL.md") else { return }

            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { return }

            if object["type"] as? String == "session_meta" {
                session = payload["session_id"] as? String
                project = projectName(fromCWD: payload["cwd"] as? String)
                surface = Self.surface(originator: payload["originator"] as? String)
                return
            }

            guard let kind = payload["type"] as? String,
                  ["function_call", "custom_tool_call", "local_shell_call"].contains(kind),
                  let stamp = object["timestamp"] as? String,
                  let date = Timestamp.iso(stamp), date >= since
            else { return }

            let command = Self.command(in: payload)
            for key in Self.activatedSkills(in: command) {
                events.append(factory.make(
                    assistant: "codex", surface: surface, kind: .skill, key: key, timestamp: date,
                    project: project, sessionID: session, sourceFile: file.path, evidence: .inferred
                ))
            }
        }
        return events
    }

    /// The command text a tool call ran, whichever shape the call arrived in.
    static func command(in payload: [String: Any]) -> String {
        for field in ["arguments", "input", "command"] {
            if let text = payload[field] as? String { return text }
            if let object = payload[field],
               let data = try? JSONSerialization.data(withJSONObject: object),
               let text = String(data: data, encoding: .utf8) { return text }
        }
        return ""
    }

    /// Which skills a command actually activated. Empty when it only looked around.
    static func activatedSkills(in command: String) -> [String] {
        guard command.contains("SKILL.md") else { return [] }
        let names = skillPath.matches(in: command, range: NSRange(command.startIndex..., in: command))
            .compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: command) else { return nil }
                return String(command[range])
            }
        guard !names.isEmpty, isCanonicalRead(command) else { return [] }
        // Two commands can read the same skill in one call; the same skill twice is still one read.
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// A read that pulls the instructions in, rather than one that hunts through them or edits them.
    ///
    /// A command that writes the skill is editing it, not using it — which happens constantly in this
    /// very app — so it is rejected outright. Otherwise the command has to actually read: `rg`,
    /// `grep`, `ls` and `find` over the same path are looking for something, and the audit confirmed
    /// that rejecting them loses no skill, because every name reached by a search was also reached by
    /// a real read.
    static func isCanonicalRead(_ command: String) -> Bool {
        let writes = ["apply_patch", "sed -i", "tee ", ">>"]
        guard !writes.contains(where: command.contains) else { return false }
        return ["cat ", "sed -n", "head -", "less "].contains(where: command.contains)
    }

    /// Codex's own front ends. Never Paseo: the audit found no Paseo value here, and Paseo
    /// attribution is a session-id join done by the index instead.
    static func surface(originator: String?) -> String? {
        switch originator {
        case "codex_cli_rs", "codex-tui": return "codex-cli"
        case "codex_exec": return "codex-exec"
        case "Codex Desktop": return "codex-app"
        case "Claude Code": return "claude-code"
        case let other?: return other.isEmpty ? nil : other
        default: return nil
        }
    }

    private static let skillPath = try! NSRegularExpression(
        pattern: "/skills/([A-Za-z0-9._-]+)/SKILL\\.md"
    )
}
