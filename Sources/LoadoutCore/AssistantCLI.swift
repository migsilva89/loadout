import Foundation

/// A command-line assistant the "Ask" sheet can run — `claude`, `codex`, whatever the user
/// points it at. Four are built in; anything else the owner adds by hand in Settings lives
/// alongside them on equal footing.
public struct AssistantCLI: Identifiable, Hashable, Sendable {
    /// The placeholder in `argumentTemplate` that becomes the prompt — always one whole
    /// argument, never spliced into another string, so a prompt containing quotes or a
    /// semicolon can never be read as more than one argv entry.
    public static let promptPlaceholder = "{prompt}"

    public let id: String
    public let label: String
    public let executable: URL
    /// Whitespace-separated argv template, e.g. `"-p {prompt}"` or `"exec {prompt}"`.
    public let argumentTemplate: String
    /// True for an entry the owner typed into Settings; false for one of the four built-ins.
    /// Built-ins are read-only there — only custom entries can be edited or removed.
    public let isCustom: Bool

    public init(id: String, label: String, executable: URL, argumentTemplate: String, isCustom: Bool) {
        self.id = id
        self.label = label
        self.executable = executable
        self.argumentTemplate = argumentTemplate
        self.isCustom = isCustom
    }

    /// Builds argv for a run: the template's tokens, with the placeholder token replaced by
    /// the whole prompt as a single argument. This never touches a shell, so nothing in the
    /// prompt is ever re-parsed.
    public func arguments(for prompt: String) -> [String] {
        argumentTemplate
            .split(whereSeparator: \.isWhitespace)
            .map { $0 == Self.promptPlaceholder ? prompt : String($0) }
    }

    /// What the sheet says it runs, e.g. "codex exec" — the placeholder spelled out, not the
    /// literal prompt.
    public var invocationDescription: String {
        let flags = argumentTemplate.replacingOccurrences(of: Self.promptPlaceholder, with: "<prompt>")
        return "\(executable.lastPathComponent) \(flags)"
    }
}

/// A CLI the owner typed into Settings › Assistants, persisted as JSON in `UserDefaults`.
public struct CustomAssistantCLI: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var executablePath: String
    public var argumentTemplate: String

    public init(id: String, label: String, executablePath: String, argumentTemplate: String) {
        self.id = id
        self.label = label
        self.executablePath = executablePath
        self.argumentTemplate = argumentTemplate
    }
}

/// Loads and saves the custom entries as one JSON blob under one key — there is no reason for
/// a dozen `UserDefaults` keys when the whole list is small and always read or written together.
public enum CustomAssistantCLIStore {
    public static let key = "customAssistantCLIs"

    public static func load(defaults: UserDefaults = .standard) -> [CustomAssistantCLI] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CustomAssistantCLI].self, from: data)) ?? []
    }

    public static func save(_ entries: [CustomAssistantCLI], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Checks a name/path/template before it becomes a `CustomAssistantCLI`, so a bad entry never
/// makes it into `UserDefaults` in the first place.
public enum AssistantCLIValidation {
    public static func validate(name: String, path: String, template: String) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LoadoutError.invalidAssistantCLI("Give the assistant a name.")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw LoadoutError.invalidAssistantCLI("Couldn't find an executable file at \(path).")
        }
        let placeholders = template.split(whereSeparator: \.isWhitespace)
            .filter { $0 == AssistantCLI.promptPlaceholder }
        guard placeholders.count == 1 else {
            let reason = placeholders.isEmpty
                ? "The arguments must include \(AssistantCLI.promptPlaceholder) where the question goes."
                : "The arguments can only use \(AssistantCLI.promptPlaceholder) once."
            throw LoadoutError.invalidAssistantCLI(reason)
        }
    }
}

/// Finds every assistant CLI on this machine: the four built-ins, wherever they actually sit
/// on `PATH` or in the usual install locations, plus whatever the owner added by hand.
public enum AssistantCLIRegistry {
    private struct Builtin {
        let id: String
        let binaryName: String
        let label: String
        let argumentTemplate: String
    }

    /// Verified non-interactive syntax for each, as of the CLIs on this machine today.
    private static let builtins: [Builtin] = [
        Builtin(id: "claude", binaryName: "claude", label: "Claude Code", argumentTemplate: "-p {prompt}"),
        Builtin(id: "codex", binaryName: "codex", label: "Codex", argumentTemplate: "exec {prompt}"),
        Builtin(
            id: "cursor-agent", binaryName: "cursor-agent", label: "Cursor",
            argumentTemplate: "-p --output-format text {prompt}"
        ),
        Builtin(id: "opencode", binaryName: "opencode", label: "opencode", argumentTemplate: "run {prompt}"),
    ]

    /// Every built-in binary name, for the "none installed" tooltip.
    public static var builtinLabels: [String] { builtins.map(\.label) }

    /// Every CLI actually available: built-ins only when found, in their fixed order, then
    /// custom entries. A custom entry sharing a built-in's id replaces it outright, at that
    /// built-in's position, rather than appearing twice.
    public static func discover(
        customEntries: [CustomAssistantCLI],
        locate: (String) -> URL? = defaultLocate
    ) -> [AssistantCLI] {
        var byID: [String: AssistantCLI] = [:]
        var order: [String] = []

        for builtin in builtins {
            guard let url = locate(builtin.binaryName) else { continue }
            byID[builtin.id] = AssistantCLI(
                id: builtin.id, label: builtin.label, executable: url,
                argumentTemplate: builtin.argumentTemplate, isCustom: false
            )
            order.append(builtin.id)
        }

        for custom in customEntries {
            guard FileManager.default.isExecutableFile(atPath: custom.executablePath) else { continue }
            if byID[custom.id] == nil { order.append(custom.id) }
            byID[custom.id] = AssistantCLI(
                id: custom.id, label: custom.label,
                executable: URL(fileURLWithPath: custom.executablePath),
                argumentTemplate: custom.argumentTemplate, isCustom: true
            )
        }

        return order.compactMap { byID[$0] }
    }

    /// Walks `PATH` the way a login shell would, then the usual install locations — the same
    /// search `Copilot.findClaude` used to do alone, now shared by all four built-ins.
    public static func defaultLocate(_ name: String) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        if name == "claude" {
            candidates.append("\(home)/.claude/local/claude")
        }
        candidates += [
            "\(home)/.local/bin/\(name)",
            "\(home)/.opencode/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        if let nvmDirs = try? fm.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            candidates += nvmDirs.map { "\(home)/.nvm/versions/node/\($0)/bin/\(name)" }
        }
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}
