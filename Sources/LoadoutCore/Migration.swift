import Foundation

/// Moving Loadout's own files out of `~/.claude`.
///
/// They were written there because that is where everything else the app reads lives, which
/// was a mistake: the backups, the usage index and the icons are Loadout's, not Claude's, and
/// anyone tidying or resetting `~/.claude` would have taken them with it. They now live in
/// `~/Library/Application Support/Loadout`, where the system expects an app's own files.
///
/// This runs at every launch and does nothing at all once there is nothing left to move.
extension Paths {
    /// What one launch moved, for the caller to log or ignore.
    public struct Migration: Sendable, Equatable {
        public var backups = false
        public var index = false
        public var icons = false

        public var movedAnything: Bool { backups || index || icons }

        /// One line, for the status footer — or nil when there was nothing to do.
        public var summary: String? {
            guard movedAnything else { return nil }
            let parts = [
                backups ? "backups" : nil,
                index ? "the usage index" : nil,
                icons ? "the assistant icons" : nil,
            ].compactMap { $0 }
            let list = parts.count > 1
                ? parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
                : parts.joined()
            return "Moved \(list) out of ~/.claude into Loadout's own folder."
        }
    }

    /// Moves each of the three, if it is still in the old place and not yet in the new one.
    ///
    /// Never overwrites: a destination that already exists means this machine has already been
    /// through the move — or has newer data — and the old copy is left exactly where it is
    /// rather than being merged blind. Nothing here throws: a launch must not be held up by a
    /// folder that could not be moved, and the app works either way.
    @discardableResult
    public func migrateOutOfClaudeDirectory() -> Migration {
        var moved = Migration()
        moved.backups = move(legacyBackups, to: backups)
        moved.icons = move(legacyCLIIcons, to: cliIcons)
        moved.index = moveIndex()

        // Only if it is empty. Anything else in there was not ours to remove.
        if let left = try? FileManager.default.contentsOfDirectory(atPath: legacySupport.path),
           left.isEmpty {
            try? FileManager.default.removeItem(at: legacySupport)
        }
        return moved
    }

    /// The index is three files, not one: SQLite keeps a write-ahead log and a shared-memory
    /// file beside the database, and a database moved without them opens as a database that
    /// lost its last transactions.
    private func moveIndex() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyIndex.path), !fm.fileExists(atPath: index.path) else {
            return false
        }
        guard move(legacyIndex, to: index) else { return false }
        for suffix in ["-wal", "-shm"] {
            _ = move(
                URL(fileURLWithPath: legacyIndex.path + suffix),
                to: URL(fileURLWithPath: index.path + suffix)
            )
        }
        return true
    }

    /// True only when something was actually moved.
    private func move(_ from: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: destination.path) else {
            return false
        }
        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fm.moveItem(at: from, to: destination)
            return true
        } catch {
            return false
        }
    }
}
