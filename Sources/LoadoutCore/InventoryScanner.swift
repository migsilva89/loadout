import Foundation

/// Reads the inventory off the disk. No caching, no cleverness: one pass produces the
/// whole picture, and the watcher just asks for another pass when something changes.
public struct InventoryScanner: Sendable {
    public let paths: Paths
    /// Discovered once per scanner, so a newly installed assistant shows up on the next reload.
    public let assistants: [Assistant]
    private var fm: FileManager { .default }

    public init(paths: Paths) {
        self.paths = paths
        self.assistants = AssistantRegistry.discover(paths: paths)
    }

    // MARK: - Whole inventory

    /// Everything the user owns or has installed, regardless of context.
    public func scanAll(project: Project? = nil) -> Inventory {
        var items: [Item] = []
        items += personalSkills()
        items += disabledSkills()
        items += personalCommands()
        items += markdownItems(in: paths.agents, kind: .agent, origin: .personal)
        items += markdownItems(
            in: paths.agentsOff, kind: .agent, origin: .personal, enabled: false
        )
        items += mcpServers()

        let plugins = installedPlugins()
        // Before reading them: an update may have brought back skills the user turned off.
        reapplyPluginChoices(plugins)
        for plugin in plugins {
            items += pluginItems(plugin)
        }

        if let project {
            // The scope answers "what belongs to this project", not "what would load
            // there": mixing the global inventory in made a project with nothing of its
            // own look exactly like Global, which read as the scope being broken.
            //
            // Plugins are the exception, and read again with the project in hand: they are
            // installed once for the machine, but a repository may have turned one off for whoever
            // works in it, and that is the state this scope has to show.
            return Inventory(
                items: projectItems(project), plugins: installedPlugins(project: project)
            )
        }

        return Inventory(items: items, plugins: plugins)
    }

    /// Everything on the machine at once: what is yours, what every project holds, what the
    /// plugins ship — each item still carrying the origin it really has.
    ///
    /// Deliberately not what any assistant sees. Claude in one repository loads your own plus that
    /// repository's, never another project's, so this is a place to find something rather than a
    /// picture of what is active. The caller says so on screen; the scanner only promises that
    /// nothing here is invented.
    public func scanEverything(projects: [Project]) -> Inventory {
        let global = scanAll()
        var items = global.items
        // Read once for the whole walk, not once per repository.
        let claudeRoot = readClaudeRoot()
        for project in projects {
            items += projectItems(project, claudeRoot: claudeRoot)
        }
        return Inventory(items: items, plugins: global.plugins)
    }

    // MARK: - Skills

    /// Personal skills, merged across assistants: one row per skill, carrying the set of
    /// assistants that load it. A skill only Codex has still shows up — with the Claude dot
    /// dark — because seeing the gap is the whole point.
    func personalSkills() -> [Item] {
        var byName: [String: Item] = [:]

        for assistant in assistants {
            for folder in skillFolders(in: assistant.skillsRoot) {
                let name = folder.lastPathComponent
                if var existing = byName[name] {
                    existing.assistants.insert(assistant.id)
                    byName[name] = existing
                } else {
                    var item = skill(at: folder, origin: .personal, enabled: true)
                    item.assistants = [assistant.id]
                    byName[name] = item
                }
            }
        }

        return byName.values.sorted { $0.name < $1.name }
    }

    /// Everything parked in a `skills-off`, wherever it is parked.
    ///
    /// One per assistant plus the shared store, because a disabled skill stays with its owner: a
    /// Codex skill waits in `~/.codex/skills-off`, and reading only Claude's would make it look
    /// deleted.
    func disabledSkills() -> [Item] {
        var roots = assistants.map { $0.skillsRoot.deletingLastPathComponent().appendingPathComponent("skills-off") }
        roots.append(paths.sharedSkills.deletingLastPathComponent().appendingPathComponent("skills-off"))

        var byName: [String: Item] = [:]
        for root in roots {
            for folder in skillFolders(in: root) where byName[folder.lastPathComponent] == nil {
                byName[folder.lastPathComponent] = skill(at: folder, origin: .personal, enabled: false)
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// `claudeRoot` lets a caller that walks many projects parse `~/.claude.json` once and hand the
    /// same copy to each of them.
    func projectItems(_ project: Project, claudeRoot: [String: Any]? = nil) -> [Item] {
        var items = skillFolders(in: paths.projectSkills(project.path))
            .map { skill(at: $0, origin: .project(project.name), enabled: true) }
        items += skillFolders(in: paths.projectSkillsOff(project.path))
            .map { skill(at: $0, origin: .project(project.name), enabled: false) }
        items += markdownItems(
            in: paths.projectCommands(project.path), kind: .command, origin: .project(project.name)
        )
        items += markdownItems(
            in: paths.projectCommandsOff(project.path), kind: .command,
            origin: .project(project.name), enabled: false
        )
        items += markdownItems(
            in: paths.projectAgents(project.path), kind: .agent, origin: .project(project.name)
        )
        items += markdownItems(
            in: paths.projectAgentsOff(project.path), kind: .agent,
            origin: .project(project.name), enabled: false
        )
        items += repositoryServers(project, claudeRoot: claudeRoot)
        return items
    }

    /// The MCP servers a repository ships in its own `.mcp.json`, which is how a team hands
    /// everybody the same servers.
    ///
    /// Read here and nowhere else: `~/.claude.json` holds your servers and the ones Claude filed
    /// under a project, and it says nothing about this file. Without this pass a repository could
    /// hand Claude three servers and the app would show none of them, which is the one thing it
    /// promises not to do.
    /// `claudeRoot` is the already-parsed `~/.claude.json` when the caller has it. That file is
    /// large and holds every project's state, so parsing it once per project with a `.mcp.json` was
    /// work repeated for no reason on a machine with many repositories.
    func repositoryServers(_ project: Project, claudeRoot: [String: Any]? = nil) -> [Item] {
        let file = paths.projectMCPJSON(project.path)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return [] }

        let answers = repositoryServerAnswers(
            project: project.path.path, claudeRoot: claudeRoot ?? readClaudeRoot()
        )
        return servers.map { name, config in
            var item = mcpItem(name: name, config: config, origin: .project(project.name))
            // Its own id space: the same name can be in this file and in your own config under the
            // same project, and one id for both would show a single row acting on the wrong file.
            item.id = "mcp-repo:\(project.path.path):\(name)"
            item.path = file
            item.modified = modificationDate(file)
            item.projectDirectory = project.path.path
            item.declaredByRepository = true
            if answers.declined.contains(name) {
                item.enabled = false
            } else if answers.approved.contains(name) {
                item.enabled = true
            } else {
                // Never answered. Claude Code asks before it loads the servers a repository ships,
                // and until that is answered it loads none of them — so showing this as on would be
                // the app claiming something the assistant is not doing. Off, and said why.
                item.enabled = false
                item.warning = "Not approved yet, so Claude is not loading it. Turning it on here is the answer it is waiting for."
            }
            return item
        }
        .sorted { $0.name < $1.name }
    }

    /// What this machine has answered about the servers one repository ships, from
    /// `enabledMcpjsonServers` and `disabledMcpjsonServers` in `~/.claude.json`.
    ///
    /// Claude Code keeps the answer to "do I trust the servers this repository ships?" in your own
    /// config, per project. That is the only place it can live, because the file being answered
    /// about belongs to the team.
    private func repositoryServerAnswers(
        project: String, claudeRoot: [String: Any]?
    ) -> (approved: Set<String>, declined: Set<String>) {
        guard let projects = claudeRoot?["projects"] as? [String: Any],
              let entry = projects[project] as? [String: Any]
        else { return ([], []) }
        return (
            Set(entry["enabledMcpjsonServers"] as? [String] ?? []),
            Set(entry["disabledMcpjsonServers"] as? [String] ?? [])
        )
    }

    func readClaudeRoot() -> [String: Any]? {
        guard let data = try? Data(contentsOf: paths.claudeJSON) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Subdirectories that actually carry a `SKILL.md`. A stray folder is not a skill.
    ///
    /// Skills are routinely symlinked in from elsewhere (a shared `.agents/skills` tree, a
    /// checked-out library), so the directory test has to follow links — `URL.isDirectory`
    /// does not, and would silently drop them from the inventory.
    func skillFolders(in root: URL) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { isDirectory($0) }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    func skill(at folder: URL, origin: Origin, enabled: Bool) -> Item {
        let file = folder.appendingPathComponent("SKILL.md")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let front = Frontmatter.parse(text)
        let folderName = folder.lastPathComponent
        var warning = front.warning
        if let declared = front.name, declared != folderName {
            warning = warning ?? "The name in the frontmatter (\(declared)) doesn't match the folder (\(folderName))."
        }
        return Item(
            id: "skill:\(origin.label):\(folderName)",
            name: front.name ?? folderName,
            kind: .skill,
            origin: origin,
            description: front.description ?? "",
            path: file,
            directory: folder,
            modified: modificationDate(file),
            enabled: enabled,
            warning: warning,
            budget: Budget.measure(document: text)
        )
    }

    // MARK: - Commands

    /// Slash commands across every assistant, merged into one row each, plus the ones parked off.
    ///
    /// The same shape `personalSkills` uses, and for the same reason: a tab that reads Claude only
    /// says 29 while quietly meaning "29 of Claude's", and the gap between assistants is the thing
    /// worth seeing.
    func personalCommands() -> [Item] {
        var byName: [String: Item] = [:]

        for assistant in assistants {
            for file in markdownFiles(in: assistant.commandsRoot) {
                let stem = file.deletingPathExtension().lastPathComponent
                if var existing = byName[stem] {
                    existing.assistants.insert(assistant.id)
                    byName[stem] = existing
                } else {
                    var item = markdownItem(at: file, kind: .command, origin: .personal, enabled: true)
                    item.assistants = [assistant.id]
                    byName[stem] = item
                }
            }
        }

        var off: [String: Item] = [:]
        for assistant in assistants {
            let root = assistant.commandsRoot.deletingLastPathComponent()
                .appendingPathComponent(assistant.commandsRoot.lastPathComponent + "-off")
            for file in markdownFiles(in: root) {
                let stem = file.deletingPathExtension().lastPathComponent
                guard byName[stem] == nil, off[stem] == nil else { continue }
                off[stem] = markdownItem(at: file, kind: .command, origin: .personal, enabled: false)
            }
        }

        return (Array(byName.values) + Array(off.values)).sorted { $0.name < $1.name }
    }

    // MARK: - Commands and agents

    /// Commands and agents are single markdown files, with the same frontmatter convention.
    func markdownItems(in root: URL, kind: ItemKind, origin: Origin, enabled: Bool = true) -> [Item] {
        markdownFiles(in: root).map { markdownItem(at: $0, kind: kind, origin: origin, enabled: enabled) }
    }

    func markdownFiles(in root: URL) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func markdownItem(at file: URL, kind: ItemKind, origin: Origin, enabled: Bool) -> Item {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let front = Frontmatter.parse(text)
        let stem = file.deletingPathExtension().lastPathComponent
        // The Agent tool calls a subagent by the `name` in its frontmatter, so one that disagrees
        // with its file name will not answer to what the list shows.
        var warning = front.structuralWarning
        if kind == .agent, let declared = front.name, declared != stem {
            warning = warning ?? "The name in the frontmatter (\(declared)) doesn't match the file (\(stem))."
        }
        return Item(
            id: "\(kind.rawValue):\(origin.label):\(stem)",
            name: stem,
            kind: kind,
            origin: origin,
            description: front.description ?? firstProseLine(front.body),
            path: file,
            directory: nil,
            modified: modificationDate(file),
            enabled: enabled,
            // A command is named after its file and has no `name` field to miss. Only what makes
            // the block unreadable is worth an amber banner here (AC10.1, AC10.2).
            warning: warning,
            budget: Budget.measure(document: text)
        )
    }

    // MARK: - Plugins

    public func installedPlugins(project: Project? = nil) -> [PluginInfo] {
        guard let data = try? Data(contentsOf: paths.installedPlugins),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any]
        else { return [] }

        let enabledMap = enabledPluginFlags()
        // What the repository decided, read only when a repository is being looked at. Its answer
        // is applied over yours because that is the order Claude Code reads the two files in.
        let repositoryMap = project.map { repositoryPluginFlags(project: $0) } ?? [:]
        var result: [PluginInfo] = []

        for (key, value) in plugins {
            // Key shape: "<plugin>@<marketplace>"
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            let name = parts.first ?? key
            let marketplace = parts.count > 1 ? parts[1] : ""
            guard let installs = value as? [[String: Any]] else { continue }
            // A plugin can be installed at several scopes; the user scope is the live one.
            let install = installs.first { ($0["scope"] as? String) == "user" } ?? installs.first
            guard let install,
                  let installPath = install["installPath"] as? String
            else { continue }
            result.append(PluginInfo(
                id: key,
                name: name,
                marketplace: marketplace,
                version: install["version"] as? String ?? "",
                installPath: URL(fileURLWithPath: installPath),
                // Absent from enabledPlugins means enabled: Claude Code opts in by default.
                enabled: repositoryMap[key] ?? enabledMap[key] ?? true,
                repositoryChoice: repositoryMap[key]
            ))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// `enabledPlugins` from the repository's own settings, the gitignored file last.
    ///
    /// This is the plugin half of what `.mcp.json` does for servers: a repository saying what its
    /// contributors load. Reading only `~/.claude` showed a plugin as on while the repository had
    /// it off, which is the app claiming something the assistant would not do.
    func repositoryPluginFlags(project: Project) -> [String: Bool] {
        var flags: [String: Bool] = [:]
        for file in [paths.projectSettings(project.path), paths.projectLocalSettings(project.path)] {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let enabled = root["enabledPlugins"] as? [String: Any]
            else { continue }
            for (key, value) in enabled {
                if let bool = value as? Bool { flags[key] = bool }
            }
        }
        return flags
    }

    /// `enabledPlugins` can live in either settings file; the local one wins, as Claude Code does.
    func enabledPluginFlags() -> [String: Bool] {
        var flags: [String: Bool] = [:]
        for file in [paths.settings, paths.localSettings] {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let enabled = root["enabledPlugins"] as? [String: Any]
            else { continue }
            for (key, value) in enabled {
                if let bool = value as? Bool { flags[key] = bool }
            }
        }
        return flags
    }

    /// What a plugin ships, each item carrying **its own** state.
    ///
    /// Not the plugin's: a skill sitting in the plugin's `skills` folder is switched on, whether or
    /// not the plugin as a whole is. Folding the two together made every row of a disabled plugin
    /// claim to be off, and flipping one of those switches then tried to re-enable something that
    /// had never been parked — it failed with "already exists". Whether the plugin is in the house
    /// at all is the plugin's own switch, and the app says that separately.
    func pluginItems(_ plugin: PluginInfo) -> [Item] {
        let origin = Origin.plugin(plugin.name)
        var items = skillFolders(in: plugin.installPath.appendingPathComponent("skills"))
            .map { skill(at: $0, origin: origin, enabled: true) }
        // Skills the user switched off one by one. They keep the plugin's own switch state out of
        // it: a skill parked here is off because it was chosen, not because the plugin is off.
        var off = skillFolders(in: plugin.installPath.appendingPathComponent("skills-off"))
            .map { skill(at: $0, origin: origin, enabled: false) }
        off += markdownItems(
            in: plugin.installPath.appendingPathComponent("commands-off"), kind: .command,
            origin: origin, enabled: false
        )
        off += markdownItems(
            in: plugin.installPath.appendingPathComponent("agents-off"), kind: .agent,
            origin: origin, enabled: false
        )
        items += markdownItems(
            in: plugin.installPath.appendingPathComponent("commands"), kind: .command, origin: origin
        )
        items += markdownItems(
            in: plugin.installPath.appendingPathComponent("agents"), kind: .agent, origin: origin
        )
        return (items + off).map {
            var item = $0
            item.pluginID = plugin.id
            return item
        }
    }

    /// Puts back whatever a plugin update undid, before the inventory is read.
    ///
    /// A new version arrives as a clean copy from the plugin's repository and knows nothing of the
    /// skills the user switched off. Without this, they would all come back on and it would look
    /// like Loadout had lost the setting.
    @discardableResult
    public func reapplyPluginChoices(_ plugins: [PluginInfo]) -> [String] {
        let mutations = Mutations(paths: paths)
        guard !mutations.records.pluginEntries().isEmpty else { return [] }
        return plugins.flatMap { mutations.reapplyDisabledSkills(of: $0) }
    }

    // MARK: - MCP servers

    /// MCP servers live inside `~/.claude.json` rather than in files of their own, both
    /// globally and per project directory.
    func mcpServers() -> [Item] {
        guard let data = try? Data(contentsOf: paths.claudeJSON),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var items: [Item] = []

        if let global = root["mcpServers"] as? [String: Any] {
            for (name, config) in global {
                items.append(mcpItem(name: name, config: config, origin: .personal))
            }
        }

        if let projects = root["projects"] as? [String: Any] {
            for (dir, value) in projects {
                guard let project = value as? [String: Any],
                      let servers = project["mcpServers"] as? [String: Any],
                      !servers.isEmpty
                else { continue }
                let label = URL(fileURLWithPath: dir).lastPathComponent
                for (name, config) in servers {
                    var item = mcpItem(name: name, config: config, origin: .project(label))
                    item.projectDirectory = dir
                    items.append(item)
                }
            }
        }

        // The ones switched off: their entry is out of `~/.claude.json`, so the only place they
        // exist is Loadout's record. Listing them is what makes the switch reversible in the eyes
        // of whoever flipped it — off, not forgotten (AC11.11).
        let records = OffRecords(paths: paths)
        for (key, json) in records.servers() {
            let parts = key.components(separatedBy: "\u{1}")
            guard parts.count == 2 else { continue }
            let project = parts[0]
            let name = parts[1]
            let origin: Origin = project.isEmpty
                ? .personal
                : .project(URL(fileURLWithPath: project).lastPathComponent)
            // A record can outlive its server — the entry was put back by hand, or by whatever
            // installed it in the first place. The live one wins: two rows with one id would show
            // twice and let the stale copy overwrite the working config.
            let live = items.contains {
                $0.kind == .mcp && $0.name == name && $0.projectDirectory == (project.isEmpty ? nil : project)
            }
            guard !live else { continue }
            let config = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            var item = mcpItem(name: name, config: config ?? [:], origin: origin)
            item.enabled = false
            item.projectDirectory = project.isEmpty ? nil : project
            items.append(item)
        }

        return items.sorted { $0.name < $1.name }
    }

    private func mcpItem(name: String, config: Any, origin: Origin) -> Item {
        var description = "MCP server"
        if let dict = config as? [String: Any] {
            if let command = dict["command"] as? String {
                description = command
                if let args = dict["args"] as? [String], !args.isEmpty {
                    description += " " + args.joined(separator: " ")
                }
            } else if let url = dict["url"] as? String {
                description = url
            } else if let type = dict["type"] as? String {
                description = type
            }
        }
        return Item(
            id: "mcp:\(origin.label):\(name)",
            name: name,
            kind: .mcp,
            origin: origin,
            description: description,
            path: paths.claudeJSON,
            directory: nil,
            modified: modificationDate(paths.claudeJSON),
            enabled: true
        )
    }

    // MARK: - Helpers

    func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Fallback description for files with no frontmatter: the first real line of prose.
    func firstProseLine(_ body: String) -> String {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("---") { continue }
            return String(trimmed.prefix(160))
        }
        return ""
    }
}

/// One pass over the disk.
public struct Inventory: Sendable {
    public var items: [Item]
    public var plugins: [PluginInfo]

    public init(items: [Item] = [], plugins: [PluginInfo] = []) {
        self.items = items
        self.plugins = plugins
    }

    public func items(kind: ItemKind) -> [Item] { items.filter { $0.kind == kind } }

    public var personalSkills: [Item] {
        items.filter { $0.kind == .skill && $0.origin == .personal && $0.enabled }
    }
    public var disabled: [Item] { items.filter { !$0.enabled && $0.kind == .skill } }
}
