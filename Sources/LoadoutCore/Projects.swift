import Foundation

/// Reads the project list out of `~/Projects/INDEX.md`.
///
/// That file is generated and is the house rule for "what repos exist", so the app reads it
/// instead of walking the disk. If it is missing, the app still works — it just has nothing
/// to offer in the context picker beyond Global (AC1.6).
public struct ProjectsIndex: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    public func load() -> [Project] {
        guard let text = try? String(contentsOf: paths.projectsIndex, encoding: .utf8) else {
            return []
        }
        return Self.parse(text, root: paths.projectsRoot)
    }

    /// Rows look like: `| `TGC/open-mercato` | description |`
    static func parse(_ text: String, root: URL) -> [Project] {
        var seen = Set<String>()
        var projects: [Project] = []

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }

            let columns = trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = columns.first else { continue }

            // Only backticked paths are project rows; that skips headers and separators.
            guard first.hasPrefix("`"), first.hasSuffix("`"), first.count > 2 else { continue }
            let relative = String(first.dropFirst().dropLast())
            guard !relative.isEmpty, !relative.contains(" "), seen.insert(relative).inserted else {
                continue
            }

            projects.append(Project(
                name: URL(fileURLWithPath: relative).lastPathComponent,
                relativePath: relative,
                path: root.appendingPathComponent(relative)
            ))
        }

        return projects.sorted { $0.relativePath.lowercased() < $1.relativePath.lowercased() }
    }
}
