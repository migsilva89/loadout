import SwiftUI
import LoadoutCore

/// The five kind rows that used to be their own sidebar column, now a horizontal bar across
/// the top of the list column. Origin and state still live below it as chips — this bar carries
/// only the one axis that used to fill a whole 212pt column two thirds empty.
struct KindBar: View {
    @Bindable var model: AppModel

    private let kinds: [Selection] = [.skills, .commands, .agents, .mcp, .plugins]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(kinds) { kind in
                KindBarItem(model: model, kind: kind, isSelected: model.selection == kind)
            }
        }
        .padding(.horizontal, Metrics.xs)
        .padding(.vertical, Metrics.xs)
        // `.bar` material, same as a toolbar, so the row reads as chrome sitting above the
        // list rather than as content inside it.
        .background(.bar)
    }
}

private struct KindBarItem: View {
    @Bindable var model: AppModel
    let kind: Selection
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            // Same behaviour the sidebar's List selection used to drive: reset both filters
            // and land on the first visible item, except for Plugins, which has no items of
            // its own to select.
            model.selection = kind
            model.filter = .all
            model.assistantFilter = .any
            if kind != .plugins {
                model.select(model.visibleItems.first?.id)
            }
        } label: {
            // Count under the label, not beside it — five even columns at the list column's
            // ideal width only leave about 80pt each, too narrow for "Commands 23" on one
            // line without truncating well before the minimum width the spec allows for. A
            // third row gives the label the full column width to itself, so it only starts
            // truncating once the column itself gets tight.
            VStack(spacing: 2) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(kind.tint)
                    .layoutPriority(1)
                Text(kind.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Smaller and quieter than the label, the same way every other count in the
                // app is — including the branch on colour scheme, since `.secondary` alone
                // reads a touch too faint against the light background here.
                Text("\(model.count(for: kind))")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(colorScheme == .dark ? Color.secondary : Color.primary.opacity(0.75))
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear)
        )
        .help(kind.rowHint)
        .pointingHand()
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
