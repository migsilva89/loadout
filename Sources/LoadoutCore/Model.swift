import Foundation

/// What kind of thing an inventory entry is.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case skill
    case command
    case agent
    case mcp
    case plugin

    public var label: String {
        switch self {
        case .skill: return "Skill"
        case .command: return "Command"
        case .agent: return "Agent"
        case .mcp: return "MCP"
        case .plugin: return "Plugin"
        }
    }

    /// How the thing is named to an assistant being told what it is looking at — lowercase, and
    /// spelled out where the short label would mean nothing out of context.
    public var briefingNoun: String {
        switch self {
        case .skill: return "skill"
        case .command: return "slash command"
        case .agent: return "subagent"
        case .mcp: return "MCP server"
        case .plugin: return "plugin"
        }
    }
}

/// Where the entry comes from. This is a property of the file on disk, never a view state.
public enum Origin: Equatable, Hashable, Codable, Sendable {
    /// `~/.claude/…` — active in every project.
    case personal
    /// `<repo>/.claude/…` — active only inside that repo.
    case project(String)
    /// Shipped by an installed plugin. Read-only for us.
    case plugin(String)

    public var label: String {
        switch self {
        case .personal: return "personal"
        case .project(let name): return name
        case .plugin(let name): return name
        }
    }

    public var isEditable: Bool {
        switch self {
        case .personal, .project: return true
        case .plugin: return false
        }
    }
}

/// One row in the inventory.
public struct Item: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: ItemKind
    public var origin: Origin
    public var description: String
    /// The file that defines it (`SKILL.md`, the command's `.md`, …). Nil for MCP servers,
    /// which live inside a JSON blob rather than in a file of their own.
    public var path: URL?
    /// The directory that holds it, when it owns one. This is what we move to disable.
    public var directory: URL?
    public var modified: Date?
    public var enabled: Bool
    /// Set when the frontmatter could not be read, so the UI can say so instead of lying.
    public var warning: String?
    public var usage: Usage
    /// Ids of the assistants that load this skill. Empty for anything that is not a
    /// personal skill.
    public var assistants: Set<String>
    /// What it costs to keep installed, and whether it breaks a documented limit. Only
    /// meaningful for items that own a markdown document.
    public var budget: Budget
    /// `"vercel@claude-plugins-official"` for anything a plugin ships, so a row can act on the
    /// plugin it came from without going looking for it. Nil for everything else.
    public var pluginID: String?
    /// The project directory an MCP server is declared under, exactly as `~/.claude.json` keys it.
    ///
    /// The row shows the folder's name, and two checkouts can share one — `~/work/app` and
    /// `~/personal/app` — so acting on the name alone would switch off a server belonging to the
    /// other one. Nil for a global server.
    public var projectDirectory: String?

    public init(
        id: String,
        name: String,
        kind: ItemKind,
        origin: Origin,
        description: String = "",
        path: URL? = nil,
        directory: URL? = nil,
        modified: Date? = nil,
        enabled: Bool = true,
        warning: String? = nil,
        usage: Usage = .none,
        assistants: Set<String> = [],
        budget: Budget = Budget(),
        pluginID: String? = nil,
        projectDirectory: String? = nil
    ) {
        self.assistants = assistants
        self.budget = budget
        self.pluginID = pluginID
        self.projectDirectory = projectDirectory
        self.id = id
        self.name = name
        self.kind = kind
        self.origin = origin
        self.description = description
        self.path = path
        self.directory = directory
        self.modified = modified
        self.enabled = enabled
        self.warning = warning
        self.usage = usage
    }

    /// Plugin-owned files are never ours to rewrite.
    public var isEditable: Bool { origin.isEditable && kind != .mcp && kind != .plugin }
}

/// How much an item has actually been used, mined from session transcripts.
public struct Usage: Equatable, Sendable, Codable {
    public var count: Int
    public var lastUsed: Date?
    public var projectCount: Int

    public static let none = Usage(count: 0, lastUsed: nil, projectCount: 0)

    public init(count: Int, lastUsed: Date?, projectCount: Int) {
        self.count = count
        self.lastUsed = lastUsed
        self.projectCount = projectCount
    }

    public var neverUsed: Bool { count == 0 }
}

/// One project an item was actually used in, and how often. The named half of `Usage`.
public struct ProjectUsage: Identifiable, Equatable, Hashable, Sendable {
    public var project: String
    public var count: Int

    public var id: String { project }

    public init(project: String, count: Int) {
        self.project = project
        self.count = count
    }
}

/// A repo the user works in, read from `~/Projects/INDEX.md`.
public struct Project: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path.path }
    public var name: String
    public var relativePath: String
    public var path: URL

    public init(name: String, relativePath: String, path: URL) {
        self.name = name
        self.relativePath = relativePath
        self.path = path
    }
}

/// An installed plugin, with the toggle state we can actually change.
public struct PluginInfo: Identifiable, Equatable, Sendable {
    /// `"vercel@claude-plugins-official"` — the key `enabledPlugins` uses.
    public var id: String
    public var name: String
    public var marketplace: String
    public var version: String
    public var installPath: URL
    public var enabled: Bool

    public init(id: String, name: String, marketplace: String, version: String, installPath: URL, enabled: Bool) {
        self.id = id
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.installPath = installPath
        self.enabled = enabled
    }
}

/// Errors surfaced to the user verbatim, so a failure always says what happened and what to do.
public enum LoadoutError: LocalizedError, Equatable {
    case notEditable(String)
    case alreadyExists(URL)
    case invalidName(String)
    case missingField(String)
    case backupFailed(String)
    case claudeNotFound
    case notFound(String)
    case io(String)
    case invalidAssistantCLI(String)

    public var errorDescription: String? {
        switch self {
        case .notEditable(let what):
            return "\(what) comes from a plugin and is read-only. Use the plugin switch instead."
        case .alreadyExists(let url):
            return "Something already exists at \(url.path). Nothing was changed."
        case .invalidName(let name):
            return "The name \"\(name)\" isn't valid. Use lowercase letters, numbers, and hyphens, like imark-review."
        case .missingField(let field):
            return "The frontmatter is missing the \(field) field."
        case .backupFailed(let reason):
            return "Couldn't make a backup, so nothing was written. \(reason)"
        case .claudeNotFound:
            return "Couldn't find an assistant CLI to run. Install Claude Code, Codex, Cursor, or opencode."
        case .notFound(let what):
            return "Couldn't find \(what)."
        case .io(let reason):
            return reason
        case .invalidAssistantCLI(let reason):
            return reason
        }
    }
}
