import Foundation

/// Every change the app makes to the disk goes through here, and every one of them
/// takes a snapshot first.
public struct Mutations: Sendable {
    public let paths: Paths
    public let backups: Backups
    public let records: OffRecords
    private var fm: FileManager { .default }

    public init(paths: Paths) {
        self.paths = paths
        self.backups = Backups(paths: paths)
        self.records = OffRecords(paths: paths)
    }

    // MARK: - Enable and disable

    /// Where the real folder of a skill lives, as opposed to the symlinks pointing at it.
    ///
    /// A skill shared between assistants has its real folder in `~/.agents/skills` and a link in
    /// each assistant; an unshared one has it in the assistant that owns it. Disabling has to know
    /// which, because parking everything under `~/.claude` silently changed a Codex skill into a
    /// Claude one — the skill vanished from Codex and nobody was told.
    public struct Owner: Equatable, Sendable {
        /// An assistant id, or `OffRecords.sharedOwner`.
        public var id: String
        /// The `skills` directory that holds the real folder.
        public var root: URL

        public init(id: String, root: URL) {
            self.id = id
            self.root = root
        }
    }

    /// Finds the owner of a personal skill: the one place holding a directory rather than a link.
    public func owner(of name: String, assistants: [Assistant]) throws -> Owner {
        let shared = paths.sharedSkills.appendingPathComponent(name)
        if fm.fileExists(atPath: shared.path), !isSymlink(shared) {
            return Owner(id: OffRecords.sharedOwner, root: paths.sharedSkills)
        }
        let real = assistants.filter { assistant in
            let candidate = assistant.skillsRoot.appendingPathComponent(name)
            return fm.fileExists(atPath: candidate.path) && !isSymlink(candidate)
        }
        guard let first = real.first else { throw LoadoutError.notFound(name) }
        guard real.count == 1 else {
            throw LoadoutError.io(
                "\(name) has its own copy in more than one assistant, and they may differ. Merge them by hand first."
            )
        }
        return Owner(id: first.id, root: first.skillsRoot)
    }

    /// The `skills-off` beside a `skills` root — same parent, so nothing changes hands.
    func offRoot(for root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent("skills-off")
    }

    /// Switches a skill off everywhere at once (AC3.1, AC3.2, AC3.3).
    ///
    /// One switch, one meaning: out of service. Taking a skill out of a single assistant while
    /// leaving it in another is the assistant dots, not this. The links go first and the real
    /// folder last, so a failure halfway never leaves a link pointing at nothing.
    @discardableResult
    public func disableSkill(_ item: Item, assistants: [Assistant] = []) throws -> URL {
        guard item.kind == .skill else {
            throw LoadoutError.notEditable("Only skills can be disabled this way: \(item.name)")
        }

        switch item.origin {
        case .plugin:
            throw LoadoutError.notEditable(item.name)
        case .project:
            // A project skill has no assistants of its own: it belongs to the repository, and
            // parks next door in the same `.claude` directory.
            guard let folder = item.directory else { throw LoadoutError.notFound(item.name) }
            return try move(folder, into: offRoot(for: folder.deletingLastPathComponent()))
        case .personal:
            break
        }

        let assistants = assistants.isEmpty ? AssistantRegistry.discover(paths: paths) : assistants
        let owner = try owner(of: item.name, assistants: assistants)
        let loadedBy = assistants
            .filter { fm.fileExists(atPath: $0.skillsRoot.appendingPathComponent(item.name).path) }
            .map(\.id)

        for assistant in assistants where assistant.skillsRoot != owner.root {
            let link = assistant.skillsRoot.appendingPathComponent(item.name)
            guard fm.fileExists(atPath: link.path), isSymlink(link) else { continue }
            try backups.snapshot(link)
            try? fm.removeItem(at: link)
        }

        let parked = try move(
            owner.root.appendingPathComponent(item.name), into: offRoot(for: owner.root)
        )
        try records.remember(OffRecords.Entry(
            name: item.name, owner: owner.id, assistants: loadedBy, disabledAt: Date()
        ))
        return parked
    }

    /// Which assistants a disabled skill should come back to, as far as anyone can tell.
    ///
    /// The off-record when there is one; otherwise just the assistant whose `skills-off` is holding
    /// it, and the caller says out loud that it could not tell (AC3.9).
    public func restoreProposal(for item: Item, assistants: [Assistant] = []) -> (assistants: [String], remembered: Bool) {
        let assistants = assistants.isEmpty ? AssistantRegistry.discover(paths: paths) : assistants
        if let entry = records.entry(named: item.name), !entry.assistants.isEmpty {
            return (entry.assistants, true)
        }
        guard let folder = item.directory else { return ([], false) }
        let parent = folder.deletingLastPathComponent().deletingLastPathComponent()
        let here = assistants.first { $0.skillsRoot.deletingLastPathComponent() == parent }
        return (here.map { [$0.id] } ?? [], false)
    }

    /// Puts a disabled skill back, into the assistants the caller chose (AC3.6, AC3.7).
    ///
    /// One assistant means the real folder goes straight there, with no link to nothing. Several
    /// means the shared store holds it and each gets a link — the same shape `share` produces, so
    /// there is one sharing mechanism in the app rather than two.
    @discardableResult
    public func enableSkill(_ item: Item, into chosen: [Assistant] = [], assistants: [Assistant] = []) throws -> URL {
        guard item.kind == .skill else {
            throw LoadoutError.notEditable("Only skills can be enabled this way: \(item.name)")
        }
        guard let folder = item.directory else { throw LoadoutError.notFound(item.name) }

        switch item.origin {
        case .plugin:
            throw LoadoutError.notEditable(item.name)
        case .project:
            let root = folder.deletingLastPathComponent().deletingLastPathComponent()
            return try move(folder, into: root.appendingPathComponent("skills"))
        case .personal:
            break
        }

        let assistants = assistants.isEmpty ? AssistantRegistry.discover(paths: paths) : assistants
        let targets = chosen.isEmpty ? fallbackTargets(for: item, among: assistants) : chosen
        guard let first = targets.first else { throw LoadoutError.notFound(item.name) }

        if targets.count == 1 {
            // `move` refuses an occupied destination, so this path was already safe.
            let restored = try move(folder, into: first.skillsRoot)
            try records.forget(item.name)
            return restored
        }

        // Nothing moves until every destination is known to be free. Skipping an assistant that
        // already had something of that name looked like success, left that assistant on its own
        // stale copy, and threw away the record of where the skill belonged — so there was no
        // longer anything to tell the user what had not happened.
        for assistant in targets {
            let link = assistant.skillsRoot.appendingPathComponent(item.name)
            guard fm.fileExists(atPath: link.path) else { continue }
            throw LoadoutError.alreadyExists(link)
        }

        // Several: the real folder belongs in the shared store, and every one of them links to it.
        let canonical = try move(folder, into: paths.sharedSkills)
        var restored = canonical
        for assistant in targets {
            let link = assistant.skillsRoot.appendingPathComponent(item.name)
            do {
                try fm.createDirectory(at: assistant.skillsRoot, withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: link, withDestinationURL: canonical)
            } catch {
                throw LoadoutError.io(
                    "\(item.name) is back in the shared folder, but linking it to \(assistant.label) failed: \(error.localizedDescription)"
                )
            }
            if assistant.id == first.id { restored = link }
        }
        try records.forget(item.name)
        return restored
    }

    /// No choice given and no record to read: the assistant whose `skills-off` holds the folder,
    /// or Claude as the last resort on a machine where even that cannot be worked out.
    private func fallbackTargets(for item: Item, among assistants: [Assistant]) -> [Assistant] {
        let proposal = restoreProposal(for: item, assistants: assistants).assistants
        let matched = assistants.filter { proposal.contains($0.id) }
        if !matched.isEmpty { return matched }
        return assistants.filter { $0.skillsRoot == paths.skills }
    }

    // MARK: - Commands

    /// A command or a subagent is a file, not a folder, so switching it off is a move to
    /// `commands-off` or `agents-off` beside wherever it lives (AC10.5, AC11.6).
    ///
    /// No assistant sheet on the way back: these belong to one assistant's directory rather than to
    /// a shared store, so there is nothing to choose.
    @discardableResult
    public func setCommand(_ item: Item, enabled: Bool, plugin: PluginInfo? = nil) throws -> URL {
        guard item.kind == .command || item.kind == .agent, let file = item.path else {
            throw LoadoutError.notEditable(item.name)
        }
        let root = file.deletingLastPathComponent()
        let name = root.lastPathComponent
        let live = enabled ? name.replacingOccurrences(of: "-off", with: "") : name
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent(enabled ? live : "\(live)-off")
        let moved = try move(file, into: destination)

        if let plugin {
            let entry = "\(live)/\(file.lastPathComponent)"
            if enabled {
                try records.forgetPluginEntry(entry, in: plugin.id)
            } else {
                try records.rememberPluginEntry(entry, in: plugin.id)
            }
        }
        return moved
    }

    /// Creates `<name>.md` from a template, in the personal commands directory or a project's.
    @discardableResult
    public func createCommand(
        name: String, description: String, in root: URL? = nil, kind: ItemKind = .command
    ) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSkillName(name) else { throw LoadoutError.invalidName(name) }
        let directory = root ?? (kind == .agent ? paths.agents : paths.commands)
        let file = directory.appendingPathComponent("\(name).md")
        guard !fm.fileExists(atPath: file.path) else { throw LoadoutError.alreadyExists(file) }

        // A command has no `name` field — it is named after its file, and writing one would put
        // back the very confusion this release took out of the warnings. A subagent does: that is
        // the name the Agent tool is called with.
        let text = kind == .agent ? """
        ---
        name: \(name)
        description: \(description.isEmpty ? "What this subagent is for, and when to hand work to it." : description)
        ---

        Say here what this subagent should do, and how it should report back.
        """ : """
        ---
        description: \(description.isEmpty ? "What this command does, and when to reach for it." : description)
        argument-hint: [arguments]
        ---

        Say here what the assistant should do when someone types /\(name).

        Arguments arrive as $ARGUMENTS.
        """
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw LoadoutError.io("Couldn't create \(name): \(error.localizedDescription)")
        }
        return file
    }

    /// Makes another assistant load a command, by linking to the one file.
    ///
    /// Deliberately a symlink rather than a copy, as with skills: one file, one edit. What does not
    /// travel is meaning — `allowed-tools` and `disable-model-invocation` are Claude Code's
    /// vocabulary and are dead text to Codex — so the caller says so before calling this (AC10.12).
    @discardableResult
    public func shareCommand(_ item: Item, with assistant: Assistant) throws -> URL {
        guard item.kind == .command, let file = item.path else {
            throw LoadoutError.notEditable(item.name)
        }
        let link = assistant.commandsRoot.appendingPathComponent(file.lastPathComponent)
        guard !fm.fileExists(atPath: link.path) else { throw LoadoutError.alreadyExists(link) }
        do {
            try fm.createDirectory(at: assistant.commandsRoot, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: file.resolvingSymlinksInPath())
        } catch {
            throw LoadoutError.io(
                "Couldn't link \(item.name) to \(assistant.label): \(error.localizedDescription)"
            )
        }
        return link
    }

    /// Removes an assistant's link to a command. Never removes the only real copy.
    public func unshareCommand(_ item: Item, from assistant: Assistant) throws {
        guard item.kind == .command, let file = item.path else {
            throw LoadoutError.notEditable(item.name)
        }
        let link = assistant.commandsRoot.appendingPathComponent(file.lastPathComponent)
        guard isSymlink(link) else {
            throw LoadoutError.io(
                "The file in \(assistant.label) is the real copy of \(item.name), not a link. Nothing was changed."
            )
        }
        try backups.snapshot(link)
        do {
            try fm.removeItem(at: link)
        } catch {
            throw LoadoutError.io("Couldn't remove the link: \(error.localizedDescription)")
        }
    }

    // MARK: - Out of a repository, into your own

    /// Copies a project's skill, command or subagent into the personal directory, so it works in
    /// every project instead of only that one.
    ///
    /// A copy, not a move: what is inside a repository belongs to whoever works in that repository,
    /// and moving it out would take it away from them at their next pull. The price is two of them
    /// — theirs and yours — which in this direction is the point rather than a flaw.
    ///
    /// The other direction, global into a repository, is deliberately absent: putting a skill in a
    /// repository hands it to the team, and that is a decision to make on purpose in the Finder,
    /// not a button beside a switch.
    @discardableResult
    public func makeGlobal(_ item: Item) throws -> URL {
        guard case .project = item.origin else { throw LoadoutError.notEditable(item.name) }
        guard let source = item.directory ?? item.path else { throw LoadoutError.notFound(item.name) }

        let destinationRoot: URL
        switch item.kind {
        case .skill: destinationRoot = paths.skills
        case .command: destinationRoot = paths.commands
        case .agent: destinationRoot = paths.agents
        default: throw LoadoutError.notEditable(item.name)
        }

        let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
        // Never over something of the same name: the one already there may be the better one, and
        // a copy that silently replaces it is a copy that loses work.
        guard !fm.fileExists(atPath: destination.path) else {
            throw LoadoutError.alreadyExists(destination)
        }
        do {
            try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw LoadoutError.io("Couldn't copy \(item.name): \(error.localizedDescription)")
        }
        return destination
    }

    // MARK: - MCP servers

    /// Switches an MCP server off by lifting its entry out of `~/.claude.json`, and on by putting
    /// back exactly what was lifted (AC11.9, AC11.10).
    ///
    /// Claude Code has no disabled flag for a user-scope server — `enabledMcpjsonServers` only
    /// governs the ones a repository ships in its own `.mcp.json` — so the entry itself has to go.
    /// Two rules make that safe: the file is snapshotted first, and the entry is written into
    /// Loadout's record **before** it is removed, so failing to remember it never loses a server.
    public func setServer(_ item: Item, enabled: Bool) throws {
        guard item.kind == .mcp else { throw LoadoutError.notEditable(item.name) }
        let project = projectKey(for: item)

        guard var root = readClaudeJSON() else {
            throw LoadoutError.io("Couldn't read \(paths.claudeJSON.lastPathComponent).")
        }

        if enabled {
            guard let stored = records.server(named: item.name, project: project),
                  let data = stored.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data)
            else { throw LoadoutError.notFound(item.name) }
            try backups.snapshot(paths.claudeJSON)
            mutateServers(in: &root, project: project) { $0[item.name] = entry }
            try writeJSON(root, to: paths.claudeJSON)
            try records.forgetServer(named: item.name, project: project)
            return
        }

        guard let entry = servers(in: root, project: project)[item.name] else {
            throw LoadoutError.notFound(item.name)
        }
        let json = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        // Remembered first: if this throws, the server is still exactly where it was.
        try records.rememberServer(
            String(decoding: json, as: UTF8.self), named: item.name, project: project
        )
        try backups.snapshot(paths.claudeJSON)
        mutateServers(in: &root, project: project) { $0.removeValue(forKey: item.name) }
        try writeJSON(root, to: paths.claudeJSON)
    }

    /// The project directory an item's servers live under, or nil for the global ones.
    ///
    /// Taken from the item, which carries the path `~/.claude.json` keys it by. Matching on the
    /// folder's name instead would pick an arbitrary one of two checkouts both called `app`, and on
    /// the way back — when the project entry is gone from the file — would fall through to the
    /// global servers and strand a switched-off server with no way to switch it on.
    private func projectKey(for item: Item) -> String? {
        guard case .project = item.origin else { return nil }
        return item.projectDirectory
    }

    private func readClaudeJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: paths.claudeJSON) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func servers(in root: [String: Any], project: String?) -> [String: Any] {
        guard let project else { return root["mcpServers"] as? [String: Any] ?? [:] }
        let projects = root["projects"] as? [String: Any] ?? [:]
        let entry = projects[project] as? [String: Any] ?? [:]
        return entry["mcpServers"] as? [String: Any] ?? [:]
    }

    /// Changes one key of one dictionary and leaves the rest of that large file alone — it holds
    /// conversation pointers and per-project state that are none of this app's business.
    private func mutateServers(
        in root: inout [String: Any], project: String?, _ change: (inout [String: Any]) -> Void
    ) {
        if let project {
            var projects = root["projects"] as? [String: Any] ?? [:]
            var entry = projects[project] as? [String: Any] ?? [:]
            var servers = entry["mcpServers"] as? [String: Any] ?? [:]
            change(&servers)
            entry["mcpServers"] = servers
            projects[project] = entry
            root["projects"] = projects
            return
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        root["mcpServers"] = servers
    }

    // MARK: - Plugin skills

    /// Switches off a single skill inside a plugin, without touching the plugin itself (AC3.12).
    ///
    /// The folder moves to `skills-off` inside the plugin's installed version, which Claude Code
    /// does not read, and the choice is recorded by name — versions come and go, names do not.
    @discardableResult
    public func disablePluginSkill(_ item: Item, in plugin: PluginInfo) throws -> URL {
        guard item.kind == .skill, case .plugin = item.origin else {
            throw LoadoutError.notEditable(item.name)
        }
        guard let folder = item.directory else { throw LoadoutError.notFound(item.name) }
        let parked = try move(folder, into: plugin.installPath.appendingPathComponent("skills-off"))
        try records.rememberPluginEntry("skills/\(item.name)", in: plugin.id)
        return parked
    }

    /// Brings it back and forgets it, so the next update leaves it alone (AC3.14).
    @discardableResult
    public func enablePluginSkill(_ item: Item, in plugin: PluginInfo) throws -> URL {
        guard item.kind == .skill, case .plugin = item.origin else {
            throw LoadoutError.notEditable(item.name)
        }
        guard let folder = item.directory else { throw LoadoutError.notFound(item.name) }
        let restored = try move(folder, into: plugin.installPath.appendingPathComponent("skills"))
        try records.forgetPluginEntry("skills/\(item.name)", in: plugin.id)
        return restored
    }

    /// Re-applies the recorded choices to a plugin's current version (AC3.13).
    ///
    /// This is what survives an update: version 0.46 arrives as a clean copy from the plugin's
    /// repository, knowing nothing of what the user turned off, and this puts it back the way they
    /// left it. A name the plugin no longer ships is left in the record and skipped — dropping it
    /// would lose the choice if the skill returns in a later version (AC3.15).
    @discardableResult
    public func reapplyDisabledSkills(of plugin: PluginInfo) -> [String] {
        var reapplied: [String] = []
        for entry in records.pluginEntries(of: plugin.id) {
            // `skills/vercel-functions` or `commands/status.md`: the directory in front is what
            // says where it goes back to being parked.
            let parts = entry.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let live = plugin.installPath.appendingPathComponent(entry)
            guard fm.fileExists(atPath: live.path) else { continue }
            let off = plugin.installPath.appendingPathComponent("\(parts[0])-off")
            guard (try? move(live, into: off)) != nil else { continue }
            reapplied.append(parts[1])
        }
        return reapplied
    }

    private func move(_ folder: URL, into destinationRoot: URL) throws -> URL {
        let destination = destinationRoot.appendingPathComponent(folder.lastPathComponent)
        // Refusing beats merging: a silent overwrite here loses a skill (AC3.3).
        guard !fm.fileExists(atPath: destination.path) else {
            throw LoadoutError.alreadyExists(destination)
        }
        try backups.snapshot(folder)
        do {
            try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            try fm.moveItem(at: folder, to: destination)
        } catch {
            throw LoadoutError.io("Couldn't move \(folder.lastPathComponent): \(error.localizedDescription)")
        }
        return destination
    }

    // MARK: - Sharing between assistants

    /// Makes a skill load in `assistant` too.
    ///
    /// The skill is promoted to `~/.agents/skills` and each assistant gets a symlink to it,
    /// which is the pattern already in use here: one copy, one edit, both sides current.
    @discardableResult
    public func share(_ item: Item, with assistant: Assistant) throws -> URL {
        guard item.kind == .skill, case .personal = item.origin else {
            throw LoadoutError.notEditable(item.name)
        }
        let canonical = try promoteToShared(named: item.name, across: AssistantRegistry.discover(paths: paths))
        let link = assistant.skillsRoot.appendingPathComponent(item.name)

        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            // Already linked somewhere. Only repoint it if it is pointing at the wrong place.
            let resolved = URL(fileURLWithPath: existing, relativeTo: link.deletingLastPathComponent())
            if resolved.standardizedFileURL.path == canonical.standardizedFileURL.path { return link }
            try backups.snapshot(link)
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw LoadoutError.alreadyExists(link)
        }

        do {
            try fm.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fm.createSymbolicLink(at: link, withDestinationURL: canonical)
        } catch {
            throw LoadoutError.io("Couldn't link \(item.name) to \(assistant.label): \(error.localizedDescription)")
        }
        return link
    }

    /// Stops an assistant from loading a skill, by removing its link.
    ///
    /// Only ever removes a symlink. If that assistant's folder holds the only real copy, the
    /// operation is refused — the point is to unlink, never to lose the skill.
    public func unshare(_ item: Item, from assistant: Assistant) throws {
        guard item.assistants.count > 1 else {
            throw LoadoutError.io(
                "\(item.name) only exists in \(assistant.label). Removing it there would lose it — use Disable instead."
            )
        }
        let link = assistant.skillsRoot.appendingPathComponent(item.name)
        guard isSymlink(link) else {
            throw LoadoutError.io(
                "The folder in \(assistant.label) is the real copy of \(item.name), not a link. Nothing was changed."
            )
        }
        try backups.snapshot(link)
        do {
            try fm.removeItem(at: link)
        } catch {
            throw LoadoutError.io("Couldn't remove the link: \(error.localizedDescription)")
        }
    }

    /// Moves the real folder to `~/.agents/skills` and leaves a symlink where it was.
    /// Already-shared skills are returned untouched.
    @discardableResult
    public func promoteToShared(named name: String, across assistants: [Assistant]) throws -> URL {
        let canonical = paths.sharedSkills.appendingPathComponent(name)
        if fm.fileExists(atPath: canonical.path) { return canonical }

        // The real folder is whichever assistant holds a directory rather than a link.
        let realCopies = assistants
            .map { $0.skillsRoot.appendingPathComponent(name) }
            .filter { fm.fileExists(atPath: $0.path) && !isSymlink($0) }

        guard let source = realCopies.first else { throw LoadoutError.notFound(name) }
        guard realCopies.count == 1 else {
            throw LoadoutError.io(
                "\(name) has its own copy in more than one assistant, and they may differ. Merge them by hand first."
            )
        }

        try backups.snapshot(source)
        do {
            try fm.createDirectory(at: paths.sharedSkills, withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: canonical)
            try fm.createSymbolicLink(at: source, withDestinationURL: canonical)
        } catch {
            throw LoadoutError.io("Couldn't share \(name): \(error.localizedDescription)")
        }
        return canonical
    }

    func isSymlink(_ url: URL) -> Bool {
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Writes `enabledPlugins["<plugin>@<marketplace>"]` into `settings.local.json`,
    /// leaving every other key exactly as it was (AC3.4).
    public func setPlugin(_ plugin: PluginInfo, enabled: Bool) throws {
        let file = paths.localSettings
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        if fm.fileExists(atPath: file.path) {
            try backups.snapshot(file)
        }

        var flags = root["enabledPlugins"] as? [String: Any] ?? [:]
        flags[plugin.id] = enabled
        root["enabledPlugins"] = flags

        try writeJSON(root, to: file)
    }

    private func writeJSON(_ object: [String: Any], to file: URL) throws {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try fm.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
        } catch {
            throw LoadoutError.io("Couldn't write \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Editing

    /// Saves an edited `SKILL.md`. Validates before touching the disk (AC4.2, AC4.6).
    public func save(_ item: Item, contents: String) throws {
        guard item.isEditable else { throw LoadoutError.notEditable(item.name) }
        guard let file = item.path else { throw LoadoutError.notFound(item.name) }

        // A skill and a subagent are both reached by the `name` in their frontmatter, so both are
        // held to it. A command is named after its file and has no such field to check.
        if item.kind == .skill || item.kind == .agent {
            try validateSkillDocument(contents)
        }

        try backups.snapshot(file)
        do {
            try contents.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw LoadoutError.io("Couldn't save \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Saves a file that sits beside a skill's document — a script, a reference note — when Miguel
    /// has accepted the assistant's changes to it.
    ///
    /// `relativePath` is resolved inside the skill's own folder and checked to still be inside it,
    /// so a path the assistant invented can't reach anywhere else on the disk. New files get no
    /// snapshot, because there is nothing yet to lose; existing ones get the same one every other
    /// write here takes, and are not touched if it fails.
    public func saveSupportingFile(in folder: URL, relativePath: String, contents: String) throws {
        let root = folder.standardizedFileURL
        let file = root.appendingPathComponent(relativePath).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else {
            throw LoadoutError.io("\(relativePath) is outside \(root.lastPathComponent) and wasn't written.")
        }

        if fm.fileExists(atPath: file.path) {
            try backups.snapshot(file)
        } else {
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        do {
            try contents.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw LoadoutError.io("Couldn't save \(relativePath): \(error.localizedDescription)")
        }
    }

    public func validateSkillDocument(_ contents: String) throws {
        let front = Frontmatter.parse(contents)
        guard let name = front.name, !name.isEmpty else { throw LoadoutError.missingField("name") }
        guard let description = front.description, !description.isEmpty else {
            throw LoadoutError.missingField("description")
        }
        guard isValidSkillName(name) else { throw LoadoutError.invalidName(name) }
    }

    /// Creates `~/.claude/skills/<name>/SKILL.md` from the template (AC4.3).
    @discardableResult
    public func createSkill(name: String, description: String) throws -> URL {
        guard isValidSkillName(name) else { throw LoadoutError.invalidName(name) }
        let folder = paths.skills.appendingPathComponent(name)
        guard !fm.fileExists(atPath: folder.path) else { throw LoadoutError.alreadyExists(folder) }
        // A skill parked in skills-off would silently come back to life on re-enable.
        let parked = paths.skillsOff.appendingPathComponent(name)
        guard !fm.fileExists(atPath: parked.path) else { throw LoadoutError.alreadyExists(parked) }

        let text = skillTemplate(
            name: name,
            description: description.isEmpty ? "Describe when this skill should be triggered." : description
        )
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(
                to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        } catch {
            throw LoadoutError.io("Couldn't create \(name): \(error.localizedDescription)")
        }
        return folder
    }

    /// Sends a skill to the Trash rather than deleting it (AC4.4).
    public func delete(_ item: Item) throws {
        guard item.isEditable else { throw LoadoutError.notEditable(item.name) }
        guard let target = item.directory ?? item.path else { throw LoadoutError.notFound(item.name) }
        try backups.snapshot(target)
        do {
            try fm.trashItem(at: target, resultingItemURL: nil)
        } catch {
            throw LoadoutError.io("Couldn't move \(item.name) to the Trash: \(error.localizedDescription)")
        }
    }
}
