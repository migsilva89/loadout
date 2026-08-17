import XCTest
@testable import LoadoutCore

/// AC10 — commands brought up to what skills already do: an honest warning, a switch, creation,
/// and the other assistants' halves of the collection.
final class CommandTests: XCTestCase {
    private let fm = FileManager.default

    private func command(_ name: String, in fixture: Fixture, frontmatter: String? = nil) {
        try! fm.createDirectory(at: fixture.paths.commands, withIntermediateDirectories: true)
        let text = frontmatter ?? "---\ndescription: Does a thing.\nargument-hint: [file]\n---\n\nBody."
        try! text.write(
            to: fixture.paths.commands.appendingPathComponent("\(name).md"),
            atomically: true, encoding: .utf8
        )
    }

    private func codexPrompt(_ name: String, in fixture: Fixture) {
        let root = fixture.paths.home.appendingPathComponent(".codex/prompts")
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        try! "---\ndescription: From Codex.\n---\n\nBody.".write(
            to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8
        )
    }

    private func item(_ name: String, in fixture: Fixture) -> Item {
        InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.kind == .command && $0.name == name }!
    }

    // MARK: - AC10.1 / AC10.2 the warning that was always wrong

    func testACommandWithoutANameFieldDoesNotWarn() {
        let fixture = Fixture()
        command("imark-review", in: fixture)

        XCTAssertNil(item("imark-review", in: fixture).warning, "a command is called by its file")
    }

    func testAnUnreadableFrontmatterStillWarnsAndStillLists() {
        let fixture = Fixture()
        command("broken", in: fixture, frontmatter: "---\ndescription: No closing fence.\n\nBody.")

        let broken = item("broken", in: fixture)
        XCTAssertNotNil(broken.warning)
        XCTAssertEqual(broken.name, "broken", "it stays listed")
    }

    func testASkillIsStillHeldToItsOwnFieldRules() {
        let fixture = Fixture()
        fixture.rawSkill("nameless", contents: "---\ndescription: Description only.\n---\n\nBody.")

        let skill = InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.kind == .skill && $0.name == "nameless" }!
        XCTAssertEqual(skill.warning, "The frontmatter is missing the name field.")
    }

    // MARK: - AC10.5 / AC10.6 the switch

    func testDisablingACommandMovesItNextDoorAndKeepsItListed() throws {
        let fixture = Fixture()
        command("imark-review", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.setCommand(item("imark-review", in: fixture), enabled: false)

        XCTAssertTrue(fixture.exists(
            fixture.paths.claude.appendingPathComponent("commands-off/imark-review.md")
        ))
        XCTAssertFalse(fixture.exists(
            fixture.paths.commands.appendingPathComponent("imark-review.md")
        ))
        let parked = item("imark-review", in: fixture)
        XCTAssertFalse(parked.enabled, "still in the list, switched off")

        try mutations.setCommand(parked, enabled: true)
        XCTAssertTrue(fixture.exists(
            fixture.paths.commands.appendingPathComponent("imark-review.md")
        ))
    }

    func testAProjectCommandParksInsideItsRepository() throws {
        let fixture = Fixture()
        let repo = fixture.projectRepo("APPS/loadout")
        let commands = repo.appendingPathComponent(".claude/commands")
        try fm.createDirectory(at: commands, withIntermediateDirectories: true)
        try "---\ndescription: From the repo.\n---\n".write(
            to: commands.appendingPathComponent("deploy.md"), atomically: true, encoding: .utf8
        )
        let project = ProjectRoots(folders: [fixture.paths.projectsRoot])
            .discover(home: fixture.paths.home).first!
        let scanner = InventoryScanner(paths: fixture.paths)
        let mutations = Mutations(paths: fixture.paths)

        let deploy = scanner.scanAll(project: project).items.first { $0.name == "deploy" }!
        try mutations.setCommand(deploy, enabled: false)

        XCTAssertTrue(fixture.exists(repo.appendingPathComponent(".claude/commands-off/deploy.md")))
        XCTAssertFalse(scanner.scanAll(project: project).items.first { $0.name == "deploy" }!.enabled)
    }

    // MARK: - AC10.7 a plugin's commands survive an update

    func testAPluginCommandIsRecordedAndReappliedAfterAnUpdate() throws {
        let fixture = Fixture()
        fixture.plugin("codex", marketplace: "official", skills: ["rescue"], commands: ["status"])
        let scanner = InventoryScanner(paths: fixture.paths)
        let mutations = Mutations(paths: fixture.paths)
        let plugin = scanner.installedPlugins().first!

        try mutations.setCommand(item("status", in: fixture), enabled: false, plugin: plugin)

        XCTAssertTrue(fixture.exists(
            plugin.installPath.appendingPathComponent("commands-off/status.md")
        ))
        XCTAssertEqual(mutations.records.pluginEntries(of: plugin.id), ["commands/status.md"])
        XCTAssertTrue(
            mutations.records.pluginSkills(of: plugin.id).isEmpty,
            "a command does not pass itself off as a skill in the record"
        )

        // The new version arrives clean, knowing nothing of what was switched off.
        let fresh = plugin.installPath.appendingPathComponent("commands/status.md")
        try fm.createDirectory(
            at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "---\ndescription: New.\n---\n".write(to: fresh, atomically: true, encoding: .utf8)
        try fm.removeItem(at: plugin.installPath.appendingPathComponent("commands-off/status.md"))

        XCTAssertEqual(mutations.reapplyDisabledSkills(of: plugin), ["status.md"])
        XCTAssertFalse(fixture.exists(fresh), "it left the place Claude reads again")
    }

    // MARK: - AC10.9 creating one

    func testCreatingACommandWritesATemplateAndRefusesToOverwrite() throws {
        let fixture = Fixture()
        let mutations = Mutations(paths: fixture.paths)

        let file = try mutations.createCommand(name: "deploy", description: "Puts this on the air.")

        let text = fixture.read(file)
        XCTAssertTrue(text.contains("description: Puts this on the air."))
        XCTAssertFalse(text.contains("name:"), "a command carries no name field")
        XCTAssertEqual(item("deploy", in: fixture).description, "Puts this on the air.")

        XCTAssertThrowsError(try mutations.createCommand(name: "deploy", description: "Another"))
        XCTAssertThrowsError(try mutations.createCommand(name: "Not Valid", description: ""))
    }

    // MARK: - AC10.11 / AC10.13 the other assistants

    func testCodexPromptsAreInventoriedAndMergedByName() {
        let fixture = Fixture()
        command("on-both", in: fixture)
        codexPrompt("on-both", in: fixture)
        codexPrompt("codex-only", in: fixture)

        let commands = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .command }

        XCTAssertEqual(commands.map(\.name).sorted(), ["codex-only", "on-both"])
        XCTAssertEqual(item("on-both", in: fixture).assistants, ["claude", "codex"])
        XCTAssertEqual(item("codex-only", in: fixture).assistants, ["codex"])
    }

    func testAnAssistantWithNoPromptsDirectoryIsNotAnError() {
        let fixture = Fixture()
        command("alone", in: fixture)

        let commands = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .command }

        XCTAssertEqual(commands.map(\.name), ["alone"])
    }

    func testSharingACommandLinksItRatherThanCopyingIt() throws {
        let fixture = Fixture()
        command("on-both", in: fixture)
        try fm.createDirectory(
            at: fixture.paths.home.appendingPathComponent(".codex/prompts"),
            withIntermediateDirectories: true
        )
        let codex = AssistantRegistry.discover(paths: fixture.paths).first { $0.id == "codex" }!
        let mutations = Mutations(paths: fixture.paths)

        let link = try mutations.shareCommand(item("on-both", in: fixture), with: codex)

        XCTAssertEqual(
            (try? fm.attributesOfItem(atPath: link.path)[.type]) as? FileAttributeType,
            .typeSymbolicLink,
            "one file, one edit"
        )
        XCTAssertEqual(item("on-both", in: fixture).assistants, ["claude", "codex"])

        try mutations.unshareCommand(item("on-both", in: fixture), from: codex)
        XCTAssertEqual(item("on-both", in: fixture).assistants, ["claude"])
    }
}

/// Taking something out of a repository and making it yours everywhere.
extension CommandTests {

    private func projectFixture() -> (Fixture, Project, InventoryScanner, Mutations) {
        let fixture = Fixture()
        let repo = fixture.projectRepo("APPS/loadout", skills: ["from-repo"])
        let commands = repo.appendingPathComponent(".claude/commands")
        try! fm.createDirectory(at: commands, withIntermediateDirectories: true)
        try! "---\ndescription: From the repo.\n---\n\nBody.".write(
            to: commands.appendingPathComponent("deploy.md"), atomically: true, encoding: .utf8
        )
        let project = ProjectRoots(folders: [fixture.paths.projectsRoot])
            .discover(home: fixture.paths.home).first!
        return (fixture, project, InventoryScanner(paths: fixture.paths), Mutations(paths: fixture.paths))
    }

    func testMakingAProjectSkillGlobalCopiesItAndLeavesTheProjectsOwn() throws {
        let (fixture, project, scanner, mutations) = projectFixture()
        let skill = scanner.scanAll(project: project).items.first { $0.name == "from-repo" }!

        try mutations.makeGlobal(skill)

        XCTAssertTrue(fixture.exists(fixture.paths.skills.appendingPathComponent("from-repo/SKILL.md")),
                      "it became yours, everywhere")
        XCTAssertTrue(
            fixture.exists(project.path.appendingPathComponent(".claude/skills/from-repo/SKILL.md")),
            "and the repository's stays — nobody loses anything at the next pull"
        )
        XCTAssertEqual(
            scanner.scanAll().items.filter { $0.kind == .skill && $0.name == "from-repo" }.count, 1
        )
    }

    func testMakingAProjectCommandGlobalLandsInTheCommandsFolder() throws {
        let (fixture, project, scanner, mutations) = projectFixture()
        let command = scanner.scanAll(project: project).items.first { $0.name == "deploy" }!

        try mutations.makeGlobal(command)

        XCTAssertTrue(fixture.exists(fixture.paths.commands.appendingPathComponent("deploy.md")))
    }

    func testItRefusesRatherThanOverwriteOneYouAlreadyHave() throws {
        let (fixture, project, scanner, mutations) = projectFixture()
        fixture.skill("from-repo", description: "Mine, different.")
        let skill = scanner.scanAll(project: project).items.first { $0.name == "from-repo" }!

        XCTAssertThrowsError(try mutations.makeGlobal(skill))
        XCTAssertEqual(
            Frontmatter.parse(fixture.read(fixture.paths.skills.appendingPathComponent("from-repo/SKILL.md"))).description,
            "Mine, different.",
            "the one that was already yours was left alone"
        )
    }

    func testAGlobalOneCannotBeMadeGlobal() {
        let fixture = Fixture()
        fixture.skill("mine")
        let mutations = Mutations(paths: fixture.paths)
        let mine = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.name == "mine" }!

        XCTAssertThrowsError(try mutations.makeGlobal(mine))
    }
}
