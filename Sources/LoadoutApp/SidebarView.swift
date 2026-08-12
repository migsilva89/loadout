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
        HStack(spacing: 8) {
            Image(systemName: selection.symbol)
                .foregroundStyle(selection.tint)
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

    var tint: Color {
        switch self {
        case .skills: return .blue
        case .commands: return .green
        case .agents: return .purple
        case .mcp: return .orange
        case .plugins: return .loadoutAmber
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

extension Color {
    /// A mid-brightness gold, picked because it stays readable on both a white and a black
    /// background — unlike a bright yellow, which washes out in light mode, or a dark brown,
    /// which disappears in dark mode.
    static let loadoutAmber = Color(red: 0.72, green: 0.48, blue: 0.06)
}
