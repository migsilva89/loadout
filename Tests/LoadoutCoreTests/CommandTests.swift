import XCTest
@testable import LoadoutCore

/// AC10 — commands brought up to what skills already do: an honest warning, a switch, creation,
/// and the other assistants' halves of the collection.
final class CommandTests: XCTestCase {
    private let fm = FileManager.default

    private func command(_ name: String, in fixture: Fixture, frontmatter: String? = nil) {
        try! fm.createDirectory(at: fixture.paths.commands, withIntermediateDirectories: true)
        let text = frontmatter ?? "---\ndescription: Faz uma coisa.\nargument-hint: [ficheiro]\n---\n\nCorpo."
        try! text.write(
            to: fixture.paths.commands.appendingPathComponent("\(name).md"),
            atomically: true, encoding: .utf8
        )
    }

    private func codexPrompt(_ name: String, in fixture: Fixture) {
        let root = fixture.paths.home.appendingPathComponent(".codex/prompts")
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        try! "---\ndescription: Do Codex.\n---\n\nCorpo.".write(
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

        XCTAssertNil(item("imark-review", in: fixture).warning, "um command chama-se pelo ficheiro")
    }

    func testAnUnreadableFrontmatterStillWarnsAndStillLists() {
        let fixture = Fixture()
        command("partido", in: fixture, frontmatter: "---\ndescription: Sem fecho.\n\nCorpo.")

        let broken = item("partido", in: fixture)
        XCTAssertNotNil(broken.warning)
        XCTAssertEqual(broken.name, "partido", "continua listado")
    }

    func testASkillIsStillHeldToItsOwnFieldRules() {
        let fixture = Fixture()
        fixture.rawSkill("sem-nome", contents: "---\ndescription: Só descrição.\n---\n\nCorpo.")

        let skill = InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.kind == .skill && $0.name == "sem-nome" }!
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
        XCTAssertFalse(parked.enabled, "continua na lista, desligado")

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
        try "---\ndescription: Do repo.\n---\n".write(
            to: commands.appendingPathComponent("deploy.md"), atomically: true, encoding: .utf8
        )
        fixture.projectsIndex("| Caminho | Descrição |\n|---|---|\n| `APPS/loadout` | A app |")
        let project = ProjectsIndex(paths: fixture.paths).load().first!
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
            "um command não se disfarça de skill no registo"
        )

        // A versão nova chega limpa, sem saber do que foi desligado.
        let fresh = plugin.installPath.appendingPathComponent("commands/status.md")
        try fm.createDirectory(
            at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "---\ndescription: Nova.\n---\n".write(to: fresh, atomically: true, encoding: .utf8)
        try fm.removeItem(at: plugin.installPath.appendingPathComponent("commands-off/status.md"))

        XCTAssertEqual(mutations.reapplyDisabledSkills(of: plugin), ["status.md"])
        XCTAssertFalse(fixture.exists(fresh), "voltou a sair do sítio que o Claude lê")
    }

    // MARK: - AC10.9 creating one

    func testCreatingACommandWritesATemplateAndRefusesToOverwrite() throws {
        let fixture = Fixture()
        let mutations = Mutations(paths: fixture.paths)

        let file = try mutations.createCommand(name: "deploy", description: "Põe isto no ar.")

        let text = fixture.read(file)
        XCTAssertTrue(text.contains("description: Põe isto no ar."))
        XCTAssertFalse(text.contains("name:"), "um command não leva campo name")
        XCTAssertEqual(item("deploy", in: fixture).description, "Põe isto no ar.")

        XCTAssertThrowsError(try mutations.createCommand(name: "deploy", description: "Outra"))
        XCTAssertThrowsError(try mutations.createCommand(name: "Não Válido", description: ""))
    }

    // MARK: - AC10.11 / AC10.13 the other assistants

    func testCodexPromptsAreInventoriedAndMergedByName() {
        let fixture = Fixture()
        command("nos-dois", in: fixture)
        codexPrompt("nos-dois", in: fixture)
        codexPrompt("so-no-codex", in: fixture)

        let commands = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .command }

        XCTAssertEqual(commands.map(\.name).sorted(), ["nos-dois", "so-no-codex"])
        XCTAssertEqual(item("nos-dois", in: fixture).assistants, ["claude", "codex"])
        XCTAssertEqual(item("so-no-codex", in: fixture).assistants, ["codex"])
    }

    func testAnAssistantWithNoPromptsDirectoryIsNotAnError() {
        let fixture = Fixture()
        command("sozinho", in: fixture)

        let commands = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .command }

        XCTAssertEqual(commands.map(\.name), ["sozinho"])
    }

    func testSharingACommandLinksItRatherThanCopyingIt() throws {
        let fixture = Fixture()
        command("nos-dois", in: fixture)
        try fm.createDirectory(
            at: fixture.paths.home.appendingPathComponent(".codex/prompts"),
            withIntermediateDirectories: true
        )
        let codex = AssistantRegistry.discover(paths: fixture.paths).first { $0.id == "codex" }!
        let mutations = Mutations(paths: fixture.paths)

        let link = try mutations.shareCommand(item("nos-dois", in: fixture), with: codex)

        XCTAssertEqual(
            (try? fm.attributesOfItem(atPath: link.path)[.type]) as? FileAttributeType,
            .typeSymbolicLink,
            "um ficheiro, uma edição"
        )
        XCTAssertEqual(item("nos-dois", in: fixture).assistants, ["claude", "codex"])

        try mutations.unshareCommand(item("nos-dois", in: fixture), from: codex)
        XCTAssertEqual(item("nos-dois", in: fixture).assistants, ["claude"])
    }
}

/// Taking something out of a repository and making it yours everywhere.
extension CommandTests {

    private func projectFixture() -> (Fixture, Project, InventoryScanner, Mutations) {
        let fixture = Fixture()
        let repo = fixture.projectRepo("APPS/loadout", skills: ["do-repo"])
        let commands = repo.appendingPathComponent(".claude/commands")
        try! fm.createDirectory(at: commands, withIntermediateDirectories: true)
        try! "---\ndescription: Do repo.\n---\n\nCorpo.".write(
            to: commands.appendingPathComponent("deploy.md"), atomically: true, encoding: .utf8
        )
        fixture.projectsIndex("| Caminho | Descrição |\n|---|---|\n| `APPS/loadout` | A app |")
        let project = ProjectsIndex(paths: fixture.paths).load().first!
        return (fixture, project, InventoryScanner(paths: fixture.paths), Mutations(paths: fixture.paths))
    }

    func testMakingAProjectSkillGlobalCopiesItAndLeavesTheProjectsOwn() throws {
        let (fixture, project, scanner, mutations) = projectFixture()
        let skill = scanner.scanAll(project: project).items.first { $0.name == "do-repo" }!

        try mutations.makeGlobal(skill)

        XCTAssertTrue(fixture.exists(fixture.paths.skills.appendingPathComponent("do-repo/SKILL.md")),
                      "passou a ser tua, em todo o lado")
        XCTAssertTrue(
            fixture.exists(project.path.appendingPathComponent(".claude/skills/do-repo/SKILL.md")),
            "e a do repositório fica — ninguém perde nada no próximo pull"
        )
        XCTAssertEqual(
            scanner.scanAll().items.filter { $0.kind == .skill && $0.name == "do-repo" }.count, 1
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
        fixture.skill("do-repo", description: "A minha, diferente.")
        let skill = scanner.scanAll(project: project).items.first { $0.name == "do-repo" }!

        XCTAssertThrowsError(try mutations.makeGlobal(skill))
        XCTAssertEqual(
            Frontmatter.parse(fixture.read(fixture.paths.skills.appendingPathComponent("do-repo/SKILL.md"))).description,
            "A minha, diferente.",
            "a que já era tua não foi tocada"
        )
    }

    func testAGlobalOneCannotBeMadeGlobal() {
        let fixture = Fixture()
        fixture.skill("minha")
        let mutations = Mutations(paths: fixture.paths)
        let mine = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.name == "minha" }!

        XCTAssertThrowsError(try mutations.makeGlobal(mine))
    }
}
