import Foundation

/// One command to run, kept as data so what the app is about to do can be shown and tested before
/// anything runs. Always an executable and an argument list — never a string handed to a shell.
public struct PluginCommand: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// What it reads as in a log: `claude plugin install vercel@official`.
    public var display: String {
        ([executable.lastPathComponent] + arguments).joined(separator: " ")
    }
}

/// A plugin that could be installed, as a marketplace lists it.
public struct PluginCatalogEntry: Identifiable, Equatable, Sendable {
    public var assistant: String
    /// What the install takes: `name@marketplace` for Claude Code, the plugin's name for Codex.
    public var id: String { assistant + ":" + spec }
    public var spec: String
    public var name: String
    public var summary: String
    public var marketplace: String
    public var installCount: Int?
    public var installed: Bool
    /// Codex installs from a marketplace *location* rather than a name; carried here so the entry
    /// can be installed without asking the provider for the list again.
    public var marketplacePath: String?

    public init(
        assistant: String, spec: String, name: String, summary: String = "", marketplace: String = "",
        installCount: Int? = nil, installed: Bool = false, marketplacePath: String? = nil
    ) {
        self.assistant = assistant
        self.spec = spec
        self.name = name
        self.summary = summary
        self.marketplace = marketplace
        self.installCount = installCount
        self.installed = installed
        self.marketplacePath = marketplacePath
    }
}

/// What a plugin command said, for the activity line and for the person who needs the detail.
public struct PluginOutcome: Equatable, Sendable {
    public var summary: String
    public var output: String

    public init(summary: String, output: String = "") {
        self.summary = summary
        self.output = output
    }
}

/// Installing, updating and removing plugins, through each assistant's own machinery.
///
/// Loadout does not reimplement a package manager. Claude Code and opencode each ship a CLI that
/// knows how to fetch a plugin, verify it and keep its own register straight, and Codex does the
/// same behind its local protocol — so this asks them to do it, after taking a snapshot of the
/// files they are about to change, and reports what they said. The one exception is removing a
/// Claude Code plugin, which `Mutations.removePlugin` already does with a confirmation of its own.
public struct PluginService: Sendable {
    /// The assistants whose plugins can be managed from here.
    public static let managedAssistants = ["claude", "codex", "opencode"]

    public let paths: Paths
    private let locate: @Sendable (String) -> URL?

    public init(
        paths: Paths, locate: @escaping @Sendable (String) -> URL? = AssistantCLIRegistry.defaultLocate
    ) {
        self.paths = paths
        self.locate = locate
    }

    // MARK: - What can be done

    /// The program that manages an assistant's plugins, or nil when it is not on this machine.
    public func executable(for assistant: String) -> URL? {
        switch assistant {
        case "claude": return locate("claude")
        case "opencode": return locate("opencode")
        case "codex": return paths.codexExecutable
        default: return nil
        }
    }

    public func canManage(_ assistant: String) -> Bool { executable(for: assistant) != nil }

    // MARK: - Commands, built and checked without running anything

    /// Names a plugin the way `claude plugin install` wants it: `name` or `name@marketplace`.
    /// Anything else is refused here, so no typed text can turn into a flag.
    static func validClaudeSpec(_ spec: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")
        let parts = spec.split(separator: "@", omittingEmptySubsequences: false)
        return !spec.isEmpty && parts.count <= 2 && parts.allSatisfy { !$0.isEmpty }
            && !spec.hasPrefix("-")
            && spec.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// An npm name, a version-pinned one, or a git URL — anything opencode's `plugin add` takes —
    /// as long as it is one word that cannot be read as an option.
    static func validPackageSpec(_ spec: String) -> Bool {
        !spec.isEmpty && !spec.hasPrefix("-")
            && spec.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    public func installCommand(spec rawSpec: String, assistant: String) throws -> PluginCommand {
        let spec = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executable = executable(for: assistant) else { throw Self.missing(assistant) }
        switch assistant {
        case "claude":
            guard Self.validClaudeSpec(spec) else {
                throw LoadoutError.io("\"\(spec)\" isn't a plugin name. Use name or name@marketplace, like vercel@claude-plugins-official.")
            }
            return PluginCommand(executable: executable, arguments: ["plugin", "install", spec])
        case "opencode":
            guard Self.validPackageSpec(spec) else {
                throw LoadoutError.io("\"\(spec)\" isn't a package. Use an npm name like opencode-wakatime, or a git URL.")
            }
            return PluginCommand(executable: executable, arguments: ["plugin", "add", spec])
        default:
            throw LoadoutError.io("\(Self.label(assistant)) installs plugins through its own app.")
        }
    }

    public func updateCommand(for plugin: PluginInfo) throws -> PluginCommand {
        guard let executable = executable(for: plugin.assistant) else { throw Self.missing(plugin.assistant) }
        switch plugin.assistant {
        case "claude":
            return PluginCommand(executable: executable, arguments: ["plugin", "update", plugin.id])
        case "opencode":
            guard plugin.nativeKey.hasPrefix("local:") == false else {
                throw LoadoutError.io("\(plugin.name) is a file on this machine, not a package, so there is nothing to update.")
            }
            guard Self.validPackageSpec(plugin.nativeKey) else {
                throw LoadoutError.io("opencode's entry for \(plugin.name) can't be read as a package.")
            }
            return PluginCommand(executable: executable, arguments: ["plugin", "update", plugin.nativeKey])
        default:
            throw LoadoutError.io("\(Self.label(plugin.assistant)) updates plugins through its own app.")
        }
    }

    public func removeCommand(for plugin: PluginInfo) throws -> PluginCommand {
        guard plugin.assistant == "opencode", let executable = executable(for: "opencode") else {
            throw Self.missing(plugin.assistant)
        }
        guard Self.validPackageSpec(plugin.nativeKey) else {
            throw LoadoutError.io("opencode's entry for \(plugin.name) can't be read as a package.")
        }
        return PluginCommand(executable: executable, arguments: ["plugin", "remove", plugin.nativeKey])
    }

    public func marketplaceCommand(source rawSource: String) throws -> PluginCommand {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executable = executable(for: "claude") else { throw Self.missing("claude") }
        guard Self.validPackageSpec(source) else {
            throw LoadoutError.io("\"\(source)\" isn't a marketplace. Use owner/repo, a git URL or a folder.")
        }
        return PluginCommand(executable: executable, arguments: ["plugin", "marketplace", "add", source])
    }

    // MARK: - Running them

    /// Runs a command to completion. Blocking — call it off the main thread.
    ///
    /// The files it is about to change are copied into Loadout's backups first, and if that copy
    /// fails nothing runs, the same rule every other write in the app follows.
    public func run(_ command: PluginCommand, assistant: String, timeout: TimeInterval = 240) throws -> PluginOutcome {
        for file in filesTouched(by: assistant) { try Backups(paths: paths).snapshot(file) }
        let cli = AssistantCLI(
            id: assistant, label: Self.label(assistant), executable: command.executable,
            argumentTemplate: "", isCustom: false
        )
        let result = try CommandRunner.run(
            executable: command.executable, arguments: command.arguments,
            environment: cli.environment(base: ProcessInfo.processInfo.environment, home: paths.home),
            directory: paths.home, timeout: timeout
        )
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut {
            throw LoadoutError.io("\(command.display) took longer than \(Int(timeout)) seconds and was stopped.")
        }
        guard result.exitCode == 0 else {
            let detail = output.isEmpty ? "It exited with status \(result.exitCode)." : Self.lastLines(of: output)
            throw LoadoutError.io("\(Self.label(assistant)) couldn't finish: \(detail)")
        }
        return PluginOutcome(summary: Self.lastLines(of: output, count: 1), output: output)
    }

    public func install(spec: String, assistant: String) throws -> PluginOutcome {
        try run(try installCommand(spec: spec, assistant: assistant), assistant: assistant)
    }

    /// Installs something a catalogue listed, each assistant in its own way.
    public func install(_ entry: PluginCatalogEntry) throws -> PluginOutcome {
        if entry.assistant == "codex" { return try CodexPlugins(paths: paths).install(entry) }
        return try install(spec: entry.spec, assistant: entry.assistant)
    }

    /// Takes a Codex or opencode plugin out. Claude Code's goes through `Mutations.removePlugin`,
    /// which asks first and moves the folder to the Trash itself.
    public func uninstall(_ plugin: PluginInfo) throws -> PluginOutcome {
        switch plugin.assistant {
        case "codex": return try CodexPlugins(paths: paths).uninstall(plugin)
        case "opencode": return try removeOpenCode(plugin)
        default: throw LoadoutError.io("Remove \(plugin.name) from the plugin's own page.")
        }
    }

    public func update(_ plugin: PluginInfo) throws -> PluginOutcome {
        if plugin.assistant == "codex" { return try CodexPlugins(paths: paths).update(plugin) }
        return try run(try updateCommand(for: plugin), assistant: plugin.assistant)
    }

    /// Removes a plugin opencode loaded: a package through its CLI, a file of yours to the Trash.
    public func removeOpenCode(_ plugin: PluginInfo) throws -> PluginOutcome {
        if plugin.nativeKey.hasPrefix("local:") {
            let target = plugin.installPath.standardizedFileURL
            let home = OpenCodePlugins(paths: paths).home.standardizedFileURL.path
            guard target.path.hasPrefix(home + "/") else {
                throw LoadoutError.io("\(plugin.name) is recorded outside opencode's folder, so it was left alone.")
            }
            try Backups(paths: paths).snapshot(target)
            do { try FileManager.default.trashItem(at: target, resultingItemURL: nil) }
            catch { throw LoadoutError.io("Couldn't move \(plugin.name) to the Trash: \(error.localizedDescription)") }
            return PluginOutcome(summary: "Moved \(plugin.name) to the Trash.")
        }
        return try run(try removeCommand(for: plugin), assistant: "opencode")
    }

    public func addMarketplace(source: String) throws -> PluginOutcome {
        try run(try marketplaceCommand(source: source), assistant: "claude")
    }

    /// What the assistants' own tools may change when asked to manage plugins.
    func filesTouched(by assistant: String) -> [URL] {
        switch assistant {
        case "claude": return [paths.installedPlugins, paths.settings, paths.localSettings]
        case "opencode": return [paths.opencodeConfig]
        case "codex": return [paths.codexConfig]
        default: return []
        }
    }

    // MARK: - What can be installed

    /// The plugins the assistant's marketplaces offer. opencode has no catalogue — it installs
    /// whatever package you name — so it answers with nothing.
    public func catalog(for assistant: String) throws -> [PluginCatalogEntry] {
        switch assistant {
        case "claude":
            guard let executable = executable(for: "claude") else { throw Self.missing("claude") }
            let command = PluginCommand(executable: executable, arguments: ["plugin", "list", "--available", "--json"])
            let outcome = try run(command, assistant: "claude", timeout: 60)
            return try Self.parseClaudeCatalog(outcome.output)
        case "codex":
            return try CodexPlugins(paths: paths).catalog()
        default:
            return []
        }
    }

    /// `claude plugin list --available --json`: `installed` and `available`, each a list.
    static func parseClaudeCatalog(_ text: String) throws -> [PluginCatalogEntry] {
        guard let start = text.firstIndex(of: "{"),
              let data = String(text[start...]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LoadoutError.io("Claude Code's plugin list wasn't readable. Update Claude Code and try again.") }
        let installed = Set((root["installed"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        return (root["available"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let spec = entry["pluginId"] as? String, let name = entry["name"] as? String else { return nil }
            return PluginCatalogEntry(
                assistant: "claude", spec: spec, name: name,
                summary: entry["description"] as? String ?? "",
                marketplace: entry["marketplaceName"] as? String ?? "",
                installCount: entry["installCount"] as? Int,
                installed: installed.contains(spec)
            )
        }
        .sorted {
            let (a, b) = ($0.installCount ?? 0, $1.installCount ?? 0)
            return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Words

    static func label(_ assistant: String) -> String {
        switch assistant {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "opencode"
        default: return assistant.capitalized
        }
    }

    static func missing(_ assistant: String) -> LoadoutError {
        .io("\(label(assistant)) isn't installed here, so its plugins can't be managed.")
    }

    /// The tail of a command's output — the part that says how it ended.
    static func lastLines(of text: String, count: Int = 4) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
    }
}

/// Runs one program with a timeout and collects what it prints.
enum CommandRunner {
    struct Result {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
    }

    static func run(
        executable: URL, arguments: [String], environment: [String: String], directory: URL,
        timeout: TimeInterval
    ) throws -> Result {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.environment = environment
        task.currentDirectoryURL = directory
        // Closed rather than inherited: a tool that wants an answer must fail, not wait for one
        // nobody can give it.
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() }
        catch { throw LoadoutError.io("Couldn't run \(executable.lastPathComponent): \(error.localizedDescription)") }

        let sink = Sink()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "loadout.plugins.read").async {
            sink.set(pipe.fileHandleForReading.readDataToEndOfFile())
            finished.signal()
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            task.terminate()
            _ = finished.wait(timeout: .now() + 5)
        }
        task.waitUntilExit()
        return Result(output: String(data: sink.get(), encoding: .utf8) ?? "", exitCode: task.terminationStatus, timedOut: timedOut)
    }

    private final class Sink: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
