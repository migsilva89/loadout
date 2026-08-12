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

    public init(home: URL, claude: URL? = nil, projectsRoot: URL? = nil) {
        self.home = home
        self.claude = claude ?? home.appendingPathComponent(".claude")
        self.projectsRoot = projectsRoot ?? home.appendingPathComponent("Projects")
    }

    public static func live() -> Paths {
        Paths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: Skills

    public var skills: URL { claude.appendingPathComponent("skills") }
    public var skillsOff: URL { claude.appendingPathComponent("skills-off") }
    public var commands: URL { claude.appendingPathComponent("commands") }
    public var agents: URL { claude.appendingPathComponent("agents") }

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
    public var backups: URL { claude.appendingPathComponent(".loadout-backups") }
    public var index: URL { claude.appendingPathComponent(".loadout/usage.sqlite") }
    public var projectsIndex: URL { projectsRoot.appendingPathComponent("INDEX.md") }

    // MARK: Per-project

    public func projectSkills(_ repo: URL) -> URL { repo.appendingPathComponent(".claude/skills") }
    public func projectCommands(_ repo: URL) -> URL { repo.appendingPathComponent(".claude/commands") }
    public func projectAgents(_ repo: URL) -> URL { repo.appendingPathComponent(".claude/agents") }
}
