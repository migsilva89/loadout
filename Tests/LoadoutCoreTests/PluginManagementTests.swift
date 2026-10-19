import XCTest
@testable import LoadoutCore

/// Installing, updating and removing plugins. Nothing here runs an assistant: commands are built
/// and checked as data, and the three scanners read fixtures.
final class PluginManagementTests: XCTestCase {
    private let fm = FileManager.default

    private func service(_ fixture: Fixture, tools: Set<String> = ["claude", "opencode"]) -> PluginService {
        let paths = Paths(home: fixture.root, codexExecutable: tools.contains("codex") ? URL(fileURLWithPath: "/usr/bin/codex") : nil)
        return PluginService(paths: paths) { tools.contains($0) ? URL(fileURLWithPath: "/usr/local/bin/\($0)") : nil }
    }

    // MARK: - Commands

    func testClaudeCommandsAreBuiltAsArgumentListsNeverShellStrings() throws {
        let fixture = Fixture()
        let install = try service(fixture).installCommand(spec: "vercel@claude-plugins-official", assistant: "claude")

        XCTAssertEqual(install.arguments, ["plugin", "install", "vercel@claude-plugins-official"])
        XCTAssertEqual(install.display, "claude plugin install vercel@claude-plugins-official")
    }

    func testTypedTextCannotBecomeAFlagOrASecondCommand() {
        let fixture = Fixture()
        let service = service(fixture)
        for bad in ["--scope=user", "-y", "a b", "name@", "@market", "x;rm -rf ~", "a@b@c", "", "name\nname"] {
            XCTAssertThrowsError(try service.installCommand(spec: bad, assistant: "claude"), bad)
        }
        for bad in ["--wizard", "", "two words", "pkg\n--x"] {
            XCTAssertThrowsError(try service.installCommand(spec: bad, assistant: "opencode"), bad)
        }
    }

    func testOpencodeAcceptsNpmNamesVersionsAndGitUrls() throws {
        let fixture = Fixture()
        let service = service(fixture)
        for good in ["opencode-wakatime", "@scope/pkg@1.2.3", "superpowers@git+https://github.com/obra/superpowers.git"] {
            XCTAssertEqual(try service.installCommand(spec: good, assistant: "opencode").arguments, ["plugin", "add", good])
        }
    }

    func testAnAssistantThatIsNotInstalledCannotBeManaged() {
        let fixture = Fixture()
        let service = service(fixture, tools: ["claude"])

        XCTAssertFalse(service.canManage("opencode"))
        XCTAssertFalse(service.canManage("codex"))
        XCTAssertThrowsError(try service.installCommand(spec: "pkg", assistant: "opencode"))
    }

    func testUpdateAndRemoveUseTheEntryOpencodeHolds() throws {
        let fixture = Fixture()
        let plugin = PluginInfo(
            id: "opencode:superpowers@git+https://x/y.git", name: "superpowers", marketplace: "git", version: "",
            installPath: fixture.root, enabled: true, assistant: "opencode",
            nativeKey: "superpowers@git+https://x/y.git"
        )
        let service = service(fixture)

        XCTAssertEqual(try service.updateCommand(for: plugin).arguments, ["plugin", "update", "superpowers@git+https://x/y.git"])
        XCTAssertEqual(try service.removeCommand(for: plugin).arguments, ["plugin", "remove", "superpowers@git+https://x/y.git"])
    }

    func testALocalPluginFileHasNothingToUpdate() {
        let fixture = Fixture()
        let local = PluginInfo(
            id: "opencode:local:a.js", name: "a", marketplace: "a file on this machine", version: "local",
            installPath: fixture.root, enabled: true, assistant: "opencode", nativeKey: "local:a.js"
        )

        XCTAssertThrowsError(try service(fixture).updateCommand(for: local))
    }

    func testClaudeUpdateNamesThePluginByItsRegisterKey() throws {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["a"])
        let plugin = InventoryScanner(paths: fixture.paths).installedPlugins().first!

        XCTAssertEqual(try service(fixture).updateCommand(for: plugin).arguments, ["plugin", "update", "vercel@official"])
    }

    func testMarketplaceSourcesAreCheckedToo() throws {
        let fixture = Fixture()
        let service = service(fixture)

        XCTAssertEqual(try service.marketplaceCommand(source: "owner/repo").arguments, ["plugin", "marketplace", "add", "owner/repo"])
        XCTAssertThrowsError(try service.marketplaceCommand(source: "--help"))
    }

    // MARK: - Catalogue

    func testTheClaudeCatalogueIsBusiestFirstAndKnowsWhatIsInstalled() throws {
        let json = """
        warning: something printed first
        {"installed":[{"id":"b@m"}],"available":[
          {"pluginId":"a@m","name":"a","description":"First.","marketplaceName":"m","installCount":5},
          {"pluginId":"b@m","name":"b","description":"Second.","marketplaceName":"m","installCount":50},
          {"pluginId":"c@m","name":"c","marketplaceName":"m"}]}
        """

        let entries = try PluginService.parseClaudeCatalog(json)

        XCTAssertEqual(entries.map(\.spec), ["b@m", "a@m", "c@m"])
        XCTAssertEqual(entries.map(\.installed), [true, false, false])
        XCTAssertEqual(entries[1].summary, "First.")
    }

    func testAnUnreadableCatalogueSaysSoInsteadOfShowingNothing() {
        XCTAssertThrowsError(try PluginService.parseClaudeCatalog("not json"))
    }

    // MARK: - opencode's plugins

    private func opencodeConfig(_ fixture: Fixture, _ plugins: [Any]) {
        try! fm.createDirectory(at: fixture.paths.opencodeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        fixture.write(json: ["plugin": plugins], to: fixture.paths.opencodeConfig)
    }

    func testPluginNamesAreReadOutOfEverySpecShape() {
        XCTAssertEqual(OpenCodePlugins.name(of: "pkg"), "pkg")
        XCTAssertEqual(OpenCodePlugins.name(of: "pkg@1.2.3"), "pkg")
        XCTAssertEqual(OpenCodePlugins.name(of: "@scope/pkg"), "@scope/pkg")
        XCTAssertEqual(OpenCodePlugins.name(of: "@scope/pkg@2"), "@scope/pkg")
        XCTAssertEqual(OpenCodePlugins.name(of: "superpowers@git+https://github.com/obra/superpowers.git"), "superpowers")
        XCTAssertEqual(OpenCodePlugins.name(of: "git+https://github.com/obra/tool.git"), "tool")
        XCTAssertEqual(OpenCodePlugins.pinnedVersion(of: "pkg@1.2.3"), "1.2.3")
        XCTAssertNil(OpenCodePlugins.pinnedVersion(of: "pkg@latest"))
        XCTAssertNil(OpenCodePlugins.pinnedVersion(of: "pkg@git+https://x/y.git"))
    }

    func testOpencodeListsItsPackagesAndItsScriptsAndCannotSwitchThemOff() throws {
        let fixture = Fixture()
        opencodeConfig(fixture, ["pkg@1.0.0", ["with-options", ["flag": true]], "pkg@1.0.0"])
        let home = fixture.paths.opencodeConfig.deletingLastPathComponent()
        try fm.createDirectory(at: home.appendingPathComponent("plugins/folder-plugin"), withIntermediateDirectories: true)
        try "export default {}".write(to: home.appendingPathComponent("plugins/status.js"), atomically: true, encoding: .utf8)
        try "notes".write(to: home.appendingPathComponent("plugins/README.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: home.appendingPathComponent("node_modules/with-options"), withIntermediateDirectories: true)
        try #"{"version":"3.4.5"}"#.write(to: home.appendingPathComponent("node_modules/with-options/package.json"), atomically: true, encoding: .utf8)

        let plugins = OpenCodePlugins(paths: fixture.paths).scan()

        XCTAssertEqual(plugins.map(\.name), ["pkg", "with-options", "folder-plugin", "status"], "no duplicate, no readme")
        XCTAssertEqual(plugins.first { $0.name == "pkg" }?.version, "1.0.0")
        XCTAssertEqual(plugins.first { $0.name == "with-options" }?.version, "3.4.5", "read from what is installed")
        XCTAssertTrue(plugins.allSatisfy { $0.assistant == "opencode" && $0.toggleUnavailableReason != nil })
        XCTAssertEqual(plugins.first { $0.name == "status" }?.nativeKey, "local:status.js")
        XCTAssertThrowsError(try Mutations(paths: fixture.paths).setPlugin(plugins[0], enabled: false))
    }

    func testOpencodePluginsJoinTheInventory() {
        let fixture = Fixture()
        opencodeConfig(fixture, ["pkg@1.0.0"])

        let inventory = InventoryScanner(paths: fixture.paths).scanAll()

        XCTAssertEqual(inventory.plugins.map(\.id), ["opencode:pkg@1.0.0"])
        XCTAssertEqual(inventory.plugins.first?.assistantLabel, "opencode")
    }

    func testRemovingALocalOpencodePluginMovesAFileOfYoursToTheTrashAndNothingElse() throws {
        let fixture = Fixture()
        let home = fixture.paths.opencodeConfig.deletingLastPathComponent()
        try fm.createDirectory(at: home.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        let file = home.appendingPathComponent("plugins/status.js")
        try "export default {}".write(to: file, atomically: true, encoding: .utf8)
        let outside = fixture.root.appendingPathComponent("precious.js")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        let service = service(fixture)
        let local = OpenCodePlugins(paths: fixture.paths).scan().first!
        var forged = local
        forged.installPath = outside

        XCTAssertThrowsError(try service.removeOpenCode(forged), "a path outside opencode's folder is refused")
        XCTAssertTrue(fixture.exists(outside))

        _ = try service.removeOpenCode(local)
        XCTAssertFalse(fixture.exists(file))
    }

    // MARK: - Codex

    func testCodexInstallNeedsTheMarketplaceLocationItWasGiven() throws {
        XCTAssertEqual(
            try CodexPlugins.installParams(pluginName: "kit", marketplacePath: "/m") as? [String: String],
            ["marketplacePath": "/m", "pluginName": "kit"]
        )
        XCTAssertThrowsError(try CodexPlugins.installParams(pluginName: "kit", marketplacePath: nil))
        XCTAssertThrowsError(try CodexPlugins.installParams(pluginName: "kit", marketplacePath: ""))
    }

    func testCodexUninstallNamesThePluginByItsNativeKey() {
        let plugin = PluginInfo(
            id: "codex:kit@test", name: "kit", marketplace: "test", version: "1", installPath: URL(fileURLWithPath: "/"),
            enabled: true, assistant: "codex", nativeKey: "kit@test"
        )

        XCTAssertEqual(CodexPlugins.uninstallParams(for: plugin)["pluginId"] as? String, "kit@test")
    }

    func testTheCodexCatalogueListsInstalledAndAvailablePluginsAlike() {
        let marketplaces: [[String: Any]] = [[
            "name": "test", "path": "/m",
            "plugins": [
                ["id": "b@test", "name": "b", "installed": false, "interface": ["shortDescription": "Bee."]],
                ["id": "a@test", "name": "a", "installed": true],
            ],
        ]]

        let entries = CodexPlugins.catalog(from: marketplaces)

        XCTAssertEqual(entries.map(\.name), ["a", "b"])
        XCTAssertEqual(entries.map(\.installed), [true, false])
        XCTAssertEqual(entries[1].summary, "Bee.")
        XCTAssertEqual(entries[1].marketplacePath, "/m")
    }

    func testAnUnmanagedCodexUpdateIsNotAttemptedWithoutCodex() {
        let fixture = Fixture()
        let plugin = PluginInfo(
            id: "codex:kit@test", name: "kit", marketplace: "test", version: "1", installPath: fixture.root,
            enabled: true, assistant: "codex", nativeKey: "kit@test"
        )

        XCTAssertThrowsError(try service(fixture, tools: ["claude"]).update(plugin))
    }
}
