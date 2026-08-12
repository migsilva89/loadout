import Foundation
@testable import LoadoutCore

/// A throwaway `~` on disk: every test builds its own so nothing ever touches the real
/// `~/.claude` (AC9.2).
final class Fixture {
    let root: URL
    let paths: Paths
    private let fm = FileManager.default

    init(function: String = #function) {
        let name = "loadout-tests-\(UUID().uuidString.prefix(8))"
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        paths = Paths(home: root)
        try? fm.createDirectory(at: paths.skills, withIntermediateDirectories: true)
        try? fm.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    // MARK: Builders

    @discardableResult
    func skill(_ name: String, description: String = "Faz coisas.", disabled: Bool = false,
               extraFile: String? = nil, body: String = "Corpo.") -> URL {
        let base = disabled ? paths.skillsOff : paths.skills
        let folder = base.appendingPathComponent(name)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = """
        ---
        name: \(name)
        description: \(description)
        ---

        \(body)
        """
        try! text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        if let extraFile {
            let nested = folder.appendingPathComponent("scripts")
            try! fm.createDirectory(at: nested, withIntermediateDirectories: true)
            try! extraFile.write(
                to: nested.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8
            )
        }
        return folder
    }

    @discardableResult
    func rawSkill(_ name: String, contents: String) -> URL {
        let folder = paths.skills.appendingPathComponent(name)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! contents.write(
            to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        return folder
    }

    func command(_ name: String, description: String = "Um comando.") {
        try! fm.createDirectory(at: paths.commands, withIntermediateDirectories: true)
        let text = "---\nname: \(name)\ndescription: \(description)\n---\n\nFaz isto."
        try! text.write(
            to: paths.commands.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8
        )
    }

    func agent(_ name: String) {
        try! fm.createDirectory(at: paths.agents, withIntermediateDirectories: true)
        let text = "---\nname: \(name)\ndescription: Um agente.\n---\n\nInstruções."
        try! text.write(
            to: paths.agents.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8
        )
    }

    /// Installs a fake plugin the way Claude Code lays them out on disk.
    func plugin(_ name: String, marketplace: String = "mkt", skills: [String] = [],
                commands: [String] = [], enabled: Bool? = nil) {
        let install = paths.claude
            .appendingPathComponent("plugins/cache/\(marketplace)/\(name)/1.0.0")
        for skill in skills {
            let folder = install.appendingPathComponent("skills/\(skill)")
            try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = "---\nname: \(skill)\ndescription: Do plugin \(name).\n---\n\nCorpo."
            try! text.write(
                to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }
        for command in commands {
            let folder = install.appendingPathComponent("commands")
            try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try! "---\nname: \(command)\ndescription: Comando do plugin.\n---\n".write(
                to: folder.appendingPathComponent("\(command).md"), atomically: true, encoding: .utf8
            )
        }

        var registry: [String: Any] = ["version": 2, "plugins": [:]]
        if let data = try? Data(contentsOf: paths.installedPlugins),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            registry = parsed
        }
        var plugins = registry["plugins"] as? [String: Any] ?? [:]
        plugins["\(name)@\(marketplace)"] = [[
            "scope": "user",
            "installPath": install.path,
            "version": "1.0.0",
        ]]
        registry["plugins"] = plugins
        write(json: registry, to: paths.installedPlugins)

        if let enabled {
            var settings: [String: Any] = [:]
            if let data = try? Data(contentsOf: paths.localSettings),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = parsed
            }
            var flags = settings["enabledPlugins"] as? [String: Any] ?? [:]
            flags["\(name)@\(marketplace)"] = enabled
            settings["enabledPlugins"] = flags
            write(json: settings, to: paths.localSettings)
        }
    }

    func mcpServer(_ name: String, command: String = "npx thing") {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: paths.claudeJSON),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[name] = ["command": command]
        root["mcpServers"] = servers
        write(json: root, to: paths.claudeJSON)
    }

    func settings(_ object: [String: Any], local: Bool = true) {
        write(json: object, to: local ? paths.localSettings : paths.settings)
    }

    func projectsIndex(_ contents: String) {
        try! fm.createDirectory(at: paths.projectsRoot, withIntermediateDirectories: true)
        try! contents.write(to: paths.projectsIndex, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func projectRepo(_ relativePath: String, skills: [String] = []) -> URL {
        let repo = paths.projectsRoot.appendingPathComponent(relativePath)
        for skill in skills {
            let folder = repo.appendingPathComponent(".claude/skills/\(skill)")
            try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try! "---\nname: \(skill)\ndescription: Do repo.\n---\n\nCorpo.".write(
                to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }
        return repo
    }

    /// Writes a transcript file with the exact record shape Claude Code produces.
    func transcript(_ name: String, lines: [String], project: String = "meu-repo") {
        let folder = paths.transcripts.appendingPathComponent("-Users-me-\(project)")
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! lines.joined(separator: "\n").write(
            to: folder.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8
        )
    }

    func write(json object: [String: Any], to url: URL) {
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try! data.write(to: url)
    }

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

// MARK: - Transcript line helpers

enum Line {
    static func skill(_ name: String, at iso: String, cwd: String = "/Users/me/meu-repo") -> String {
        """
        {"type":"assistant","timestamp":"\(iso)","cwd":"\(cwd)","message":{"content":[\
        {"type":"tool_use","name":"Skill","input":{"skill":"\(name)"}}]}}
        """
    }

    static func agent(_ name: String, at iso: String, cwd: String = "/Users/me/meu-repo") -> String {
        """
        {"type":"assistant","timestamp":"\(iso)","cwd":"\(cwd)","message":{"content":[\
        {"type":"tool_use","name":"Agent","input":{"subagent_type":"\(name)"}}]}}
        """
    }

    static func mcp(_ server: String, at iso: String, cwd: String = "/Users/me/meu-repo") -> String {
        """
        {"type":"assistant","timestamp":"\(iso)","cwd":"\(cwd)","message":{"content":[\
        {"type":"tool_use","name":"mcp__\(server)__do_thing","input":{}}]}}
        """
    }

    static func command(_ name: String, at iso: String, cwd: String = "/Users/me/meu-repo") -> String {
        """
        {"type":"user","timestamp":"\(iso)","cwd":"\(cwd)","message":{"content":\
        "<command-name>/\(name)</command-name><command-message>go</command-message>"}}
        """
    }

    static let corrupted = "{\"type\":\"assistant\",\"timestamp\": broken json here"
}
