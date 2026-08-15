import Foundation

/// One thing that happened while an assistant worked, in a shape the panel can show whichever
/// CLI produced it.
public enum ChatEvent: Hashable, Sendable {
    /// The id of the conversation just started, so a later turn can resume it.
    case session(String)
    /// Prose meant for Miguel to read, as it arrives.
    case text(String)
    /// Thinking out loud, shown dimmed and collapsible — never mistaken for the answer.
    case reasoning(String)
    /// The assistant ran something. `detail` is the command or the file it touched.
    case activity(tool: String, detail: String)
    /// The assistant changed a file. What it says changed is shown live, but the blocks Miguel
    /// accepts come from diffing the workspace afterwards, so `before`/`after` may be `nil` for
    /// a CLI that only reports the path.
    case edited(path: String, before: String?, after: String?)
    /// The run finished. `error` is `nil` when it ended cleanly.
    case finished(error: String?)
    /// A line the translator could not make sense of, kept rather than dropped so a dialect
    /// change shows up as noise in the panel instead of silence.
    case unparsed(String)
}

/// Turns one line of a CLI's JSON output into events. One translator per dialect, all behind the
/// same call, so teaching Loadout a fifth assistant is a new `case` and nothing else.
public enum ChatEventParser {
    public static func events(from line: String, dialect: AssistantChat.Dialect) -> [ChatEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not JSON at all: a banner, a warning on stderr, a progress line. Worth showing.
            return [.unparsed(trimmed)]
        }
        switch dialect {
        case .claudeStreamJSON: return claude(object)
        case .codexJSONL: return codex(object)
        case .openCodeJSON: return openCode(object)
        }
    }

    // MARK: - claude

    private static func claude(_ object: [String: Any]) -> [ChatEvent] {
        var events: [ChatEvent] = []
        let type = object["type"] as? String

        if let id = object["session_id"] as? String, type == "system" {
            events.append(.session(id))
        }

        switch type {
        case "result":
            let failed = (object["is_error"] as? Bool) == true
            let reason = object["result"] as? String
            events.append(.finished(error: failed ? (reason ?? "The assistant reported an error.") : nil))
            return events
        case "assistant", "user":
            break
        default:
            return events
        }

        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return events }

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { events.append(.text(text)) }
            case "thinking":
                if let text = block["thinking"] as? String, !text.isEmpty {
                    events.append(.reasoning(text))
                }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                if name == "Edit" || name == "Write" || name == "MultiEdit" {
                    events.append(.edited(
                        path: input["file_path"] as? String ?? "",
                        before: input["old_string"] as? String,
                        after: input["new_string"] as? String ?? input["content"] as? String
                    ))
                } else {
                    events.append(.activity(tool: name, detail: describe(input)))
                }
            default:
                break
            }
        }
        return events
    }

    // MARK: - codex

    private static func codex(_ object: [String: Any]) -> [ChatEvent] {
        // Events arrive either bare or wrapped in `msg`, depending on the codex version.
        let message = (object["msg"] as? [String: Any]) ?? object
        var events: [ChatEvent] = []

        if let id = message["thread_id"] as? String ?? object["thread_id"] as? String,
           (message["type"] as? String) == "thread.started" {
            events.append(.session(id))
        }

        switch message["type"] as? String {
        case "turn.completed":
            events.append(.finished(error: nil))
            return events
        case "turn.failed", "error":
            let reason = (message["error"] as? [String: Any])?["message"] as? String
            events.append(.finished(error: reason ?? "The assistant reported an error."))
            return events
        case "item.completed":
            break
        default:
            return events
        }

        guard let item = message["item"] as? [String: Any] else { return events }
        switch item["type"] as? String {
        case "agent_message":
            if let text = item["text"] as? String, !text.isEmpty { events.append(.text(text)) }
        case "reasoning":
            if let text = item["text"] as? String, !text.isEmpty { events.append(.reasoning(text)) }
        case "command_execution":
            events.append(.activity(tool: "Shell", detail: item["command"] as? String ?? ""))
        case "file_change":
            // codex names the file and says "update", never what changed — which is exactly why
            // the accepted blocks come from diffing the workspace instead of from here.
            for change in item["changes"] as? [[String: Any]] ?? [] {
                events.append(.edited(path: change["path"] as? String ?? "", before: nil, after: nil))
            }
        default:
            break
        }
        return events
    }

    // MARK: - opencode

    private static func openCode(_ object: [String: Any]) -> [ChatEvent] {
        var events: [ChatEvent] = []
        if let id = object["sessionID"] as? String { events.append(.session(id)) }

        guard let part = object["part"] as? [String: Any] else { return events }
        switch object["type"] as? String {
        case "text":
            if let text = part["text"] as? String, !text.isEmpty { events.append(.text(text)) }
        case "reasoning":
            if let text = part["text"] as? String, !text.isEmpty { events.append(.reasoning(text)) }
        case "tool_use":
            let tool = part["tool"] as? String ?? "tool"
            let input = ((part["state"] as? [String: Any])?["input"] as? [String: Any]) ?? [:]
            if tool == "edit" || tool == "write" {
                events.append(.edited(
                    path: input["filePath"] as? String ?? "",
                    before: input["oldString"] as? String,
                    after: input["newString"] as? String ?? input["content"] as? String
                ))
            } else {
                events.append(.activity(tool: tool, detail: describe(input)))
            }
        case "finish", "session_finish":
            events.append(.finished(error: nil))
        default:
            break
        }
        return events
    }

    // MARK: - Shared

    /// A one-line summary of a tool's arguments, for the activity row. Prefers the fields that
    /// actually say what is happening over dumping the whole payload.
    private static func describe(_ input: [String: Any]) -> String {
        for key in ["command", "pattern", "file_path", "filePath", "path", "query", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }
}
