import Foundation

/// What Loadout has left lying around, and getting rid of it.
///
/// The app writes two kinds of thing behind your back. Backups: a copy of a file before every
/// edit, which is the only reason a mistake is survivable, and which nothing has ever removed on
/// its own — a year of editing leaves a year of copies. And records: the small notes that remember
/// a switched-off MCP server's configuration so it can be put back exactly. A record whose server
/// you later deleted by hand is a note about nothing.
///
/// Neither is dangerous, and that is the problem: nothing ever complains, so it accumulates
/// silently until somebody goes looking at their disk. This counts it and clears it.
public struct Housekeeping: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// How old a backup has to be before the automatic sweep takes it.
    ///
    /// Thirty days is long enough that a copy is still there when somebody realises last week's
    /// edit was wrong, and short enough that the folder stops growing without end. The same number
    /// the manual button has always used, now applied without being asked.
    public static let keepBackupsFor: TimeInterval = 30 * 24 * 3600

    /// A summary of what could be cleared, for a screen to show before anybody presses anything.
    public struct Report: Equatable, Sendable {
        /// Backup snapshots on disk, and how many are old enough to be swept.
        public var snapshots: Int
        public var expiredSnapshots: Int
        public var bytes: Int64
        /// Records pointing at a switched-off MCP server that is no longer written down anywhere
        /// Loadout can put back — the note outlived the thing.
        public var strandedRecords: Int
        /// Record files that could not be read at all. Never touched automatically: an unreadable
        /// file is a question, and deleting it answers it the wrong way.
        public var unreadableRecords: [URL]

        public var isEmpty: Bool {
            expiredSnapshots == 0 && strandedRecords == 0
        }

        public init(
            snapshots: Int = 0, expiredSnapshots: Int = 0, bytes: Int64 = 0,
            strandedRecords: Int = 0, unreadableRecords: [URL] = []
        ) {
            self.snapshots = snapshots
            self.expiredSnapshots = expiredSnapshots
            self.bytes = bytes
            self.strandedRecords = strandedRecords
            self.unreadableRecords = unreadableRecords
        }
    }

    /// Walks everything and reports. Not cheap — it sizes every backup — so callers run it off the
    /// main thread, as the Storage screen already did for its own count.
    public func report(now: Date = Date()) -> Report {
        let backups = Backups(paths: paths)
        let snapshots = backups.listSnapshots()
        let cutoff = now.addingTimeInterval(-Self.keepBackupsFor)
        let records = OffRecords(paths: paths)

        return Report(
            snapshots: snapshots.count,
            expiredSnapshots: snapshots.filter { $0.date < cutoff }.count,
            bytes: backups.totalSize(),
            strandedRecords: strandedServerRecords(records).count,
            unreadableRecords: records.unreadable()
        )
    }

    /// Clears what the report said could go: old snapshots to the Trash, stranded records
    /// forgotten. Returns what it actually did, which is what the screen says afterwards.
    ///
    /// Unreadable files are left alone on purpose. Everything removed here can be described in one
    /// sentence to the person who pressed the button; a file nobody can read cannot be, so it is
    /// reported and kept.
    @discardableResult
    public func sweep(now: Date = Date()) throws -> Report {
        let records = OffRecords(paths: paths)
        let stranded = strandedServerRecords(records)
        for name in stranded { try? records.forgetServer(named: name) }

        let removed = try Backups(paths: paths)
            .deleteSnapshots(olderThan: now.addingTimeInterval(-Self.keepBackupsFor))

        return Report(expiredSnapshots: removed, strandedRecords: stranded.count)
    }

    /// Records that describe nothing any more: the server is back in `~/.claude.json` by other
    /// means, so the copy kept here is stale and forgetting it loses nothing.
    ///
    /// This used to ask the opposite question — records whose server "no longer appears" — and that
    /// was both useless and dangerous. Useless because a switched-off server appears *from this very
    /// record*, so the condition could not fire in the normal case. Dangerous because the one way it
    /// could fire was `~/.claude.json` being unreadable: the scan then returned nothing, every global
    /// record looked stranded, and the launch sweep deleted the only surviving copy of every
    /// switched-off server's configuration.
    ///
    /// Narrow in three ways, because the cost of being wrong is a server nobody can put back:
    ///
    /// - Nothing is swept unless the file was read. Unreadable means unknown, and unknown means
    ///   leave it alone.
    /// - Only records with no project attached are considered. A project's records describe a
    ///   repository that may simply not be open right now, and "not open" is not "gone".
    /// - A record whose server is absent from the file is exactly what a switched-off server looks
    ///   like, and is never touched.
    func strandedServerRecords(_ records: OffRecords) -> [String] {
        let recorded = records.servers()
        guard !recorded.isEmpty else { return [] }
        guard let data = try? Data(contentsOf: paths.claudeJSON),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let live = Set((root["mcpServers"] as? [String: Any] ?? [:]).keys)

        return recorded.keys.compactMap { key -> String? in
            // Keys are `project\u{1}name`; an empty project means a global record.
            let parts = key.split(separator: "\u{1}", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].isEmpty else { return nil }
            let name = String(parts[1])
            // Present in the file *and* remembered here: the server came back by hand or by whatever
            // installed it, the app already prefers the live one, and this note is left over.
            return live.contains(name) ? name : nil
        }.sorted()
    }
}
