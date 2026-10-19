import Foundation

/// Every path the app touches, derived from injected roots.
///
/// Nothing here is hardcoded to a user: `Paths.live()` reads the real home directory,
/// and tests build one against a temporary tree. That single indirection is what keeps
/// the test suite off the user's real `~/.claude` (AC9.2) and the code free of
/// hardcoded user paths (AC9.5).
public struct Paths: Sendable {
    public let codexExecutable: URL?
    public let codexHome: URL
    public let home: URL
    public let claude: URL
    public let projectsRoot: URL
    /// Where `Paths.live()` found opencode's config, when the environment said so. Nil means
    /// the `~/.config` default derived from `home`.
    private let opencodeConfigOverride: URL?
    /// Everything Loadout itself owns — its backups, its usage index, the icons the owner
    /// drops in for the assistants that ship no Mac app.
    ///
    /// Deliberately not inside `~/.claude`: that directory belongs to Claude, and an app that
    /// keeps its own database in someone else's folder is a surprise waiting to happen — for
    /// whoever wipes `.claude` to fix something, above all. Derived from `home` rather than
    /// asked of the system, so a fixture home in a test keeps its own copy of all of it.
    public let support: URL

    public init(home: URL, claude: URL? = nil, projectsRoot: URL? = nil, support: URL? = nil,
                codexExecutable: URL? = nil, codexHome: URL? = nil, opencodeConfig: URL? = nil) {
        self.codexExecutable = codexExecutable
        self.codexHome = codexHome ?? home.appendingPathComponent(".codex")
        self.home = home
        self.claude = claude ?? home.appendingPathComponent(".claude")
        self.projectsRoot = projectsRoot ?? home.appendingPathComponent("Projects")
        self.opencodeConfigOverride = opencodeConfig
        self.support = support
            ?? home
                .appendingPathComponent("Library/Application Support")
                .appendingPathComponent("Loadout")
    }

    public static func live() -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // opencode reads its global config from `XDG_CONFIG_HOME` when that is set, so the real
        // location is decided here — the only place the environment is allowed to matter.
        let opencode = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { xdg -> URL? in
            guard xdg.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode/opencode.json")
        }
        return Paths(home: home,
              codexExecutable: AssistantCLIRegistry.defaultLocate("codex"),
              codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) },
              opencodeConfig: opencode)
    }

    public var codexConfig: URL { codexHome.appendingPathComponent("config.toml") }
    public var codexPluginCache: URL { codexHome.appendingPathComponent("plugins/cache") }

    // MARK: Skills

    public var skills: URL { claude.appendingPathComponent("skills") }
    public var skillsOff: URL { claude.appendingPathComponent("skills-off") }

    /// Codex keeps its own skills next to its own config.
    public var codexSkills: URL { codexHome.appendingPathComponent("skills") }

    /// The tree both assistants can point at, so a shared skill has one copy and one edit.
    public var sharedSkills: URL { home.appendingPathComponent(".agents/skills") }

    public func skillsRoot(forAssistant id: String) -> URL {
        switch id {
        case "codex": return codexSkills
        case "antigravity": return antigravitySkills
        default: return home.appendingPathComponent(".\(id)/skills")
        }
    }

    // MARK: Other assistants' MCP configs

    /// Cursor keeps its global MCP servers in a file of its own, in the same `mcpServers` shape
    /// Claude uses.
    public var cursorMCP: URL { home.appendingPathComponent(".cursor/mcp.json") }
    /// The Gemini CLI's settings file, which also holds an `mcpServers` table.
    public var geminiSettings: URL { home.appendingPathComponent(".gemini/settings.json") }
    /// Windsurf's MCP config — `mcpServers` again, under Codeium's directory.
    public var windsurfMCP: URL {
        home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
    }
    /// opencode's global config. Its MCP section is called `mcp` and its entries have a shape
    /// of their own (`type`, an array `command`, `environment`), so this is a format rather than
    /// just another `mcpServers` file.
    ///
    /// Always derived from the injected `home`, so a fixture home in a test keeps its own copy.
    /// `Paths.live()` is the one that reads `XDG_CONFIG_HOME` and passes the real location in.
    public var opencodeConfig: URL {
        opencodeConfigOverride ?? home.appendingPathComponent(".config/opencode/opencode.json")
    }

    // MARK: Antigravity

    /// Antigravity CLI (`agy`) has no dot-directory of its own: it lives inside `~/.gemini`, next
    /// to the Gemini CLI. Its own state — conversations, logs, the built-in skills — sits under
    /// `antigravity-cli`, and this folder existing is what says the CLI is installed.
    public var antigravityHome: URL { home.appendingPathComponent(".gemini/antigravity-cli") }
    /// The global customization root the CLI reads: skills, plugins and `mcp_config.json`.
    /// Probed on agy 1.2.7 — of the three folders its docs mention, this is the only one it loads.
    public var antigravityConfig: URL { home.appendingPathComponent(".gemini/config") }
    public var antigravitySkills: URL { antigravityConfig.appendingPathComponent("skills") }
    /// One SQLite database per conversation, with every step as a protobuf blob.
    public var antigravityConversations: URL { antigravityHome.appendingPathComponent("conversations") }
    /// The index of those conversations: title, dates and the workspace each one ran in.
    public var antigravitySummaries: URL {
        antigravityHome.appendingPathComponent("conversation_summaries.db")
    }

    public var commands: URL { claude.appendingPathComponent("commands") }
    public var agents: URL { claude.appendingPathComponent("agents") }
    public var agentsOff: URL { claude.appendingPathComponent("agents-off") }

    // MARK: Config files

    public var settings: URL { claude.appendingPathComponent("settings.json") }
    public var localSettings: URL { claude.appendingPathComponent("settings.local.json") }
    public var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    public var installedPlugins: URL {
        claude.appendingPathComponent("plugins/installed_plugins.json")
    }
    public var pluginCache: URL { claude.appendingPathComponent("plugins/cache") }

    // MARK: Derived data

    public var transcripts: URL { claude.appendingPathComponent("projects") }
    public var backups: URL { support.appendingPathComponent("backups") }
    public var index: URL { support.appendingPathComponent("usage.sqlite") }
    /// `<id>.png` per assistant, for the ones with no Mac app to read an icon from. A folder
    /// rather than files in the bundle: they are somebody else's trademarks, so they stay out
    /// of this repository and belong to the machine they were put on.
    public var cliIcons: URL { support.appendingPathComponent("cli-icons") }
    /// One disposable copy of a skill's folder per live conversation, for the assistant to write
    /// in. Here rather than in a system temporary directory because a conversation outlives the
    /// app: resuming it tomorrow means running in the same folder it started in.
    public var askWorkspaces: URL { support.appendingPathComponent("ask-workspaces") }

    // MARK: Where those three used to live

    /// Loadout kept its own files inside `~/.claude` until they were moved out. Named here so
    /// the migration has one place to read them from, and so nothing else has to remember.
    public var legacySupport: URL { claude.appendingPathComponent(".loadout") }
    public var legacyBackups: URL { claude.appendingPathComponent(".loadout-backups") }
    public var legacyIndex: URL { legacySupport.appendingPathComponent("usage.sqlite") }
    public var legacyCLIIcons: URL { legacySupport.appendingPathComponent("cli-icons") }

    // MARK: Other assistants' histories

    /// Codex keeps sessions by date, and archives the ones it has closed. Both count.
    public var codexSessions: URL { home.appendingPathComponent(".codex/sessions") }
    public var codexArchivedSessions: URL {
        home.appendingPathComponent(".codex/archived_sessions")
    }
    /// Metadata only — one file per agent Paseo ran. Read for attribution, never counted.
    public var paseoAgents: URL { home.appendingPathComponent(".paseo/agents") }
    public var openCodeSessions: URL {
        home.appendingPathComponent(".local/share/opencode/storage/session")
    }
    public var piSessions: URL { home.appendingPathComponent(".pi/agent/sessions") }
    public var cursorProjects: URL { home.appendingPathComponent(".cursor/projects") }

    // MARK: Per-project

    public func projectSkills(_ repo: URL) -> URL { repo.appendingPathComponent(".claude/skills") }
    /// A project skill parks next door, inside the repository it belongs to: moving it out would
    /// still show up in the working tree, and next door at least reads as a deliberate state.
    public func projectSkillsOff(_ repo: URL) -> URL { repo.appendingPathComponent(".claude/skills-off") }
    public func projectCommands(_ repo: URL) -> URL { repo.appendingPathComponent(".claude/commands") }
    public func projectCommandsOff(_ repo: URL) -> URL {
        repo.appendingPathComponent(".claude/commands-off")
    }
    public func projectAgents(_ repo: URL) -> URL { repo.appendingPathComponent(".claude/agents") }
    public func projectAgentsOff(_ repo: URL) -> URL {
        repo.appendingPathComponent(".claude/agents-off")
    }
    /// A repository's own settings, committed for the whole team. Claude Code reads these after
    /// your `~/.claude` ones, so what is here wins over what you chose — including which plugins
    /// are on.
    public func projectSettings(_ repo: URL) -> URL {
        repo.appendingPathComponent(".claude/settings.json")
    }
    /// The same file for one person only, gitignored, and the last word of the two.
    public func projectLocalSettings(_ repo: URL) -> URL {
        repo.appendingPathComponent(".claude/settings.local.json")
    }
    /// The MCP servers a repository ships for everybody who checks it out. Committed, so it belongs
    /// to the team rather than to whoever is reading it — the app shows what is in here and never
    /// rewrites it.
    public func projectMCPJSON(_ repo: URL) -> URL { repo.appendingPathComponent(".mcp.json") }
}
