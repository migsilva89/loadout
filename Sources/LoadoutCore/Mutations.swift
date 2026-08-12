import Foundation

/// Every change the app makes to the disk goes through here, and every one of them
/// takes a snapshot first.
public struct Mutations: Sendable {
    public let paths: Paths
    public let backups: Backups
    private var fm: FileManager { .default }

    public init(paths: Paths) {
        self.paths = paths
        self.backups = Backups(paths: paths)
    }

    // MARK: - Enable and disable

    /// Moves a personal skill into `skills-off/`, keeping the whole folder intact (AC3.1).
    @discardableResult
    public func disableSkill(_ item: Item) throws -> URL {
        guard item.kind == .skill else {
            throw LoadoutError.notEditable("Only skills can be disabled this way: \(item.name)")
        }
        guard case .personal = item.origin else {
            throw LoadoutError.notEditable(item.name)
        }
        guard let folder = item.directory else { throw LoadoutError.notFound(item.name) }
        return try move(folder, into: paths.skillsOff)
    }

    /// Moves it back (AC3.2).
    @discardableResult
    public func enableSkill(_ item: Item) throws -> URL {
        guard item.kind == .skill, case .personal = item.origin else {
            throw LoadoutError.notEditable(item.name)
        }
        guard let folder = item.directory else { throw LoadoutError.notFound(item.name) }
        return try move(folder, into: paths.skills)
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

        if item.kind == .skill {
            try validateSkillDocument(contents)
        }

        try backups.snapshot(file)
        do {
            try contents.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw LoadoutError.io("Couldn't save \(file.lastPathComponent): \(error.localizedDescription)")
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
