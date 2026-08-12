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
        case .command: return "Comando"
        case .agent: return "Agente"
        case .mcp: return "MCP"
        case .plugin: return "Plugin"
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
        case .personal: return "pessoal"
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
        usage: Usage = .none
    ) {
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

    public var errorDescription: String? {
        switch self {
        case .notEditable(let what):
            return "\(what) vem de um plugin e é só de leitura. O interruptor é o do plugin."
        case .alreadyExists(let url):
            return "Já existe algo em \(url.path). Nada foi alterado."
        case .invalidName(let name):
            return "O nome \"\(name)\" não serve: usa minúsculas, números e hífenes, como imark-review."
        case .missingField(let field):
            return "Falta o campo \(field) no frontmatter."
        case .backupFailed(let reason):
            return "Não foi possível fazer a cópia de segurança, por isso não escrevi nada. \(reason)"
        case .claudeNotFound:
            return "Não encontrei o comando claude no PATH. Instala o Claude Code ou ajusta o PATH."
        case .notFound(let what):
            return "Não encontrei \(what)."
        case .io(let reason):
            return reason
        }
    }
}
