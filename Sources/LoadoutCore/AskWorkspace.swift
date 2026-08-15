import Foundation

/// A throwaway copy of a skill's folder for an assistant to work in.
///
/// This is the whole safety story of the conversation feature. The assistant is given write
/// permission and runs shell commands of its own accord — verified, it ran `find` to locate the
/// file — so it is never pointed at `~/.claude`. It gets a copy, and Miguel's folder changes only
/// when he accepts a block and saves, through the same write path with the same mandatory backup
/// as any other edit.
public struct AskWorkspace: Sendable {
    /// The skill whose folder was copied, by item id.
    public let itemID: String
    /// The real folder, which the assistant never sees.
    public let origin: URL
    /// The copy it works in.
    public let root: URL

    public init(itemID: String, origin: URL, root: URL) {
        self.itemID = itemID
        self.origin = origin
        self.root = root
    }

    /// One file the assistant changed, with both versions read back as text.
    public struct ChangedFile: Identifiable, Hashable, Sendable {
        /// Path relative to the folder, e.g. `SKILL.md` or `scripts/run.sh`.
        public let id: String
        public let original: String
        public let modified: String
        /// True when the assistant created it, so there is nothing on disk to diff against.
        public let isNew: Bool

        public init(id: String, original: String, modified: String, isNew: Bool) {
            self.id = id
            self.original = original
            self.modified = modified
            self.isNew = isNew
        }

        public var blocks: [DiffBlock] { DiffBlocks.blocks(from: original, to: modified) }
    }
}

/// Creates, finds, compares and removes the workspaces.
public struct AskWorkspaces: Sendable {
    /// `~/Library/Application Support/Loadout/ask-workspaces`, alongside the backups.
    public let root: URL
    private var fm: FileManager { .default }

    public init(root: URL) {
        self.root = root
    }

    public init(paths: Paths) {
        self.init(root: paths.askWorkspaces)
    }

    public func directory(for itemID: String) -> URL {
        root.appendingPathComponent(slug(itemID), isDirectory: true)
    }

    public func exists(for itemID: String) -> Bool {
        isUsable(directory(for: itemID))
    }

    /// A directory the assistant can actually be pointed at. A dangling symlink is not one, even
    /// though something is there.
    private func isUsable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether anything at all sits at that path, symlinks included — `fileExists` follows links
    /// and so reports a broken one as absent.
    private func entryExists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    /// Copies `origin` into a workspace and returns it, reusing the copy if one is already there —
    /// a second turn of the same conversation must not throw away the edits of the first.
    ///
    /// The copy is initialised as a git repository because `codex` refuses to run outside one.
    /// A failed `git init` is not fatal: the codex invocation also passes the flag that skips
    /// that check, so the run still happens.
    @discardableResult
    public func open(itemID: String, origin: URL) throws -> AskWorkspace {
        // A shared skill's folder is a symlink into `~/.agents/skills`, and copying a symlink
        // copies the link — which, from its new home, points at nothing. Resolve it first, so the
        // copy holds the files themselves and comparing afterwards reads the files they came from.
        let origin = origin.resolvingSymlinksInPath()
        let destination = directory(for: itemID)
        // A copy left behind by the version that copied symlinks is a dangling link: it reports as
        // absent, yet a copy onto it fails because something is there. Clear it rather than making
        // the conversation unusable until someone deletes it by hand.
        if !isUsable(destination), entryExists(destination) {
            try? fm.removeItem(at: destination)
        }
        if !isUsable(destination) {
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                try fm.copyItem(at: origin, to: destination)
            } catch {
                throw LoadoutError.io(
                    "Couldn't make a working copy of \(origin.lastPathComponent): \(error.localizedDescription)"
                )
            }
            initialiseGitRepository(at: destination)
        }
        return AskWorkspace(itemID: itemID, origin: origin, root: destination)
    }

    /// Every file the assistant added or changed in the copy, each with the original text beside
    /// the new one. Files it deleted are ignored: nothing in Loadout deletes on an assistant's
    /// word, and a missing file is reported as "unchanged" rather than proposed for removal.
    public func changes(in workspace: AskWorkspace) -> [AskWorkspace.ChangedFile] {
        var result: [AskWorkspace.ChangedFile] = []
        for relative in files(under: workspace.root).sorted() {
            let copy = workspace.root.appendingPathComponent(relative)
            let real = workspace.origin.appendingPathComponent(relative)
            guard let modified = try? String(contentsOf: copy, encoding: .utf8) else { continue }
            let original = (try? String(contentsOf: real, encoding: .utf8))
            guard original != modified else { continue }
            result.append(AskWorkspace.ChangedFile(
                id: relative,
                original: original ?? "",
                modified: modified,
                isNew: original == nil
            ))
        }
        return result
    }

    /// Deletes the workspace. `hasPendingBlocks` is the trap Miguel asked for: a copy is never
    /// thrown away while a change in it is still undecided.
    public func remove(itemID: String, hasPendingBlocks: Bool) throws {
        guard !hasPendingBlocks else {
            throw LoadoutError.io(
                "There are still changes waiting for you to accept or reject, so the working copy was kept."
            )
        }
        let directory = directory(for: itemID)
        guard fm.fileExists(atPath: directory.path) else { return }
        do {
            try fm.removeItem(at: directory)
        } catch {
            throw LoadoutError.io("Couldn't remove the working copy: \(error.localizedDescription)")
        }
    }

    /// Removes every workspace whose conversation is gone — called at launch, with the ids of the
    /// conversations that survived. Nothing else remembers these folders exist, so without this
    /// they would pile up.
    @discardableResult
    public func removeOrphans(keeping liveItemIDs: Set<String>) -> Int {
        let keep = Set(liveItemIDs.map(slug))
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for entry in entries where !keep.contains(entry) {
            if (try? fm.removeItem(at: root.appendingPathComponent(entry))) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Internals

    /// An item id can hold a slash — it is derived from a path — and would then be read as a
    /// subfolder. Flattened, so one id is always exactly one directory.
    func slug(_ itemID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(itemID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "workspace" : cleaned
    }

    /// Relative paths of every file in the copy, skipping git's own directory and the metadata
    /// junk the assistants leave behind.
    private func files(under directory: URL) -> [String] {
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var result: [String] = []
        let prefix = directory.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".git" || name == ".DS_Store" {
                walker.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            result.append(String(path.dropFirst(prefix.count)))
        }
        return result
    }

    private func initialiseGitRepository(at directory: URL) {
        guard let git = AssistantCLIRegistry.defaultLocate("git") else { return }
        for arguments in [["init", "--quiet"], ["add", "-A"], ["-c", "user.name=Loadout",
                                                               "-c", "user.email=loadout@localhost",
                                                               "commit", "--quiet", "-m", "working copy"]] {
            let task = Process()
            task.executableURL = git
            task.arguments = arguments
            task.currentDirectoryURL = directory
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }
}
