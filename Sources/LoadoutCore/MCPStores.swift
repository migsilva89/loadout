import Foundation

/// One MCP server entry, read into a shape every assistant's format can be rendered from.
///
/// The formats agree on more than they differ: a command with arguments and an environment, or a
/// URL. What differs is spelling — opencode wants the command as an array and calls the
/// environment `environment`; Antigravity calls a remote server's URL `serverUrl` — so the entry
/// is read once here and rendered per target, rather than translated pairwise between every pair
/// of assistants.
public struct MCPEntry: Equatable, Sendable {
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    /// The on/off flag the entry carries, when its format has one. Nil means the format cannot
    /// say so in place — off is the entry's absence, and Loadout's record holds it instead.
    public var enabled: Bool?

    public init(
        command: String? = nil, args: [String] = [], env: [String: String] = [:],
        url: String? = nil, enabled: Bool? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.enabled = enabled
    }

    public var isRemote: Bool { url != nil }

    /// The same sentence the list rows use: the command and its arguments, or the URL.
    public var description: String {
        if let command {
            return args.isEmpty ? command : command + " " + args.joined(separator: " ")
        }
        if let url { return url }
        return "MCP server"
    }

    /// Reads an entry written in any of the formats Loadout knows.
    public init(dict: [String: Any], style: MCPStore.EntryStyle) {
        switch style {
        case .opencode:
            // `type: "local"` carries a command array; `type: "remote"` a URL. An entry with
            // neither is read as a local one with no command, which is at least honest about
            // what is missing rather than pretending it is remote.
            if let command = dict["command"] as? [String], !command.isEmpty {
                self.init(
                    command: command[0], args: Array(command.dropFirst()),
                    env: dict["environment"] as? [String: String] ?? [:],
                    enabled: dict["enabled"] as? Bool
                )
            } else {
                self.init(
                    url: dict["url"] as? String,
                    enabled: dict["enabled"] as? Bool
                )
            }
        case .classic, .antigravity:
            self.init(
                command: dict["command"] as? String,
                args: dict["args"] as? [String] ?? [],
                env: dict["env"] as? [String: String] ?? [:],
                url: dict["url"] as? String ?? dict["serverUrl"] as? String,
                enabled: dict["enabled"] as? Bool
            )
        }
    }

    /// Renders this entry in one assistant's own format.
    public func rendered(for style: MCPStore.EntryStyle) -> [String: Any] {
        switch style {
        case .opencode:
            var dict: [String: Any] = ["enabled": enabled ?? true]
            if let url {
                dict["type"] = "remote"
                dict["url"] = url
            } else {
                dict["type"] = "local"
                dict["command"] = ([command].compactMap { $0 }) + args
                if !env.isEmpty { dict["environment"] = env }
            }
            return dict
        case .classic:
            var dict: [String: Any] = [:]
            if let command {
                dict["command"] = command
                if !args.isEmpty { dict["args"] = args }
            }
            if !env.isEmpty { dict["env"] = env }
            if let url { dict["url"] = url }
            return dict
        case .antigravity:
            var dict = rendered(for: .classic)
            if let url = dict.removeValue(forKey: "url") { dict["serverUrl"] = url }
            return dict
        }
    }
}

/// One assistant's MCP config as a place servers can be read from and written to.
public struct MCPStore: Equatable, Sendable {
    public let assistant: String
    public let file: URL
    /// Where the servers live in the file: `mcpServers` for most, `mcp` for opencode.
    public let section: String
    public let entryStyle: EntryStyle
    public let switchStyle: SwitchStyle

    public enum EntryStyle: Equatable, Sendable {
        /// `command` as a string plus `args` — Claude's shape, and Cursor's, Gemini's and
        /// Windsurf's too.
        case classic
        /// The same, with a remote server's URL spelled `serverUrl`. Antigravity's.
        case antigravity
        /// `type` plus an array `command` and `environment` — opencode's.
        case opencode
    }

    public enum SwitchStyle: Equatable, Sendable {
        /// An `enabled` flag inside the entry — flip it in place.
        case flagEnabled
        /// A `disabled` flag inside the entry — flip it in place. Antigravity's.
        case flagDisabled
        /// The format has no flag: off is the entry lifted out into Loadout's record, exactly
        /// as Claude's user-scope servers have always worked.
        case liftOut
    }

    /// The four JSON-config assistants Loadout can now write, in the order the matrix shows
    /// them. Claude and Antigravity have their own types — their files hold more than MCP and
    /// their switches have history — and Codex goes through its app-server; none of the three
    /// is described here.
    public static func stores(paths: Paths) -> [MCPStore] {
        [
            MCPStore(assistant: "cursor", file: paths.cursorMCP, section: "mcpServers",
                     entryStyle: .classic, switchStyle: .liftOut),
            MCPStore(assistant: "gemini", file: paths.geminiSettings, section: "mcpServers",
                     entryStyle: .classic, switchStyle: .liftOut),
            MCPStore(assistant: "windsurf", file: paths.windsurfMCP, section: "mcpServers",
                     entryStyle: .classic, switchStyle: .liftOut),
            MCPStore(assistant: "opencode", file: paths.opencodeConfig, section: "mcp",
                     entryStyle: .opencode, switchStyle: .flagEnabled),
        ]
    }

    public static func store(assistant: String, paths: Paths) -> MCPStore? {
        stores(paths: paths).first { $0.assistant == assistant }
    }
}

/// The generic reader and writer over one `MCPStore`.
///
/// Every write snapshots the target file first, like every other write Loadout makes. A file
/// that cannot be parsed is never overwritten — the assistant owns it, and a half-understood
/// config is worse than an untouched one.
public struct JSONMCP {
    public let paths: Paths
    public let store: MCPStore

    public init(paths: Paths, store: MCPStore) {
        self.paths = paths
        self.store = store
    }

    public init?(paths: Paths, assistant: String) {
        guard let store = MCPStore.store(assistant: assistant, paths: paths) else { return nil }
        self.init(paths: paths, store: store)
    }

    /// The live servers table, as the file has it. What the matrix copies a definition from.
    public func currentServers() -> [String: Any] {
        readServers() ?? [:]
    }

    /// One row per server in the file, plus the ones switched off and waiting in the record —
    /// off, not forgotten, exactly like Claude's.
    public func items() -> [Item] {
        guard let servers = readServers() else { return [] }
        var items = servers.map { name, value -> Item in
            let dict = value as? [String: Any] ?? [:]
            let entry = MCPEntry(dict: dict, style: store.entryStyle)
            return item(name: name, entry: entry, enabled: flagAllows(entry))
        }

        if store.switchStyle == .liftOut {
            let records = OffRecords(paths: paths)
            for (key, json) in records.servers() {
                let parts = key.components(separatedBy: "\u{1}")
                guard parts.count == 3, parts[0] == store.assistant else { continue }
                let name = parts[2]
                guard !items.contains(where: { $0.name == name }) else { continue }
                let dict = json.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                items.append(item(name: name, entry: MCPEntry(dict: dict, style: store.entryStyle),
                                  enabled: false))
            }
        }

        return items.sorted { $0.name < $1.name }
    }

    /// Off is what the format itself says, or — with no flag to say it with — the entry being
    /// lifted out and remembered, which is how Claude's user-scope servers have always worked.
    public func setServer(named name: String, enabled: Bool) throws {
        switch store.switchStyle {
        case .flagEnabled, .flagDisabled:
            guard let current = readServers()?[name] as? [String: Any] else {
                throw LoadoutError.notFound(name)
            }
            var entry = current
            if store.switchStyle == .flagEnabled {
                entry["enabled"] = enabled
            } else {
                if enabled { entry.removeValue(forKey: "disabled") } else { entry["disabled"] = true }
            }
            try mutate(name, replacingWith: entry)
        case .liftOut:
            let records = OffRecords(paths: paths)
            if enabled {
                guard let stored = records.server(named: name, project: nil, assistant: store.assistant),
                      let data = stored.data(using: .utf8),
                      let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { throw LoadoutError.notFound(name) }
                try mutate(name, replacingWith: entry)
                try records.forgetServer(named: name, project: nil, assistant: store.assistant)
            } else {
                guard let entry = readServers()?[name] else { throw LoadoutError.notFound(name) }
                let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                // Remembered first: if this throws, the server is still exactly where it was.
                try records.rememberServer(String(decoding: data, as: UTF8.self), named: name,
                                           project: nil, assistant: store.assistant)
                do {
                    try mutate(name, replacingWith: nil)
                } catch {
                    try? records.forgetServer(named: name, project: nil, assistant: store.assistant)
                    throw error
                }
            }
        }
    }

    /// Puts a brand-new server into the file, in this assistant's own format. A name that is
    /// already there is refused rather than overwritten — two definitions of one server is the
    /// exact confusion this app exists to remove.
    public func addServer(named name: String, entry: MCPEntry) throws {
        guard !name.isEmpty else { throw LoadoutError.invalidName(name) }
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.contains("\u{1}") else { throw LoadoutError.invalidName(name) }
        // A file that has never existed is started — the first server for an assistant is the
        // reason this exists. A file that exists but cannot be parsed is refused: it belongs to
        // the assistant, and half-understood JSON is not something to write back over.
        var root: [String: Any]
        if let data = try? Data(contentsOf: store.file) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LoadoutError.io("\(store.file.lastPathComponent) could not be parsed, so nothing was written.")
            }
            root = parsed
        } else {
            root = [:]
        }
        var servers = root[store.section] as? [String: Any] ?? [:]
        guard servers[name] == nil else { throw LoadoutError.alreadyExists(store.file) }
        try Backups(paths: paths).snapshot(store.file)
        servers[name] = entry.rendered(for: store.entryStyle)
        root[store.section] = servers
        try write(root)
    }

    /// Takes the entry out for good. The snapshot taken first is what stands in for the Trash.
    /// A server already switched off lives only in the record, so forgetting the record is the
    /// whole deletion in that case — the same rule Claude's removal follows.
    public func removeServer(named name: String) throws {
        let records = OffRecords(paths: paths)
        let live = readServers()?[name] != nil
        let remembered = records.server(named: name, project: nil, assistant: store.assistant) != nil
        guard live || remembered else { throw LoadoutError.notFound(name) }
        if live { try mutate(name, replacingWith: nil) }
        if remembered {
            try records.forgetServer(named: name, project: nil, assistant: store.assistant)
        }
    }

    // MARK: - Plumbing

    private func item(name: String, entry: MCPEntry, enabled: Bool) -> Item {
        Item(
            id: "mcp:\(store.assistant):\(name)", name: name, kind: .mcp, origin: .personal,
            description: entry.description, path: store.file,
            modified: (try? store.file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
            enabled: enabled, assistants: [store.assistant]
        )
    }

    private func flagAllows(_ entry: MCPEntry) -> Bool {
        switch store.switchStyle {
        case .flagEnabled: return entry.enabled ?? true
        case .flagDisabled: return entry.enabled != false
        case .liftOut: return true
        }
    }

    /// One entry changes, the rest of the file stays exactly as it was. `nil` removes — which
    /// requires the entry to be there; a replacement puts the entry in whether it was there or
    /// not, because that is how a lifted-out server comes back on.
    private func mutate(_ name: String, replacingWith replacement: [String: Any]?) throws {
        guard var root = readRoot() else {
            throw LoadoutError.io("Couldn't read \(store.file.lastPathComponent).")
        }
        var servers = root[store.section] as? [String: Any] ?? [:]
        if replacement == nil, servers[name] == nil { throw LoadoutError.notFound(name) }
        try Backups(paths: paths).snapshot(store.file)
        if let replacement { servers[name] = replacement } else { servers.removeValue(forKey: name) }
        root[store.section] = servers
        try write(root)
    }

    private func readRoot() -> [String: Any]? {
        guard let data = try? Data(contentsOf: store.file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readServers() -> [String: Any]? {
        readRoot()?[store.section] as? [String: Any]
    }

    private func write(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // The first server for an assistant creates its config, directory included — Cursor's
        // `.cursor` has often never been made by anything else.
        try FileManager.default.createDirectory(
            at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: store.file, options: .atomic)
    }
}
