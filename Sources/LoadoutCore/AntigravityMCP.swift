import Foundation

/// Antigravity's MCP servers, in `~/.gemini/config/mcp_config.json`.
///
/// The one MCP format of the three that has a switch of its own: `agy mcp disable` writes
/// `"disabled": true` into the server's entry and leaves everything else where it was, and that is
/// exactly what Loadout does too — no entry is ever lifted out to remember it elsewhere, so nothing
/// here needs the off-record Claude's servers need. The file is snapshotted before every write and
/// rewritten whole, so a server's other keys — `env`, `args`, `serverUrl` — come back as they went.
struct AntigravityMCP {
    let paths: Paths

    var file: URL { paths.antigravityConfig.appendingPathComponent("mcp_config.json") }

    /// One row per server, owned by Antigravity, off when the flag says so.
    func items() -> [Item] {
        guard let root = read() else { return [] }
        let servers = root["mcpServers"] as? [String: Any] ?? [:]
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return servers.map { name, config in
            let dict = config as? [String: Any] ?? [:]
            return Item(
                id: "mcp:antigravity:\(name)", name: name, kind: .mcp, origin: .personal,
                description: Self.describe(dict), path: file, modified: modified,
                enabled: (dict["disabled"] as? Bool) != true, assistants: ["antigravity"]
            )
        }.sorted { $0.name < $1.name }
    }

    /// Flips the flag agy itself uses, and nothing else in the entry.
    func setServer(named name: String, enabled: Bool) throws {
        try mutate(name) { original in
            var entry = original
            if enabled { entry.removeValue(forKey: "disabled") } else { entry["disabled"] = true }
            return entry
        }
    }

    /// Takes the entry out for good. The snapshot taken first is what stands in for the Trash.
    func removeServer(named name: String) throws {
        try mutate(name) { _ in nil }
    }

    private func mutate(_ name: String, _ change: ([String: Any]) -> [String: Any]?) throws {
        guard var root = read() else {
            throw LoadoutError.io("Couldn't read \(file.lastPathComponent).")
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        guard let entry = servers[name] as? [String: Any] else { throw LoadoutError.notFound(name) }
        try Backups(paths: paths).snapshot(file)
        if let changed = change(entry) { servers[name] = changed } else { servers.removeValue(forKey: name) }
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

    private func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The same sentence the Claude rows use: the command and its arguments, or the URL.
    static func describe(_ dict: [String: Any]) -> String {
        if let command = dict["command"] as? String {
            let args = dict["args"] as? [String] ?? []
            return args.isEmpty ? command : command + " " + args.joined(separator: " ")
        }
        if let url = dict["serverUrl"] as? String ?? dict["url"] as? String { return url }
        return "MCP server"
    }
}
