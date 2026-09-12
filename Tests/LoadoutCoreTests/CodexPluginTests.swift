import XCTest
@testable import LoadoutCore

final class CodexPluginTests: XCTestCase {
    private func package(_ fixture: Fixture, version: String = "1.0.0", location: String = "skills") throws -> URL {
        let root = fixture.paths.codexPluginCache.appendingPathComponent("market/kit/\(version)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": "kit", "version": version, "skills": "./\(location)"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent(".codex-plugin/plugin.json"))
        for name in ["a", "b"] {
            let folder = root.appendingPathComponent("\(location)/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: From Codex.\n---\nBody".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func installed(enabled: Bool = true, version: String = "1.0.0", remote: Bool = false) -> [String: Any] {
        ["marketplaces": [["name": "market", "plugins": [[
            "id": "kit@market", "name": "kit", "installed": true, "enabled": enabled,
            "localVersion": version, "source": ["type": remote ? "remote" : "local"],
        ]]]], "marketplaceLoadErrors": []]
    }

    private func scan(_ fixture: Fixture, enabled: Bool = true, version: String = "1.0.0",
                      overrides: [[String: Any]] = [], native: [[String: Any]] = []) throws -> Inventory {
        try CodexPlugins(paths: fixture.paths).inventory(
            installed: installed(enabled: enabled, version: version),
            skills: ["data": [["skills": native]]],
            settings: ["config": ["skills": ["config": overrides]]])
    }

    func testCodexOnlyInstallationRemainsVisibleWithParentOffAndRestoresChoices() throws {
        let f = Fixture()
        let root = try package(f)
        let overrides: [[String: Any]] = [["path": root.appendingPathComponent("skills/b/SKILL.md").path, "enabled": false]]
        let on = try scan(f, overrides: overrides)
        let off = try scan(f, enabled: false, overrides: overrides)
        let restored = try scan(f, overrides: overrides)
        XCTAssertEqual(on.plugins.map(\.id), ["codex:kit@market"])
        XCTAssertEqual(off.items.count, 2)
        XCTAssertEqual(off.items.filter(\.enabled).map(\.name), ["a"])
        XCTAssertTrue(off.items.allSatisfy { !Filtering.isEffectivelyEnabled($0, disabledPluginIDs: ["codex:kit@market"]) })
        XCTAssertEqual(restored.items.filter(\.enabled).map(\.name), ["a"])
        XCTAssertTrue(restored.items.allSatisfy { $0.assistants == ["codex"] })
        XCTAssertEqual(on.items.map(\.id).sorted(), restored.items.map(\.id).sorted())
    }

    func testInstalledVersionAndManifestPathsWinOverNewerStaleCache() throws {
        let f = Fixture()
        let active = try package(f, location: "custom/nested")
        _ = try package(f, version: "99.0.0")
        let result = try scan(f)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.allSatisfy { $0.path!.path.contains("/1.0.0/custom/nested/") })
        XCTAssertEqual(result.plugins.first?.installPath.path, active.path)
        let empty = try CodexPlugins(paths: f.paths).inventory(installed: ["marketplaces": []], skills: ["data": []], settings: ["config": [:]])
        XCTAssertTrue(empty.items.isEmpty, "uninstalled packages left in cache are not installations")
    }

    func testNativeRuntimePathsAndManifestDoNotDuplicateRows() throws {
        let f = Fixture()
        let root = try package(f)
        let result = try scan(f, native: [["pluginId": "kit@market", "name": "kit:a", "enabled": true,
                                         "path": root.appendingPathComponent("skills/a/SKILL.md").path]])
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(Set(result.items.map(\.id)).count, 2)
    }

    func testProviderAndMarketplaceIdentitiesCannotCollide() throws {
        let f = Fixture()
        f.plugin("kit", marketplace: "market", skills: ["a"])
        f.plugin("kit", marketplace: "other", skills: ["a"])
        _ = try package(f)
        let claude = InventoryScanner(paths: f.paths).scanAll()
        let codex = try scan(f)
        let all = claude.items + codex.items
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set((claude.plugins + codex.plugins).map(\.id)).count, 3)
        let filtered = Filtering.filter(all, by: .one("codex"))
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { $0.pluginID == "codex:kit@market" })
    }

    func testNamedOverrideIsPreservedWhenParentIsDisabled() throws {
        let f = Fixture()
        _ = try package(f)
        let result = try scan(f, enabled: false, overrides: [["name": "kit:b", "enabled": false]])
        XCTAssertEqual(result.items.filter { !$0.enabled }.map(\.name), ["b"])
    }

    func testManagedPluginHasAnExplanationInsteadOfAnIneffectiveParentSwitch() throws {
        let f = Fixture()
        _ = try package(f)
        let result = try CodexPlugins(paths: f.paths).inventory(installed: installed(remote: true), skills: ["data": []], settings: ["config": [:]])
        let plugin = try XCTUnwrap(result.plugins.first)
        XCTAssertNotNil(plugin.toggleUnavailableReason)
        XCTAssertThrowsError(try Mutations(paths: f.paths).setPlugin(plugin, enabled: false))
        XCTAssertFalse(f.exists(f.paths.localSettings))
    }

    func testMalformedProtocolAndMissingPackageAreDiagnosed() throws {
        let f = Fixture()
        XCTAssertThrowsError(try CodexPlugins(paths: f.paths).inventory(installed: [:], skills: [:], settings: [:]))
        let result = try scan(f)
        XCTAssertFalse(result.diagnostics.isEmpty)
        XCTAssertNotNil(result.plugins.first?.toggleUnavailableReason)
    }

    func testManifestCannotEscapePackageOrFollowSymlinkCycle() throws {
        let f = Fixture()
        let root = try package(f)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("skills/loop"), withDestinationURL: root.appendingPathComponent("skills"))
        let outside = f.skill("outside")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("skills/outside"), withDestinationURL: outside)
        XCTAssertEqual(try CodexPlugins.manifestSkills(at: root).count, 2)
    }

    func testParentOffGuardsMutationsForEveryChildEntryPoint() throws {
        let f = Fixture()
        f.plugin("kit", skills: ["a"], commands: ["status"], enabled: false)
        let inventory = InventoryScanner(paths: f.paths).scanAll()
        let plugin = try XCTUnwrap(inventory.plugins.first)
        let skill = try XCTUnwrap(inventory.items.first { $0.kind == .skill })
        let command = try XCTUnwrap(inventory.items.first { $0.kind == .command })
        let mutations = Mutations(paths: f.paths)
        XCTAssertThrowsError(try mutations.disablePluginSkill(skill, in: plugin))
        XCTAssertThrowsError(try mutations.enablePluginSkill(skill, in: plugin))
        XCTAssertThrowsError(try mutations.setCommand(command, enabled: false, plugin: plugin))
        XCTAssertTrue(f.exists(skill.path!))
        XCTAssertTrue(f.exists(command.path!))
        XCTAssertTrue(mutations.records.pluginEntries().isEmpty)
    }

    func testCodexRecordsAreNeverReappliedAsClaudeFolderMoves() throws {
        let f = Fixture()
        let root = try package(f)
        let plugin = try XCTUnwrap(try scan(f).plugins.first)
        let mutations = Mutations(paths: f.paths)
        try mutations.records.rememberPluginEntry("skills/a/SKILL.md", in: plugin.id)
        XCTAssertEqual(mutations.reapplyDisabledSkills(of: plugin), [])
        XCTAssertTrue(f.exists(root.appendingPathComponent("skills/a/SKILL.md")))
    }

    func testProviderTimeoutIsBounded() throws {
        let f = Fixture()
        let executable = f.root.appendingPathComponent("codex")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let paths = Paths(home: f.root, codexExecutable: executable)
        let start = Date()
        XCTAssertThrowsError(try CodexConnection(paths: paths, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testProjectOverrideShowsEffectiveStateAndLocksParentSwitch() throws {
        let f = Fixture()
        _ = try package(f)
        let result = try CodexPlugins(paths: f.paths).inventory(installed: installed(), skills: ["data": []], settings: [
            "config": ["plugins": ["kit@market": ["enabled": false]]],
            "origins": ["plugins.\"kit@market\".enabled": ["name": ["type": "project"]]],
        ])
        XCTAssertEqual(result.plugins.first?.enabled, false)
        XCTAssertNotNil(result.plugins.first?.toggleUnavailableReason)
    }

    func testWatcherDetectsFirstConfigCreation() throws {
        let f = Fixture()
        let detected = expectation(description: "new Codex configuration")
        let config = f.paths.codexConfig
        let watcher = Watcher(coalescing: 0.05) {
            if FileManager.default.fileExists(atPath: config.path) { detected.fulfill() }
        }
        watcher.start(watching: [config])
        defer { watcher.stop() }
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# new config".write(to: config, atomically: true, encoding: .utf8)
        wait(for: [detected], timeout: 4)
    }

    func testCustomCodexHomeStillHasAnAssistantForItsPluginFilter() throws {
        let f = Fixture()
        let custom = f.root.appendingPathComponent("custom-codex")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let paths = Paths(home: f.root, codexHome: custom)
        let codex = try XCTUnwrap(AssistantRegistry.discover(paths: paths).first { $0.id == "codex" })
        XCTAssertEqual(codex.skillsRoot, paths.codexSkills)
        XCTAssertEqual(paths.skillsRoot(forAssistant: "codex"), paths.codexSkills)
    }
}
