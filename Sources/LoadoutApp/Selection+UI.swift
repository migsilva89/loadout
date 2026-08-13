import SwiftUI
import LoadoutCore

/// What the UI layer knows about each sidebar kind beyond its core identity: a tooltip
/// sentence and what the search placeholder calls it.
extension Selection {
    /// What clicking this tab switches the window to, said as a sentence for the hover tooltip.
    var rowHint: String {
        switch self {
        case .skills: return "Skills Claude and other assistants load automatically when they're relevant"
        case .commands: return "Slash commands available to Claude in every project"
        case .agents: return "Subagents Claude can delegate a task to"
        case .mcp: return "MCP servers configured for Claude"
        case .plugins: return "Plugins installed through Claude Code, and their enabled state"
        }
    }

    /// What the search field's placeholder calls a row of this kind — "Search 56 skills",
    /// singular when there is only one.
    func searchNoun(plural: Bool) -> String {
        switch self {
        case .skills: return plural ? "skills" : "skill"
        case .commands: return plural ? "commands" : "command"
        case .agents: return plural ? "agents" : "agent"
        case .mcp: return plural ? "MCP servers" : "MCP server"
        case .plugins: return plural ? "plugins" : "plugin"
        }
    }
}

/// One system colour per kind, spaced around the wheel so no two neighbours are easy to
/// confuse — the detail header's icon tile and the plugin rows wear it.
extension ItemKind {
    var tint: Color {
        switch self {
        case .skill: return .blue
        case .command: return .green
        case .agent: return .purple
        case .mcp: return .orange
        case .plugin: return Color(nsColor: .systemYellow)
        }
    }
}
