import Foundation
import LoadoutCore

/// An explicit integration check with an installed Codex binary, isolated from user config.
/// Normal unit tests use recorded protocol fixtures and do not require Codex to be installed.
@MainActor
enum CodexSelfCheck {
    static func run() -> Never {
        var failures: [String] = []
        func check(_ label: String, _ value: Bool) {
            print("\(value ? "✓" : "✗") \(label)")
            if !value { failures.append(label) }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("loadout-codex-check-\(UUID().uuidString)")
        do {
            guard let executable = AssistantCLIRegistry.defaultLocate("codex") else {
                throw LoadoutError.io("Install Codex before running the Codex integration check.")
            }
            let paths = Paths(home: root, codexExecutable: executable)
            let market = root.appendingPathComponent("market")
            let source = market.appendingPathComponent("plugins/kit")
            func json(_ object: [String: Any], _ file: URL) throws {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: object).write(to: file)
            }
            func package(_ version: String) throws {
                let cache = paths.codexPluginCache.appendingPathComponent("test/kit/\(version)")
                for folder in [source, cache] {
                    try json(["name": "kit", "version": version, "skills": "./custom"], folder.appendingPathComponent(".codex-plugin/plugin.json"))
                    for name in ["a", "b"] {
                        let directory = folder.appendingPathComponent("custom/\(name)")
                        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                        try "---\nname: \(name)\ndescription: A fixture skill.\n---\nFixture body.".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                    }
                }
            }
            try package("1.0.0")
            try json(["name": "test", "plugins": [["name": "kit", "source": ["source": "local", "path": "./plugins/kit"],
                                                    "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"]]]],
                     market.appendingPathComponent(".agents/plugins/marketplace.json"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let quotedMarket = String(data: try encoder.encode(market.path), encoding: .utf8)!
            let config = """
            # Keep this comment and unrelated setting.
            model = "fixture-model"
            [marketplaces.test]
            source_type = "local"
            source = \(quotedMarket)
            [plugins."kit@test"]
            enabled = true

            """
            try config.write(to: paths.codexConfig, atomically: true, encoding: .utf8)
            let model = AppModel(paths: paths)
            model.reload()
            if let error = model.errorMessage { print("Provider diagnostic: \(error)") }
            check("native Codex inventory has no diagnostics", model.errorMessage == nil)
            check("Codex-only plugin and custom skill paths are discovered", model.plugins.count == 1 && model.items.filter { $0.pluginID != nil }.count == 2)
            func plugin() throws -> PluginInfo {
                guard let p = model.plugins.first else { throw LoadoutError.io("Missing fixture plugin: \(model.errorMessage ?? "no diagnostics")") }; return p
            }
            func skill(_ name: String) throws -> Item {
                guard let item = model.items.first(where: { $0.name == name && $0.pluginID != nil }) else { throw LoadoutError.notFound(name) }; return item
            }
            model.toggle(try skill("b"))
            check("native skill switch changes only b", try skill("a").enabled && !skill("b").enabled)
            model.togglePlugin(try plugin())
            check("disabled parent retains both children", model.items.filter { $0.pluginID != nil }.count == 2)
            check("all child switches are effectively off", model.items.filter { $0.pluginID != nil }.allSatisfy { !model.isEffectivelyEnabled($0) })
            model.toggle(try skill("a"))
            check("direct action is blocked while parent is off", model.errorMessage != nil)
            model.errorMessage = nil
            model.togglePlugin(try plugin())
            check("parent on restores a and keeps b off", try skill("a").enabled && !skill("b").enabled)
            try package("2.0.0")
            model.reload()
            check("new installed version replaces old rows", try plugin().version == "2.0.0" && model.items.filter { $0.pluginID != nil }.count == 2)
            check("individual off choice survives the update", try !skill("b").enabled)
            model.toggle(try skill("b"))
            check("updated skill can be enabled again", try skill("b").enabled)
            let reloaded = InventoryScanner(paths: paths).scanAll()
            check("fresh provider process sees the restored choices", reloaded.diagnostics.isEmpty && reloaded.items.filter { $0.pluginID != nil }.allSatisfy(\.enabled))
            let after = try String(contentsOf: paths.codexConfig, encoding: .utf8)
            check("native TOML editor preserves comments and unrelated values", after.contains("# Keep this comment") && after.contains("model = \"fixture-model\""))
            check("Codex writes never create Claude settings", !fm.fileExists(atPath: paths.localSettings.path))
            check("configuration writes are backed up", !Backups(paths: paths).listSnapshots().isEmpty)
            let blocker = root.appendingPathComponent("blocked-backups")
            try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
            let blockedPaths = Paths(home: root, support: blocker, codexExecutable: executable)
            var backupRefused = false
            do { try Mutations(paths: blockedPaths).setPlugin(try plugin(), enabled: false) }
            catch { backupRefused = true }
            let afterRefusal = try String(contentsOf: paths.codexConfig, encoding: .utf8)
            check("backup failure prevents a configuration write", backupRefused && afterRefusal == after)
            try "[broken".write(to: paths.codexConfig, atomically: true, encoding: .utf8)
            model.togglePlugin(try plugin())
            check("malformed configuration is refused without replacement", try String(contentsOf: paths.codexConfig, encoding: .utf8) == "[broken")
        } catch {
            check(error.localizedDescription, false)
        }
        try? fm.removeItem(at: root)
        print("Codex integration: \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }
}
