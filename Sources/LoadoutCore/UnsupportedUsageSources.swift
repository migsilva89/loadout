import Foundation

/// The assistants whose history exists but cannot yet prove a skill was used.
///
/// They are registered rather than left out on purpose. A source nobody lists contributes a silent
/// zero, which reads exactly like "never used" — and that is the bug this whole feature exists to
/// fix. Listed, they say `Format unsupported` and the zero is explainable.

/// OpenCode, at `~/.local/share/opencode/storage`.
///
/// The store is perfectly parseable — one JSON file per session, message and part — but there is no
/// skill mechanism to find: its tools are `read`, `edit`, `bash`, `grep`, `glob`, `todowrite`,
/// `write`, `list`, `task` and `webfetch`, and 4 419 tool parts contained not one `SKILL.md`.
public struct OpenCodeUsageSource: UsageSource {
    public let id = "opencode"
    public let assistant = "opencode"
    public let label = "opencode"
    public let parserVersion = 1
    public let isSupported = false

    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func historyFiles() -> [URL] {
        let root = paths.openCodeSessions
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "json" { found.append(url) }
        return found
    }
}

/// Cursor, at `~/.cursor/projects/*/agent-transcripts`.
///
/// The transcripts were found and they are shaped much like Claude's, but a record has exactly two
/// keys — `role` and `message` — so there is no time on it. Without a timestamp an event cannot be
/// placed inside the 30/90/365-day window, and dating a whole session by its file would be wrong the
/// moment it is resumed. There is no skill tool either, which fits: Cursor keeps its skills in
/// `skills-cursor`.
public struct CursorUsageSource: UsageSource {
    public let id = "cursor"
    public let assistant = "cursor"
    public let label = "Cursor"
    public let parserVersion = 1
    public let isSupported = false

    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func historyFiles() -> [URL] {
        jsonlFiles(under: paths.cursorProjects).filter {
            $0.pathComponents.contains("agent-transcripts")
        }
    }
}

/// Pi, at `~/.pi/agent/sessions`.
///
/// The format is readable and timestamped, but there is no skill signal in it, and on this machine
/// the whole history is one session of two messages.
public struct PiUsageSource: UsageSource {
    public let id = "pi"
    public let assistant = "pi"
    public let label = "Pi"
    public let parserVersion = 1
    public let isSupported = false

    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func historyFiles() -> [URL] { jsonlFiles(under: paths.piSessions) }
}
