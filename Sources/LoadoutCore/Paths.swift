import Foundation

/// Every path the app touches, derived from injected roots.
///
/// Nothing here is hardcoded to a user: `Paths.live()` reads the real home directory,
/// and tests build one against a temporary tree. That single indirection is what keeps
/// the test suite off the user's real `~/.claude` (AC9.2) and the code free of
/// hardcoded user paths (AC9.5).
public struct Paths: Sendable {
    public let home: URL
    public let claude: URL
    public let projectsRoot: URL
    /// Everything Loadout itself owns — its backups, its usage index, the icons the owner
    /// drops in for the assistants that ship no Mac app.
    ///
    /// Deliberately not inside `~/.claude`: that directory belongs to Claude, and an app that
    /// keeps its own database in someone else's folder is a surprise waiting to happen — for
    /// whoever wipes `.claude` to fix something, above all. Derived from `home` rather than
    /// asked of the system, so a fixture home in a test keeps its own copy of all of it.
    public let support: URL

    public init(home: URL, claude: URL? = nil, projectsRoot: URL? = nil, support: URL? = nil) {
        self.home = home
        self.claude = claude ?? home.appendingPathComponent(".claude")
        self.projectsRoot = projectsRoot ?? home.appendingPathComponent("Projects")
        self.support = support
            ?? home
                .appendingPathComponent("Library/Application Support")
                .appendingPathComponent("Loadout")
    }

    public static func live() -> Paths {
        Paths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: Skills

    public var skills: URL { claude.appendingPathComponent("skills") }
    public var skillsOff: URL { claude.appendingPathComponent("skills-off") }

    /// Codex keeps its own skills next to its own config.
    public var codexSkills: URL { home.appendingPathComponent(".codex/skills") }

    /// The tree both assistants can point at, so a shared skill has one copy and one edit.
    public var sharedSkills: URL { home.appendingPathComponent(".agents/skills") }

    public func skillsRoot(forAssistant id: String) -> URL {
        home.appendingPathComponent(".\(id)/skills")
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
    public var projectsIndex: URL { projectsRoot.appendingPathComponent("INDEX.md") }

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
}
