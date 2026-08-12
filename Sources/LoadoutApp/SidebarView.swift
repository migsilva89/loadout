import SwiftUI
import LoadoutCore

/// One axis: what kind of thing this is. Origin and state used to be stacked in here too —
/// "Sources", "Plugins", "More" — which read as three different sidebars in one column.
/// They live above the list now, as chips that combine with whichever row is picked here.
struct SidebarView: View {
    @Bindable var model: AppModel

    private let rows: [Selection] = [.skills, .commands, .agents, .mcp]

    var body: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { newValue in
                if let newValue {
                    model.selection = newValue
                    model.filter = .all
                    model.assistantFilter = .any
                    if newValue != .plugins {
                        model.select(model.visibleItems.first?.id)
                    }
                }
            }
        )) {
            ForEach(rows) { row($0) }
            Divider()
            row(.plugins)
        }
        .listStyle(.sidebar)
    }

    private func row(_ selection: Selection) -> some View {
        // The symbol carries colour again — one tint per kind, so a glance down the column
        // tells kinds apart without reading the label. The text and row background stay
        // untouched by it: colour marks the icon only, selection still marks the row.
        let isSelected = model.selection == selection
        return HStack(spacing: Metrics.xs) {
            Image(systemName: selection.symbol)
                .foregroundStyle(isSelected ? Color.white : selection.tint)
                .frame(width: 18)
            Text(selection.title)
                .font(.system(size: 14))
            Spacer()
            Text("\(model.count(for: selection))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(selection.rowHint)
        .pointingHand()
        .tag(selection)
    }
}

extension Selection: Identifiable {
    public var id: Self { self }

    /// The suggested set from the redesign: one recognisable symbol per kind.
    var symbol: String {
        switch self {
        case .skills: return "sparkles"
        case .commands: return "terminal"
        case .agents: return "person.2"
        case .mcp: return "network"
        case .plugins: return "puzzlepiece.extension"
        }
    }

    /// One system colour per kind — the mockup's palette, restored after a pass that took all
    /// colour out of the sidebar. Skills stays close to the window's own accent (Graphite is
    /// neutral, so blue is what actually reads as "tinted" next to it); the rest are spaced
    /// around the wheel so no two neighbours are easy to confuse.
    var tint: Color {
        switch self {
        case .skills: return .blue
        case .commands: return .green
        case .agents: return .purple
        case .mcp: return .orange
        case .plugins: return Color(nsColor: .systemYellow)
        }
    }

    /// What clicking this row switches the list to, said as a sentence for the hover tooltip.
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
