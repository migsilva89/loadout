import Foundation

/// Reads the inventory off the disk. No caching, no cleverness: one pass produces the
/// whole picture, and the watcher just asks for another pass when something changes.
public struct InventoryScanner: Sendable {
    public let paths: Paths
    private var fm: FileManager { .default }

    public init(paths: Paths) {
        self.paths = paths
    }

    // MARK: - Whole inventory

    /// Everything the user owns or has installed, regardless of context.
    public func scanAll(project: Project? = nil) -> Inventory {
        var items: [Item] = []
        items += personalSkills()
        items += disabledSkills()
        items += markdownItems(in: paths.commands, kind: .command, origin: .personal)
        items += markdownItems(in: paths.agents, kind: .agent, origin: .personal)
        items += mcpServers()

        let plugins = installedPlugins()
        for plugin in plugins {
            items += pluginItems(plugin)
        }

        if let project {
            items += projectItems(project)
        }

        return Inventory(items: items, plugins: plugins)
    }

    // MARK: - Skills

    /// Personal skills, merged across assistants: one row per skill, carrying the set of
    /// assistants that load it. A skill only Codex has still shows up — with the Claude dot
    /// dark — because seeing the gap is the whole point.
    func personalSkills() -> [Item] {
        var byName: [String: Item] = [:]

        for assistant in Assistant.allCases {
            for folder in skillFolders(in: paths.skillsRoot(for: assistant)) {
                let name = folder.lastPathComponent
                if var existing = byName[name] {
                    existing.assistants.insert(assistant)
                    byName[name] = existing
                } else {
                    var item = skill(at: folder, origin: .personal, enabled: true)
                    item.assistants = [assistant]
                    byName[name] = item
                }
            }
        }

        return byName.values.sorted { $0.name < $1.name }
    }

    func disabledSkills() -> [Item] {
        skillFolders(in: paths.skillsOff).map { skill(at: $0, origin: .personal, enabled: false) }
    }

    func projectItems(_ project: Project) -> [Item] {
        var items = skillFolders(in: paths.projectSkills(project.path))
            .map { skill(at: $0, origin: .project(project.name), enabled: true) }
        items += markdownItems(
            in: paths.projectCommands(project.path), kind: .command, origin: .project(project.name)
        )
        items += markdownItems(
            in: paths.projectAgents(project.path), kind: .agent, origin: .project(project.name)
        )
        return items
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
            warning = warning ?? "O name no frontmatter (\(declared)) não coincide com a pasta (\(folderName))."
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
            warning: warning
        )
    }

    // MARK: - Commands and agents

    /// Commands and agents are single markdown files, with the same frontmatter convention.
    func markdownItems(in root: URL, kind: ItemKind, origin: Origin) -> [Item] {
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { file in
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let front = Frontmatter.parse(text)
                let stem = file.deletingPathExtension().lastPathComponent
                return Item(
                    id: "\(kind.rawValue):\(origin.label):\(stem)",
                    name: front.name ?? stem,
                    kind: kind,
                    origin: origin,
                    description: front.description ?? firstProseLine(front.body),
                    path: file,
                    directory: nil,
                    modified: modificationDate(file),
                    enabled: true,
                    // A command file legitimately has no frontmatter; only flag skills for that.
                    warning: front.fields.isEmpty ? nil : front.warning
                )
            }
    }

    // MARK: - Plugins

    public func installedPlugins() -> [PluginInfo] {
        guard let data = try? Data(contentsOf: paths.installedPlugins),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any]
        else { return [] }

        let enabledMap = enabledPluginFlags()
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
                enabled: enabledMap[key] ?? true
            ))
        }
        return result.sorted { $0.name < $1.name }
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

    func pluginItems(_ plugin: PluginInfo) -> [Item] {
        let origin = Origin.plugin(plugin.name)
        var items = skillFolders(in: plugin.installPath.appendingPathComponent("skills"))
            .map { skill(at: $0, origin: origin, enabled: plugin.enabled) }
        items += markdownItems(
            in: plugin.installPath.appendingPathComponent("commands"), kind: .command, origin: origin
        )
        items += markdownItems(
            in: plugin.installPath.appendingPathComponent("agents"), kind: .agent, origin: origin
        )
        return items.map {
            var item = $0
            item.enabled = plugin.enabled
            return item
        }
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
                    items.append(mcpItem(name: name, config: config, origin: .project(label)))
                }
            }
        }

        return items.sorted { $0.name < $1.name }
    }

    private func mcpItem(name: String, config: Any, origin: Origin) -> Item {
        var description = "Servidor MCP"
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
