import Foundation

/// What Loadout remembers about the things it has switched off.
///
/// Two questions the disk cannot answer on its own: which assistants were loading a skill before
/// it was parked, and which plugin skills the user turned off — a plugin update ships a clean copy
/// from the plugin's repository and knows nothing of that choice.
///
/// Kept in Loadout's own support directory rather than inside the skill folders: a stray file there
/// would show up in the user's repository and travel with a skill that is shared or published.
/// Losing this file is never an error. It degrades: enabling asks with only the owner ticked, and a
/// plugin's skills come back on at the next update.
public struct OffRecords: Sendable {
    public let paths: Paths
    private var fm: FileManager { .default }

    public init(paths: Paths) {
        self.paths = paths
    }

    // MARK: - Personal and project skills

    /// One skill, as it stood the moment it was switched off.
    public struct Entry: Equatable, Codable, Sendable {
        public var name: String
        /// An assistant id, or `shared` for `~/.agents/skills`.
        public var owner: String
        /// The assistants that were loading it.
        public var assistants: [String]
        public var disabledAt: Date

        public init(name: String, owner: String, assistants: [String], disabledAt: Date) {
            self.name = name
            self.owner = owner
            self.assistants = assistants
            self.disabledAt = disabledAt
        }
    }

    struct SkillFile: Codable {
        var version: Int
        var entries: [Entry]
    }

    /// `shared` is not an assistant id — no assistant directory is called `.shared` — so it can
    /// stand for `~/.agents/skills` in the same field without ever colliding with a real one.
    public static let sharedOwner = "shared"

    var skillsFile: URL { paths.support.appendingPathComponent("skills-off.json") }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: skillsFile),
              let file = try? decoder.decode(SkillFile.self, from: data)
        else { return [] }
        return file.entries
    }

    public func entry(named name: String) -> Entry? {
        entries().first { $0.name == name }
    }

    public func remember(_ entry: Entry) throws {
        var all = entries().filter { $0.name != entry.name }
        all.append(entry)
        try writeSkills(all)
    }

    public func forget(_ name: String) throws {
        let all = entries()
        guard all.contains(where: { $0.name == name }) else { return }
        try writeSkills(all.filter { $0.name != name })
    }

    private func writeSkills(_ entries: [Entry]) throws {
        try write(SkillFile(version: 1, entries: entries.sorted { $0.name < $1.name }), to: skillsFile)
    }

    // MARK: - Plugin skills

    struct PluginFile: Codable {
        var version: Int
        var plugins: [String: [String]]
    }

    var pluginsFile: URL { paths.support.appendingPathComponent("plugin-skills-off.json") }

    /// What is switched off inside each plugin, per `"<plugin>@<marketplace>"` key.
    ///
    /// Entries are paths relative to the plugin's installed version — `skills/vercel-functions`,
    /// `commands/status.md` — so one record covers both kinds and a skill never collides with a
    /// command of the same name. Bare names from the first version of this file are read as skills,
    /// which is all it could hold.
    public func pluginEntries() -> [String: [String]] {
        guard let data = try? Data(contentsOf: pluginsFile),
              let file = try? decoder.decode(PluginFile.self, from: data)
        else { return [:] }
        return file.plugins.mapValues { $0.map { $0.contains("/") ? $0 : "skills/\($0)" } }
    }

    public func pluginEntries(of pluginID: String) -> [String] {
        pluginEntries()[pluginID] ?? []
    }

    /// The skill names turned off in a plugin, without the `skills/` in front.
    public func pluginSkills(of pluginID: String) -> [String] {
        pluginEntries(of: pluginID)
            .filter { $0.hasPrefix("skills/") }
            .map { String($0.dropFirst("skills/".count)) }
    }

    public func rememberPluginEntry(_ entry: String, in pluginID: String) throws {
        var all = pluginEntries()
        var entries = Set(all[pluginID] ?? [])
        entries.insert(entry)
        all[pluginID] = entries.sorted()
        try writePlugins(all)
    }

    public func forgetPluginEntry(_ entry: String, in pluginID: String) throws {
        var all = pluginEntries()
        guard var entries = all[pluginID], entries.contains(entry) else { return }
        entries.removeAll { $0 == entry }
        // An empty list is the same as no list, and leaving it behind grows the file forever.
        if entries.isEmpty { all.removeValue(forKey: pluginID) } else { all[pluginID] = entries }
        try writePlugins(all)
    }

    private func writePlugins(_ plugins: [String: [String]]) throws {
        try write(PluginFile(version: 1, plugins: plugins), to: pluginsFile)
    }

    // MARK: - MCP servers

    /// An MCP server is not a file — it is an entry inside `~/.claude.json` — so switching it off
    /// means lifting that entry out, and switching it on means putting back exactly what was
    /// lifted. This is where it waits in between, as the JSON it was.
    struct ServerFile: Codable {
        var version: Int
        /// Keyed by `"<project path or empty>\u{1}<server name>"`, so a project's server and a
        /// global one of the same name never overwrite each other.
        var servers: [String: String]
    }

    var serversFile: URL { paths.support.appendingPathComponent("mcp-off.json") }

    static func serverKey(name: String, project: String?) -> String {
        "\(project ?? "")\u{1}\(name)"
    }

    public func servers() -> [String: String] {
        guard let data = try? Data(contentsOf: serversFile) else { return [:] }
        if let file = try? decoder.decode(ServerFile.self, from: data) { return file.servers }
        // A file that cannot be decoded must not read as "nothing was switched off": that made a
        // disabled server vanish from the list, and with it the only way to switch it back on.
        // Whatever can still be salvaged is salvaged, and `unreadable` says the rest out loud.
        guard let loose = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = loose["servers"] as? [String: String]
        else { return [:] }
        return servers
    }

    /// The records that exist on disk but could not be read at all. The app says so rather than
    /// behaving as though the user had never switched anything off.
    public func unreadable() -> [URL] {
        [skillsFile, pluginsFile, serversFile].filter { file in
            guard let data = try? Data(contentsOf: file) else { return false }
            return (try? JSONSerialization.jsonObject(with: data)) == nil
        }
    }

    /// The stored entry, as JSON text, or nil if this one is not switched off.
    public func server(named name: String, project: String? = nil) -> String? {
        servers()[Self.serverKey(name: name, project: project)]
    }

    public func rememberServer(_ json: String, named name: String, project: String? = nil) throws {
        var all = servers()
        all[Self.serverKey(name: name, project: project)] = json
        try write(ServerFile(version: 1, servers: all), to: serversFile)
    }

    public func forgetServer(named name: String, project: String? = nil) throws {
        var all = servers()
        guard all.removeValue(forKey: Self.serverKey(name: name, project: project)) != nil else { return }
        try write(ServerFile(version: 1, servers: all), to: serversFile)
    }

    // MARK: - What the user has been told once

    /// "Don't tell me again", for the note that disabling something inside a repository shows up in
    /// the working tree.
    ///
    /// Kept here rather than in `UserDefaults` because everything else the app knows is derived
    /// from its injected roots, and this was the one exception: a fixture home inherited the answer
    /// a completely different home had given, which made the warning untestable and, on a machine
    /// with two accounts' worth of state, unpredictable.
    struct FlagFile: Codable {
        var version: Int
        var seenProjectWarning: Bool
    }

    var flagsFile: URL { paths.support.appendingPathComponent("told-once.json") }

    public var hasSeenProjectWarning: Bool {
        guard let data = try? Data(contentsOf: flagsFile),
              let file = try? decoder.decode(FlagFile.self, from: data)
        else { return false }
        return file.seenProjectWarning
    }

    public func rememberProjectWarning() throws {
        try write(FlagFile(version: 1, seenProjectWarning: true), to: flagsFile)
    }

    // MARK: - Shared plumbing

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw LoadoutError.io("Couldn't write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
