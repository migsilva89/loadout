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
}
