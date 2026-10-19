import Foundation

/// One row of the sharing matrix: a server name, and what every MCP-capable assistant says
/// about it.
///
/// The list joins nothing — a server is one assistant's entry, and the same name in two
/// assistants is two rows there. This is the view that groups them: one name, one row, a cell
/// per assistant, which is what makes "put it on the other three" one gesture instead of a tour
/// through four config files.
public struct MCPMatrixRow: Identifiable, Equatable, Sendable {
    public var name: String
    /// The first definition found, for the preview under the name — command and arguments, or
    /// the URL. Whichever assistant supplied it, the row describes the same server.
    public var description: String
    /// Cell state per assistant id. An assistant with no cell is not MCP-capable here.
    public var cells: [String: Cell]

    public var id: String { name }

    public init(name: String, description: String, cells: [String: Cell]) {
        self.name = name
        self.description = description
        self.cells = cells
    }

    /// One assistant's square: on, off, absent, or something Loadout refuses to write.
    public struct Cell: Equatable, Sendable {
        public let assistant: String
        public let state: State
        /// Set when the assistant cannot be given this server by Loadout — today only Codex,
        /// whose config is TOML behind its own protocol and has `codex mcp add` for this.
        public let refusal: String?

        public init(assistant: String, state: State, refusal: String? = nil) {
            self.assistant = assistant
            self.state = state
            self.refusal = refusal
        }

        public enum State: Equatable, Sendable {
            /// In the assistant's config and running.
            case on
            /// In the assistant's config, with its own flag saying no.
            case off
            /// Not in this assistant's config at all. Pressing it shares the server in.
            case absent
        }

        public var isOn: Bool { state == .on }
    }

    /// The assistants that already have this server on — the number in the column header.
    public var onCount: Int { cells.values.filter(\.isOn).count }
}

public enum MCPMatrix {
    /// Builds the matrix from the inventory.
    ///
    /// Only personal-scope servers take part: per-project MCP is Claude's alone and answered by
    /// the project scope, not by this view. `assistants` is the column order, already narrowed
    /// to what the reader has not hidden in Settings — every one of them gets a cell, absent
    /// servers included, because an empty square is the thing you press to fill it.
    public static func rows(items: [Item], assistants: [String]) -> [MCPMatrixRow] {
        let personal = items.filter {
            $0.kind == .mcp && $0.origin == .personal
        }
        var grouped: [String: [Item]] = [:]
        for item in personal { grouped[item.name, default: []].append(item) }

        return grouped.map { name, owners in
            var cells: [String: MCPMatrixRow.Cell] = [:]
            for assistant in assistants {
                if let owner = owners.first(where: { $0.assistants.contains(assistant) }) {
                    cells[assistant] = MCPMatrixRow.Cell(
                        assistant: assistant,
                        state: owner.enabled ? .on : .off,
                        refusal: refusal(for: assistant)
                    )
                } else {
                    cells[assistant] = MCPMatrixRow.Cell(
                        assistant: assistant, state: .absent, refusal: refusal(for: assistant)
                    )
                }
            }
            let first = owners.first { $0.enabled } ?? owners[0]
            return MCPMatrixRow(
                name: name,
                description: first.description,
                cells: cells
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Which assistants get a column: the three with their own handling, plus every assistant
    /// whose config file Loadout knows how to write. In the order the stores define, with
    /// Claude, Codex and Antigravity first — they are the ones with history.
    public static func columns(paths: Paths, assistants: [Assistant]) -> [Assistant] {
        let capable = ["claude", "codex", "antigravity"]
            + MCPStore.stores(paths: paths).map(\.assistant)
        return assistants.filter { capable.contains($0.id) }
    }

    /// What Loadout will not do for an assistant, in one line for the tooltip. Nil means it
    /// will do everything the matrix offers.
    static func refusal(for assistant: String) -> String? {
        assistant == "codex"
            ? "Codex keeps its servers in config.toml behind its own protocol. Loadout can switch this one on and off; adding it is `codex mcp add`."
            : nil
    }
}
