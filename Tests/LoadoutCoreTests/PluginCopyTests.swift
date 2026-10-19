import XCTest
@testable import LoadoutCore

/// A plugin's skills are read-only and live in a cache an update replaces, so they cannot be
/// shared. A personal copy is the way to share one.
final class PluginCopyTests: XCTestCase {
    let fm = FileManager.default

    func fixtureWithPlugin() throws -> (Fixture, Mutations, InventoryScanner) {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["deploy-helper"], commands: ["ship-it"])
        let plugin = InventoryScanner(paths: fixture.paths).installedPlugins().first!
        let agents = plugin.installPath.appendingPathComponent("agents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try "---\nname: deployer\ndescription: Deploys.\n---\n".write(
            to: agents.appendingPathComponent("deployer.md"), atomically: true, encoding: .utf8
        )
        // A file beside the skill, which has to travel with it.
        try "echo hi".write(
            to: plugin.installPath.appendingPathComponent("skills/deploy-helper/run.sh"), atomically: true, encoding: .utf8
        )
        return (fixture, Mutations(paths: fixture.paths), InventoryScanner(paths: fixture.paths))
    }

    func pluginItem(_ name: String, _ kind: ItemKind, _ scanner: InventoryScanner) -> Item {
        scanner.scanAll().items.first { $0.name == name && $0.kind == kind && !$0.origin.isEditable }!
    }

    func testAPluginSkillIsCopiedWholeAndThePluginKeepsItsOwn() throws {
        let (fixture, mutations, scanner) = try fixtureWithPlugin()
        let skill = pluginItem("deploy-helper", .skill, scanner)

        XCTAssertFalse(mutations.hasGlobalCopy(of: skill))
        try mutations.makeGlobal(skill)

        XCTAssertTrue(fixture.exists(fixture.paths.skills.appendingPathComponent("deploy-helper/SKILL.md")))
        XCTAssertTrue(fixture.exists(fixture.paths.skills.appendingPathComponent("deploy-helper/run.sh")), "the folder travels whole")
        XCTAssertTrue(fixture.exists(skill.directory!.appendingPathComponent("SKILL.md")), "the plugin's own is untouched")
        XCTAssertTrue(mutations.hasGlobalCopy(of: skill), "so the button can stop being offered")
        XCTAssertThrowsError(try mutations.makeGlobal(skill), "a second copy never overwrites the first")
    }

    func testAPluginCommandAndSubagentLandInTheirOwnFolders() throws {
        let (fixture, mutations, scanner) = try fixtureWithPlugin()

        try mutations.makeGlobal(pluginItem("ship-it", .command, scanner))
        try mutations.makeGlobal(pluginItem("deployer", .agent, scanner))

        XCTAssertTrue(fixture.exists(fixture.paths.commands.appendingPathComponent("ship-it.md")))
        XCTAssertTrue(fixture.exists(fixture.paths.agents.appendingPathComponent("deployer.md")))
    }

    func testTheCopyIsPersonalSoItCanBeSharedWithAnotherAssistant() throws {
        let (fixture, mutations, scanner) = try fixtureWithPlugin()
        try fm.createDirectory(at: fixture.paths.home.appendingPathComponent(".zzz/skills"), withIntermediateDirectories: true)
        let zzz = AssistantRegistry.discover(paths: fixture.paths).first { $0.id == "zzz" }!
        try mutations.makeGlobal(pluginItem("deploy-helper", .skill, scanner))
        let mine = InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.name == "deploy-helper" && $0.origin == .personal }!

        XCTAssertThrowsError(try mutations.share(pluginItem("deploy-helper", .skill, scanner), with: zzz), "the plugin's own still cannot")
        try mutations.share(mine, with: zzz)

        XCTAssertEqual(
            InventoryScanner(paths: fixture.paths).scanAll().items
                .first { $0.name == "deploy-helper" && $0.origin == .personal }?.assistants,
            ["claude", "zzz"]
        )
    }

    func testSomethingAlreadyYoursIsNotCopyable() {
        XCTAssertFalse(Origin.personal.isCopyable)
        XCTAssertTrue(Origin.plugin("x").isCopyable)
        XCTAssertTrue(Origin.project("x").isCopyable)
    }
}

/// Taking back a personal copy.
extension PluginCopyTests {
    func testRemovingMyCopyTakesItAndItsLinksAndLeavesThePluginsOwn() throws {
        let (fixture, mutations, scanner) = try fixtureWithPlugin()
        try fm.createDirectory(at: fixture.paths.home.appendingPathComponent(".zzz/skills"), withIntermediateDirectories: true)
        let zzz = AssistantRegistry.discover(paths: fixture.paths).first { $0.id == "zzz" }!
        let theirs = pluginItem("deploy-helper", .skill, scanner)
        try mutations.makeGlobal(theirs)
        let mine = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.name == "deploy-helper" && $0.origin == .personal }!
        try mutations.share(mine, with: zzz)

        let report = try mutations.removeGlobalCopy(of: theirs)

        XCTAssertFalse(mutations.hasGlobalCopy(of: theirs), "so the button reads Make personal copy again")
        XCTAssertFalse(fixture.exists(fixture.paths.skills.appendingPathComponent("deploy-helper")))
        XCTAssertNil(try? fm.attributesOfItem(atPath: zzz.skillsRoot.appendingPathComponent("deploy-helper").path), "no dangling link")
        XCTAssertFalse(report.links.isEmpty)
        XCTAssertTrue(fixture.exists(theirs.directory!.appendingPathComponent("SKILL.md")), "the plugin's own is untouched")
    }

    func testThereIsNothingToTakeBackBeforeACopyIsMade() throws {
        let (fixture, mutations, scanner) = try fixtureWithPlugin()

        XCTAssertThrowsError(try mutations.removeGlobalCopy(of: pluginItem("ship-it", .command, scanner)))
        withExtendedLifetime(fixture) {}
    }
}
