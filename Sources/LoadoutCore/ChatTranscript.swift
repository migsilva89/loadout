import Foundation

/// Reads back a conversation the `claude` CLI already saved.
///
/// Loadout stores only the id of each conversation, never a copy of it. The messages come from the
/// CLI's own record in `~/.claude/projects/<project>/<id>.jsonl` — one JSON object per line —
/// so there is one history and it cannot drift from what the assistant itself will resume.
public enum ChatTranscript {
    public struct Message: Hashable, Sendable {
        public enum Speaker: Hashable, Sendable { case you, assistant }
        public let speaker: Speaker
        public let text: String

        public init(speaker: Speaker, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    /// The prose of a saved conversation, oldest first. Tool calls and thinking are left out: this
    /// is what reopening the panel shows, and what matters there is what was said.
    ///
    /// Returns nothing if the file isn't found — a conversation the CLI has since pruned reopens
    /// empty rather than failing, and the next message still resumes it by id.
    public static func messages(sessionID: String, transcripts: URL) -> [Message] {
        guard let file = file(for: sessionID, under: transcripts),
              let contents = try? String(contentsOf: file, encoding: .utf8)
        else { return [] }

        var result: [Message] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  // Sidechain entries are a subagent talking to itself, not part of this exchange.
                  (object["isSidechain"] as? Bool) != true,
                  let message = object["message"] as? [String: Any]
            else { continue }

            let speaker: Message.Speaker = type == "user" ? .you : .assistant
            for text in prose(in: message["content"]) {
                result.append(Message(speaker: speaker, text: text))
            }
        }
        return result
    }

    /// Where the CLI put the file. The project directory is derived from the working directory, so
    /// rather than reproduce that naming rule, the id is looked for wherever it landed.
    static func file(for sessionID: String, under transcripts: URL) -> URL? {
        let name = "\(sessionID).jsonl"
        let direct = transcripts.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: transcripts, includingPropertiesForKeys: nil
        ) else { return nil }
        for project in projects {
            let candidate = project.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Content is either a plain string or a list of blocks; only the text blocks are prose.
    private static func prose(in content: Any?) -> [String] {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
