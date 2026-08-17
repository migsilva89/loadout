import Foundation

/// The models each assistant CLI can be asked for, and the one Loadout offers by default.
///
/// This is a written list, and that is a deliberate choice rather than a shortcut. Neither CLI can
/// be asked what it supports: `claude` has no `model` subcommand — the command to add one is still
/// an open request on its tracker — and `codex` does not understand `--list-models`. Every tool
/// that offers a model picker ships its own list for the same reason.
///
/// So the list here is short, and it is never the whole story: the picker also takes a name typed
/// by hand. When a model ships that Loadout has not heard of, you type it and it works. A written
/// list that goes stale is only a problem when it is the only way in.
public enum AssistantModels {
    public struct Model: Identifiable, Hashable, Sendable {
        /// Exactly what is passed to the CLI after its model flag.
        public let id: String
        /// What the picker shows.
        public let label: String
        /// One line on what it is for, shown beside the name.
        public let note: String

        public init(id: String, label: String, note: String) {
            self.id = id
            self.label = label
            self.note = note
        }
    }

    /// The models offered for a CLI, most capable first. Empty for a CLI Loadout cannot pass a
    /// model to at all, which is how the picker knows to stay hidden rather than offer a choice
    /// that would be ignored.
    ///
    /// `claude` takes aliases as well as full names, and the aliases are what is offered: they
    /// keep working when the model behind them is replaced, which a pinned version does not.
    /// `codex` and `opencode` want the name itself.
    public static func known(for assistantID: String) -> [Model] {
        switch assistantID {
        case "claude":
            return [
                Model(id: "opus", label: "Opus", note: "The most capable, and the slowest"),
                Model(id: "sonnet", label: "Sonnet", note: "The everyday one"),
                Model(id: "haiku", label: "Haiku", note: "Fast and cheap, for small jobs"),
            ]
        case "codex":
            return [
                Model(id: "gpt-5.6-sol", label: "GPT-5.6 Sol", note: "The most capable"),
                Model(id: "gpt-5.6-terra", label: "GPT-5.6 Terra", note: "Balanced, for everyday work"),
                Model(id: "gpt-5.6-luna", label: "GPT-5.6 Luna", note: "Fast and cheap"),
            ]
        case "opencode":
            return [
                Model(id: "anthropic/claude-opus-4-5", label: "Claude Opus", note: "Through opencode"),
                Model(id: "openai/gpt-5", label: "GPT-5", note: "Through opencode"),
            ]
        default:
            return []
        }
    }

    /// Whether this assistant can be told which model to use at all. A CLI with no model flag
    /// takes whatever it is configured for, and Loadout says nothing about it rather than
    /// pretending to offer a choice.
    public static func acceptsAModel(assistantID: String) -> Bool {
        AssistantChat.builtin(id: assistantID)?.modelTemplate != nil
    }

    /// Where the choice is remembered, one key per assistant: picking Opus for `claude` should not
    /// silently become the model `codex` is asked for, since the names are not even in the same
    /// vocabulary.
    public static func defaultsKey(assistantID: String) -> String {
        "chatModel.\(assistantID)"
    }
}
