import Foundation

/// Copies anything about to change into `~/.claude/.loadout-backups/<timestamp>/`.
///
/// The rule is absolute: if the copy fails, the write does not happen (AC5.4). An app that
/// edits the user's agent configuration has to be boring about this.
public struct Backups: Sendable {
    public let paths: Paths
    private var fm: FileManager { .default }

    public init(paths: Paths) {
        self.paths = paths
    }

    /// Snapshots a file or a whole directory tree, preserving its layout under the stamp folder.
    @discardableResult
    public func snapshot(_ source: URL, stamp: Date = Date()) throws -> URL? {
        guard fm.fileExists(atPath: source.path) else { return nil }

        let folder = paths.backups.appendingPathComponent(Self.stampFormatter.string(from: stamp))
        // Keep enough of the original path to tell two backups of the same name apart.
        let destination = folder.appendingPathComponent(Self.relativeLabel(for: source, under: paths))

        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            // copyItem handles both a lone file and a full tree, which is what AC5.2 asks for.
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw LoadoutError.backupFailed(error.localizedDescription)
        }
        return destination
    }

    /// `~/.claude/skills/foo` becomes `skills/foo`; anything outside `~/.claude` keeps its
    /// last two components so project files stay distinguishable.
    static func relativeLabel(for source: URL, under paths: Paths) -> String {
        let base = paths.claude.standardizedFileURL.path
        let path = source.standardizedFileURL.path
        if path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        let parts = source.pathComponents.suffix(2)
        return parts.joined(separator: "/")
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Enumeration, for Settings › Backups

    /// One stamp folder directly inside `paths.backups`.
    public struct Snapshot: Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var date: Date
        public var url: URL
    }

    /// Every top-level snapshot folder whose name round-trips through `stampFormatter`,
    /// newest first. Anything else living in `paths.backups` — there shouldn't be anything,
    /// but this is the boundary that keeps deletion from ever guessing — is silently skipped.
    public func listSnapshots() -> [Snapshot] {
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.backups, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var result: [Snapshot] = []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            guard let date = Self.stampFormatter.date(from: entry.lastPathComponent) else { continue }
            result.append(Snapshot(name: entry.lastPathComponent, date: date, url: entry))
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Bytes across every snapshot folder. Walking the whole backups tree is not cheap, so
    /// this is deliberately synchronous — callers run it off the main thread themselves.
    public func totalSize() -> Int64 {
        listSnapshots().reduce(0) { $0 + directorySize($1.url) }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Deletes snapshot folders older than `cutoff`, straight to the Trash — same rule as
    /// everything else this app removes. Every candidate is re-checked against `listSnapshots()`
    /// and against being a direct child of `paths.backups`, so this can never reach outside the
    /// stamp folders it enumerated, and never removes `paths.backups` itself.
    @discardableResult
    public func deleteSnapshots(olderThan cutoff: Date) throws -> Int {
        var removed = 0
        for snapshot in listSnapshots() where snapshot.date < cutoff {
            guard snapshot.url.deletingLastPathComponent().standardizedFileURL
                == paths.backups.standardizedFileURL
            else { continue }
            try fm.trashItem(at: snapshot.url, resultingItemURL: nil)
            removed += 1
        }
        return removed
    }
}
