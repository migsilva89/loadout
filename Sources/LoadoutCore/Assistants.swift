import Foundation

/// A coding assistant that reads skills from `~/.<id>/skills`.
///
/// Not an enum: the set is whatever is on this machine. Install another assistant tomorrow
/// and it appears on its own, with no code change here.
public struct Assistant: Identifiable, Hashable, Sendable {
    /// The dot-directory name — `claude`, `codex`, `trae`.
    public let id: String
    public let label: String
    public let skillsRoot: URL
    /// The installed app, when there is one. Used to show its real icon rather than a
    /// hand-drawn imitation of someone's trademark.
    public let appPath: String?

    public init(id: String, label: String, skillsRoot: URL, appPath: String? = nil) {
        self.id = id
        self.label = label
        self.skillsRoot = skillsRoot
        self.appPath = appPath
    }

    /// Two letters for when there is no app icon to show.
    public var initials: String {
        String(label.replacingOccurrences(of: " ", with: "").prefix(2)).uppercased()
    }
}

public enum AssistantRegistry {
    /// Nicer names, and where each assistant's Mac app lives when it has one.
    /// Anything not listed still shows up, under its directory name.
    static let known: [String: (label: String, app: String?)] = [
        "claude": ("Claude Code", "/Applications/Claude.app"),
        "codex": ("Codex", "/Applications/ChatGPT.app"),
        "cursor": ("Cursor", "/Applications/Cursor.app"),
        "windsurf": ("Windsurf", "/Applications/Windsurf.app"),
        "trae": ("Trae", "/Applications/Trae.app"),
        "kiro": ("Kiro", "/Applications/Kiro.app"),
        "factory": ("Factory", nil),
        "hermes": ("Hermes", nil),
        "commandcode": ("CommandCode", nil),
        "gemini": ("Gemini", nil),
        "copilot": ("Copilot", nil),
        "opencode": ("opencode", nil),
        "droid": ("Droid", nil),
    ]

    /// `~/.agents/skills` is the shared store the assistants link into, not an assistant.
    static let sharedDirectoryName = ".agents"

    /// Every `~/.<name>/skills` directory on the machine.
    public static func discover(paths: Paths) -> [Assistant] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.home, includingPropertiesForKeys: nil, options: []
        ) else { return [] }

        var found: [Assistant] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("."), name != sharedDirectoryName else { continue }
            let id = String(name.dropFirst())
            guard !id.isEmpty, !id.contains(".") else { continue }

            // An assistant is one that actually keeps skills. Having ~/.gemini or ~/.ssh
            // says nothing — without a skills directory there is nowhere to put one, and
            // listing them all turns the panel into noise.
            let root = entry.appendingPathComponent("skills")
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            let entry = known[id]
            let app = entry?.app.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
            found.append(Assistant(
                id: id,
                label: entry?.label ?? id.capitalized,
                skillsRoot: root,
                appPath: app
            ))
        }

        // The two he actually works in lead; the rest alphabetically.
        let leaders = ["claude", "codex"]
        return found.sorted { a, b in
            switch (leaders.firstIndex(of: a.id), leaders.firstIndex(of: b.id)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            }
        }
    }
}
