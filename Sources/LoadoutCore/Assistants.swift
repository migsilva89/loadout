import Foundation

/// A coding assistant that reads skills from `~/.<id>/skills`.
///
/// Not an enum: the set is whatever is on this machine. Install another assistant tomorrow
/// and it appears on its own, with no code change here.
public struct Assistant: Identifiable, Hashable, Sendable {
    /// The dot-directory name — `claude`, `codex`, `trae`.
    public let id: String
    public let label: String
    public let skillsRoot: URL
    /// The installed app, when there is one. Used to show its real icon rather than a
    /// hand-drawn imitation of someone's trademark.
    public let appPath: String?
    /// Whether it already keeps a skills directory. False means it is on the machine but has
    /// never had a skill — putting the first one there creates the folder.
    public let hasSkillsFolder: Bool
    /// Whether the assistant itself is on this machine — its app, or its command-line tool.
    ///
    /// A dot-directory outlives the thing that made it: uninstall Trae and `~/.trae` stays, with
    /// whatever was linked into it. Such an assistant is still *discovered* (a skill linked into
    /// its folder is still a skill, and the scanner must see it) but it is not one the person can
    /// use, so the app does not offer it a column, a mark or a switch.
    public let isInstalled: Bool
    /// The directory its commands and subagents sit in. `~/.<id>` for nearly everyone; opencode
    /// keeps them under `~/.config/opencode`, which is why this is stored rather than derived.
    public let configHome: URL

    public init(
        id: String, label: String, skillsRoot: URL, appPath: String? = nil,
        hasSkillsFolder: Bool = true, isInstalled: Bool = true, configHome: URL? = nil
    ) {
        self.id = id
        self.label = label
        self.skillsRoot = skillsRoot
        self.appPath = appPath
        self.hasSkillsFolder = hasSkillsFolder
        self.isInstalled = isInstalled
        self.configHome = configHome ?? skillsRoot.deletingLastPathComponent()
    }

    /// Two letters for when there is no app icon to show.
    public var initials: String {
        String(label.replacingOccurrences(of: " ", with: "").prefix(2)).uppercased()
    }

    /// Where this assistant keeps its slash commands.
    ///
    /// Claude Code calls them commands and keeps them in `~/.claude/commands`; Codex calls them
    /// prompts and keeps them in `~/.codex/prompts`; opencode says `command` or `commands` under
    /// its config directory. Same thing — a markdown file named after the command — under several
    /// names, so the folder is chosen by whichever exists and falls back to the assistant's own
    /// convention when none does yet.
    public var commandsRoot: URL {
        let names = AssistantRegistry.commandFolders[id] ?? ["commands", "prompts"]
        return existingFolder(among: names) ?? configHome.appendingPathComponent(
            id == "codex" ? "prompts" : (names.first ?? "commands")
        )
    }

    /// Where this assistant keeps subagent files, or nil when it keeps none Loadout knows about.
    ///
    /// Not every assistant has the idea. Those that do read a markdown file with frontmatter from
    /// a folder, which is what makes a symlink a sound way to share one; for the rest there is
    /// nothing to link into, and inventing a folder nobody reads would be a lie in the shape of a
    /// feature. An assistant that has the idea but no folder yet gets the conventional one.
    public var agentsRoot: URL? {
        guard let names = AssistantRegistry.agentFolders[id] else { return nil }
        return existingFolder(among: names) ?? configHome.appendingPathComponent(names[0])
    }

    private func existingFolder(among names: [String]) -> URL? {
        let fm = FileManager.default
        return names.map { configHome.appendingPathComponent($0) }
            .first { fm.fileExists(atPath: $0.path) }
    }
}

public enum AssistantRegistry {
    /// Nicer names, and where each assistant's Mac app lives when it has one.
    /// Anything not listed still shows up, under its directory name.
    public static let known: [String: (label: String, app: String?)] = [
        "claude": ("Claude Code", "/Applications/Claude.app"),
        "codex": ("Codex", "/Applications/ChatGPT.app"),
        "cursor": ("Cursor", "/Applications/Cursor.app"),
        "windsurf": ("Windsurf", "/Applications/Windsurf.app"),
        "trae": ("Trae", "/Applications/Trae.app"),
        "kiro": ("Kiro", "/Applications/Kiro.app"),
        "factory": ("Factory", nil),
        "hermes": ("Hermes", nil),
        "commandcode": ("CommandCode", nil),
        "gemini": ("Gemini", nil),
        "antigravity": ("Antigravity", "/Applications/Antigravity.app"),
        "copilot": ("Copilot", nil),
        "opencode": ("opencode", "/Applications/OpenCode.app"),
        "droid": ("Droid", nil),
    ]

    /// The command-line tools that mean an assistant is installed, for the ones with no Mac app —
    /// and for the ones with one, since the app is not what every person runs. An id missing here
    /// is looked for under its own name.
    static let binaries: [String: [String]] = [
        "claude": ["claude"],
        "codex": ["codex"],
        "cursor": ["cursor-agent", "cursor"],
        "windsurf": ["windsurf"],
        "trae": ["trae"],
        "kiro": ["kiro-cli", "kiro"],
        "factory": ["droid"],
        "droid": ["droid"],
        "hermes": ["hermes"],
        "commandcode": ["commandcode", "cmd"],
        "gemini": ["gemini"],
        "antigravity": ["agy"],
        "copilot": ["copilot"],
        "opencode": ["opencode"],
    ]

    /// Other places a Mac app for the same assistant is found, besides the one in `known`.
    static let extraApps: [String: [String]] = [
        "antigravity": ["/Applications/Antigravity IDE.app"],
        "codex": ["/Applications/Codex.app"],
    ]

    /// Folder names, inside an assistant's config directory, that hold its slash commands. Whichever
    /// exists wins; an id not listed uses `commands` then `prompts`.
    static let commandFolders: [String: [String]] = [
        "opencode": ["commands", "command"],
    ]

    /// The assistants that read subagents from a folder of markdown files, and what that folder is
    /// called. Deliberately short: each entry is an assistant whose own documentation says it loads
    /// agents this way. Codex defines its agents in TOML and Antigravity has no such folder, so
    /// neither is here.
    static let agentFolders: [String: [String]] = [
        "claude": ["agents"],
        "cursor": ["agents"],
        "gemini": ["agents"],
        "factory": ["droids"],
        "opencode": ["agents", "agent"],
    ]

    /// `~/.agents/skills` is the shared store the assistants link into, not an assistant.
    static let sharedDirectoryName = ".agents"

    /// Whether the assistant is actually on this machine: its Mac app is in `/Applications` (or
    /// `~/Applications`), or its command-line tool can be found. Neither is proof that it works,
    /// but both are proof that somebody installed it — which a leftover dot-directory is not.
    static func isInstalled(
        id: String, appPath: String?, paths: Paths, locate: (String) -> URL?
    ) -> Bool {
        let fm = FileManager.default
        if appPath != nil { return true }
        for app in extraApps[id] ?? [] where fm.fileExists(atPath: app) { return true }
        if let name = known[id]?.app?.split(separator: "/").last {
            let personal = paths.home.appendingPathComponent("Applications/\(name)").path
            if fm.fileExists(atPath: personal) { return true }
        }
        if id == "codex", paths.codexExecutable != nil { return true }
        return (binaries[id] ?? [id]).contains { locate($0) != nil }
    }

    /// Every `~/.<name>/skills` directory on the machine, each marked with whether the assistant
    /// behind it is installed. `locate` finds a command-line tool by name; it is injected so the
    /// tests can say what is "installed" without depending on the machine they run on.
    public static func discover(
        paths: Paths, locate: (String) -> URL? = AssistantCLIRegistry.defaultLocate
    ) -> [Assistant] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.home, includingPropertiesForKeys: nil, options: []
        ) else { return [] }

        func app(_ descriptor: (label: String, app: String?)?) -> String? {
            descriptor?.app.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
        }

        var found: [Assistant] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("."), name != sharedDirectoryName else { continue }
            let id = String(name.dropFirst())
            guard !id.isEmpty, !id.contains(".") else { continue }

            // Anything holding skills counts. A known assistant with no skills folder still
            // counts, listed apart as "no skills yet" — that is precisely the one you might
            // want to hand the first skill to. Unknown dot-directories without skills stay
            // out, so ~/.ssh never poses as an assistant.
            let root = id == "codex" ? paths.codexSkills : entry.appendingPathComponent("skills")
            var isDirectory: ObjCBool = false
            let hasFolder = fm.fileExists(atPath: root.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            let descriptor = known[id]
            guard hasFolder || descriptor != nil else { continue }

            let appPath = app(descriptor)
            found.append(Assistant(
                id: id,
                label: descriptor?.label ?? id.capitalized,
                skillsRoot: root,
                appPath: appPath,
                hasSkillsFolder: hasFolder,
                isInstalled: isInstalled(id: id, appPath: appPath, paths: paths, locate: locate),
                configHome: id == "opencode" ? paths.opencodeConfig.deletingLastPathComponent() : nil
            ))
        }

        if !found.contains(where: { $0.id == "codex" }), fm.fileExists(atPath: paths.codexHome.path) {
            found.append(Assistant(
                id: "codex", label: "Codex", skillsRoot: paths.codexSkills,
                appPath: app(known["codex"]),
                hasSkillsFolder: fm.fileExists(atPath: paths.codexSkills.path),
                isInstalled: isInstalled(id: "codex", appPath: app(known["codex"]), paths: paths, locate: locate)
            ))
        }

        // opencode keeps its configuration in `~/.config/opencode`, so the walk above only meets
        // it when something also made a `~/.opencode` — its installer does, but a package-manager
        // install does not, and an assistant that is not listed has no MCP column and no plugins.
        let opencodeHome = paths.opencodeConfig.deletingLastPathComponent()
        if !found.contains(where: { $0.id == "opencode" }), fm.fileExists(atPath: opencodeHome.path) {
            let descriptor = known["opencode"]!
            let root = paths.skillsRoot(forAssistant: "opencode")
            found.append(Assistant(
                id: "opencode", label: descriptor.label, skillsRoot: root, appPath: app(descriptor),
                hasSkillsFolder: fm.fileExists(atPath: root.path),
                isInstalled: isInstalled(id: "opencode", appPath: app(descriptor), paths: paths, locate: locate),
                configHome: opencodeHome
            ))
        }

        // Antigravity CLI (`agy`) keeps everything under `~/.gemini`, so the walk above may never
        // meet it: the Gemini CLI's own `~/.gemini/skills` is Gemini's, and agy reads
        // `~/.gemini/config/skills` instead. A stray `~/.antigravity` folder *does* get found by
        // the walk though, which would put the assistant in twice — two rows, and a duplicate
        // column in the MCP matrix. The agy entry is the real one, so where the CLI has ever run
        // on this machine it replaces whatever the walk found under that id.
        if fm.fileExists(atPath: paths.antigravityHome.path) {
            let descriptor = known["antigravity"]!
            found.removeAll { $0.id == "antigravity" }
            found.append(Assistant(
                id: "antigravity", label: descriptor.label, skillsRoot: paths.antigravitySkills,
                appPath: app(descriptor),
                hasSkillsFolder: fm.fileExists(atPath: paths.antigravitySkills.path),
                isInstalled: isInstalled(id: "antigravity", appPath: app(descriptor), paths: paths, locate: locate)
            ))
        }

        // The two he actually works in lead, then the rest alphabetically, and the ones
        // with no skills folder last — they are the tail of the list, not the headline.
        let leaders = ["claude", "codex"]
        return found.sorted { a, b in
            if a.hasSkillsFolder != b.hasSkillsFolder { return a.hasSkillsFolder }
            switch (leaders.firstIndex(of: a.id), leaders.firstIndex(of: b.id)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            }
        }
    }
}
