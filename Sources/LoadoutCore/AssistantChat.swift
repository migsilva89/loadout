import Foundation

/// What an assistant CLI can do beyond answering once and exiting.
///
/// The CLIs do not share a single flag between them, so rather than pretend they do,
/// each one says here how to ask it for a streaming conversation, how to pick a previous one back
/// up, and which dialect its output speaks. Anything else stays `nil` and keeps the one-shot Ask,
/// instead of being handed flags it may not understand.
public struct AssistantChat: Hashable, Sendable {
    /// How a CLI reports what it did while it works. Only used for the live view — the blocks
    /// Miguel accepts are always computed by diffing the workspace, never taken from here.
    public enum Dialect: String, Hashable, Sendable {
        /// `claude`: one JSON object per line, `{"type":"assistant","message":{"content":[…]}}`,
        /// with `Edit` tool calls carrying `old_string` and `new_string`. Verified.
        case claudeStreamJSON
        /// `codex exec --json`: `{"msg":{"type":"item.completed","item":{…}}}`. Its `file_change`
        /// item names the file and says `update`, but never what changed. Verified.
        case codexJSONL
        /// `opencode run --format json`: `{"type":"tool_use","part":{…}}`, whose `edit` tool
        /// carries `oldString`, `newString` and a unified diff. Verified.
        case openCodeJSON
    }

    /// Argv for the first message of a conversation, with `{prompt}` where the question goes.
    public var startTemplate: String
    /// Argv for a later message, with `{prompt}` for the question and `{session}` for the id of
    /// the conversation to pick up. `nil` when the CLI can't resume, in which case every turn
    /// starts cold and the panel says so.
    public var resumeTemplate: String?
    /// Argv for handing the CLI a system prompt, with `{system}` where the briefing goes — the
    /// `claude` CLI takes one, the others don't. When this is `nil` the briefing is put at the top
    /// of the first message instead, which every assistant understands.
    public var systemTemplate: String?
    public var dialect: Dialect
    /// True when the CLI refuses to work outside a git repository, as `codex` does. The workspace
    /// is initialised as one either way, so this is only here to explain why.
    public var requiresGitRepository: Bool

    public init(
        startTemplate: String,
        resumeTemplate: String?,
        systemTemplate: String? = nil,
        dialect: Dialect,
        requiresGitRepository: Bool = false
    ) {
        self.startTemplate = startTemplate
        self.resumeTemplate = resumeTemplate
        self.systemTemplate = systemTemplate
        self.dialect = dialect
        self.requiresGitRepository = requiresGitRepository
    }

    public static let sessionPlaceholder = "{session}"
    public static let systemPlaceholder = "{system}"

    /// Builds argv, substituting every placeholder as a whole argument — never spliced into a
    /// larger string, so text holding quotes or a semicolon can't become two arguments.
    ///
    /// - Parameter briefing: what the assistant is told about where it is. Passed as a system
    ///   prompt where the CLI has one, and otherwise prefixed to the message — and only on the
    ///   first turn, since a resumed conversation was already told.
    public func arguments(prompt: String, resuming session: String?, briefing: String? = nil) -> [String] {
        let resuming = session != nil && resumeTemplate != nil
        var template: String
        if resuming, let session, let resumeTemplate {
            template = resumeTemplate.replacingOccurrences(of: Self.sessionPlaceholder, with: session)
        } else {
            template = startTemplate
        }

        var message = prompt
        if let briefing, !resuming {
            if let systemTemplate {
                template = systemTemplate + " " + template
            } else {
                // No system prompt to hand it, so the briefing rides at the top of the message.
                message = briefing + "\n\n---\n\n" + prompt
            }
        }

        return template
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                switch token {
                case Substring(AssistantCLI.promptPlaceholder): return message
                case Substring(Self.systemPlaceholder): return briefing ?? ""
                default: return String(token)
                }
            }
    }

    /// What the panel says it is running, with both placeholders spelled out.
    public var invocationDescription: String {
        startTemplate.replacingOccurrences(of: AssistantCLI.promptPlaceholder, with: "<prompt>")
    }
}

public extension AssistantChat {
    /// Verified on this machine by running the CLI against a throwaway `SKILL.md` and asking it to
    /// edit the file. `--permission-mode acceptEdits` and `-s workspace-write` are safe here
    /// only because the working directory is a disposable copy, never the real skill folder.
    static let claude = AssistantChat(
        startTemplate: "-p --output-format stream-json --verbose --permission-mode acceptEdits {prompt}",
        resumeTemplate:
            "-p --output-format stream-json --verbose --permission-mode acceptEdits --resume {session} {prompt}",
        systemTemplate: "--append-system-prompt {system}",
        dialect: .claudeStreamJSON
    )

    /// `--skip-git-repo-check` is not needed once the workspace is a git repository, but is kept
    /// so a workspace whose `git init` failed still runs instead of erroring out.
    static let codex = AssistantChat(
        startTemplate: "exec --json -s workspace-write --skip-git-repo-check {prompt}",
        resumeTemplate: "exec resume {session} --json -s workspace-write --skip-git-repo-check {prompt}",
        dialect: .codexJSONL,
        requiresGitRepository: true
    )

    static let openCode = AssistantChat(
        startTemplate: "run --format json {prompt}",
        resumeTemplate: "run --format json --session {session} {prompt}",
        dialect: .openCodeJSON
    )

    /// The conversation abilities of a built-in, by id.
    ///
    /// Three of the four hold conversations. `cursor-agent` is not one of them: it wants an
    /// interactive login, so a conversation with it would open a panel and then ask for a password
    /// nobody can type there. It keeps the one-shot Ask, as do custom entries from Settings, whose
    /// flags Loadout has no way to know.
    static func builtin(id: String) -> AssistantChat? {
        switch id {
        case "claude": return .claude
        case "codex": return .codex
        case "opencode": return .openCode
        default: return nil
        }
    }
}
