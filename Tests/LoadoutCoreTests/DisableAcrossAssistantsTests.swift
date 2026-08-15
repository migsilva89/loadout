import XCTest
@testable import LoadoutCore

/// AC3.1–AC3.20 — the switch, once more than one assistant, a plugin or a repository is in play.
///
/// The bug these start from: disabling always parked the folder in `~/.claude/skills-off` and
/// enabling always brought it back to `~/.claude/skills`, so a Codex skill switched off and on
/// again quietly became a Claude skill and vanished from Codex.
final class DisableAcrossAssistantsTests: XCTestCase {
    private let fm = FileManager.default

    // MARK: - Fixtures

    private func skill(_ name: String, forAssistant id: String, in fixture: Fixture) {
        let folder = fixture.paths.skillsRoot(forAssistant: id).appendingPathComponent(name)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! "---\nname: \(name)\ndescription: Do \(id).\n---\n\nCorpo.".write(
            to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
    }

    /// The shape `share` leaves behind: one real folder in `~/.agents/skills`, a symlink per
    /// assistant pointing at it.
    private func sharedSkill(_ name: String, between ids: [String], in fixture: Fixture) {
        let canonical = fixture.paths.sharedSkills.appendingPathComponent(name)
        try! fm.createDirectory(at: canonical, withIntermediateDirectories: true)
        try! "---\nname: \(name)\ndescription: Partilhada.\n---\n\nCorpo.".write(
            to: canonical.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        for id in ids {
            let root = fixture.paths.skillsRoot(forAssistant: id)
            try! fm.createDirectory(at: root, withIntermediateDirectories: true)
            try! fm.createSymbolicLink(
                at: root.appendingPathComponent(name), withDestinationURL: canonical
            )
        }
    }

    private func item(_ name: String, in fixture: Fixture, enabled: Bool? = nil) -> Item {
        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        return items.first { $0.name == name && (enabled == nil || $0.enabled == enabled!) }!
    }

    private func assistants(_ fixture: Fixture) -> [Assistant] {
        AssistantRegistry.discover(paths: fixture.paths)
    }

    private func assistant(_ id: String, in fixture: Fixture) -> Assistant {
        assistants(fixture).first { $0.id == id }!
    }

    private func offRoot(_ id: String, in fixture: Fixture) -> URL {
        fixture.paths.home.appendingPathComponent(".\(id)/skills-off")
    }

    // MARK: - AC3.1 the folder stays with its owner

    func testACodexOnlySkillParksInCodexNotInClaude() throws {
        let fixture = Fixture()
        skill("so-do-codex", forAssistant: "codex", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(item("so-do-codex", in: fixture), assistants: assistants(fixture))

        XCTAssertTrue(fixture.exists(
            offRoot("codex", in: fixture).appendingPathComponent("so-do-codex/SKILL.md")
        ))
        XCTAssertFalse(
            fixture.exists(fixture.paths.skillsOff.appendingPathComponent("so-do-codex")),
            "não muda de dono a caminho do off"
        )
    }

    func testASharedSkillParksBesideTheSharedStore() throws {
        let fixture = Fixture()
        sharedSkill("partilhada", between: ["claude", "codex"], in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(item("partilhada", in: fixture), assistants: assistants(fixture))

        XCTAssertTrue(fixture.exists(
            fixture.paths.home.appendingPathComponent(".agents/skills-off/partilhada/SKILL.md")
        ))
    }

    // MARK: - AC3.2 off means off everywhere

    func testDisablingRemovesEveryLinkAndAsksNothing() throws {
        let fixture = Fixture()
        sharedSkill("partilhada", between: ["claude", "codex"], in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(item("partilhada", in: fixture), assistants: assistants(fixture))

        for id in ["claude", "codex"] {
            XCTAssertFalse(
                fixture.exists(
                    fixture.paths.skillsRoot(forAssistant: id).appendingPathComponent("partilhada")
                ),
                "\(id) deixou de a carregar"
            )
        }
        XCTAssertFalse(item("partilhada", in: fixture).enabled)
    }

    // MARK: - AC3.3 the off-record

    func testDisablingRecordsTheOwnerAndWhoWasLoadingIt() throws {
        let fixture = Fixture()
        sharedSkill("partilhada", between: ["claude", "codex"], in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(item("partilhada", in: fixture), assistants: assistants(fixture))

        let entry = mutations.records.entry(named: "partilhada")
        XCTAssertEqual(entry?.owner, OffRecords.sharedOwner)
        XCTAssertEqual(entry?.assistants.sorted(), ["claude", "codex"])
    }

    // MARK: - AC3.4 nothing is destroyed

    func testDisablingRefusesWhenSomethingIsAlreadyParkedThere() {
        let fixture = Fixture()
        skill("dupla", forAssistant: "codex", in: fixture)
        let parked = offRoot("codex", in: fixture).appendingPathComponent("dupla")
        try! fm.createDirectory(at: parked, withIntermediateDirectories: true)
        try! "---\nname: dupla\ndescription: Velha.\n---\n".write(
            to: parked.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let mutations = Mutations(paths: fixture.paths)
        let live = item("dupla", in: fixture, enabled: true)

        XCTAssertThrowsError(try mutations.disableSkill(live, assistants: assistants(fixture)))
        XCTAssertTrue(
            fixture.exists(
                fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("dupla/SKILL.md")
            ),
            "a viva ficou onde estava"
        )
    }

    // MARK: - AC3.6 / AC3.7 coming back

    func testEnablingIntoOneAssistantLeavesNoLinksBehind() throws {
        let fixture = Fixture()
        skill("so-do-codex", forAssistant: "codex", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(item("so-do-codex", in: fixture), assistants: assistants(fixture))

        try mutations.enableSkill(
            item("so-do-codex", in: fixture),
            into: [assistant("codex", in: fixture)],
            assistants: assistants(fixture)
        )

        XCTAssertTrue(fixture.exists(
            fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("so-do-codex/SKILL.md")
        ))
        XCTAssertFalse(
            fixture.exists(fixture.paths.skills.appendingPathComponent("so-do-codex")),
            "não aparece no Claude por ter passado por lá"
        )
    }

    func testEnablingIntoSeveralUsesTheSharedStoreAndLinks() throws {
        let fixture = Fixture()
        skill("a-duplicar", forAssistant: "claude", in: fixture)
        // O Codex está instalado nesta máquina, ainda que sem skills próprias.
        try! fm.createDirectory(
            at: fixture.paths.skillsRoot(forAssistant: "codex"), withIntermediateDirectories: true
        )
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(item("a-duplicar", in: fixture), assistants: assistants(fixture))

        try mutations.enableSkill(
            item("a-duplicar", in: fixture),
            into: assistants(fixture).filter { ["claude", "codex"].contains($0.id) },
            assistants: assistants(fixture)
        )

        XCTAssertTrue(fixture.exists(
            fixture.paths.sharedSkills.appendingPathComponent("a-duplicar/SKILL.md")
        ), "a pasta a sério vai para a partilhada")
        for id in ["claude", "codex"] {
            let link = fixture.paths.skillsRoot(forAssistant: id).appendingPathComponent("a-duplicar")
            XCTAssertEqual(
                (try? fm.attributesOfItem(atPath: link.path)[.type]) as? FileAttributeType,
                .typeSymbolicLink,
                "\(id) fica com um atalho"
            )
        }
    }

    // MARK: - AC3.8 / AC3.9 / AC3.10 the record, and life without it

    func testASuccessfulEnableForgetsTheRecord() throws {
        let fixture = Fixture()
        skill("ida-e-volta", forAssistant: "claude", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(item("ida-e-volta", in: fixture), assistants: assistants(fixture))

        try mutations.enableSkill(
            item("ida-e-volta", in: fixture),
            into: [assistant("claude", in: fixture)],
            assistants: assistants(fixture)
        )

        XCTAssertNil(mutations.records.entry(named: "ida-e-volta"))
    }

    func testWithNoRecordTheProposalIsWhereItIsParkedAndSaysSo() throws {
        let fixture = Fixture()
        skill("orfa", forAssistant: "codex", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(item("orfa", in: fixture), assistants: assistants(fixture))
        try mutations.records.forget("orfa") // o registo perdeu-se

        let proposal = mutations.restoreProposal(
            for: item("orfa", in: fixture), assistants: assistants(fixture)
        )

        XCTAssertEqual(proposal.assistants, ["codex"])
        XCTAssertFalse(proposal.remembered, "a app diz que não sabia, em vez de fingir que sabia")
    }

    func testARoundTripLeavesTheDiskExactlyAsItWas() throws {
        let fixture = Fixture()
        sharedSkill("partilhada", between: ["claude", "codex"], in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let before = item("partilhada", in: fixture)

        try mutations.disableSkill(before, assistants: assistants(fixture))
        let proposal = mutations.restoreProposal(
            for: item("partilhada", in: fixture), assistants: assistants(fixture)
        )
        XCTAssertTrue(proposal.remembered)
        try mutations.enableSkill(
            item("partilhada", in: fixture),
            into: assistants(fixture).filter { proposal.assistants.contains($0.id) },
            assistants: assistants(fixture)
        )

        XCTAssertTrue(fixture.exists(
            fixture.paths.sharedSkills.appendingPathComponent("partilhada/SKILL.md")
        ))
        for id in ["claude", "codex"] {
            let link = fixture.paths.skillsRoot(forAssistant: id).appendingPathComponent("partilhada")
            XCTAssertEqual(
                (try? fm.attributesOfItem(atPath: link.path)[.type]) as? FileAttributeType,
                .typeSymbolicLink
            )
        }
        XCTAssertEqual(item("partilhada", in: fixture).assistants, ["claude", "codex"])
    }

    // MARK: - AC3.12–AC3.15 plugin skills

    func testDisablingOnePluginSkillLeavesTheRestOfThePluginAlone() throws {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["vercel-functions", "vercel-cli"])
        let mutations = Mutations(paths: fixture.paths)
        let plugin = InventoryScanner(paths: fixture.paths).installedPlugins().first!

        try mutations.disablePluginSkill(item("vercel-functions", in: fixture), in: plugin)

        XCTAssertTrue(fixture.exists(
            plugin.installPath.appendingPathComponent("skills-off/vercel-functions/SKILL.md")
        ))
        XCTAssertTrue(
            fixture.exists(plugin.installPath.appendingPathComponent("skills/vercel-cli/SKILL.md")),
            "a outra continua ligada"
        )
        XCTAssertEqual(mutations.records.pluginSkills(of: plugin.id), ["vercel-functions"])
        XCTAssertFalse(item("vercel-functions", in: fixture).enabled)
    }

    func testAPluginUpdateDoesNotUndoTheChoice() throws {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["vercel-functions", "vercel-cli"])
        let scanner = InventoryScanner(paths: fixture.paths)
        let mutations = Mutations(paths: fixture.paths)
        let plugin = scanner.installedPlugins().first!
        try mutations.disablePluginSkill(item("vercel-functions", in: fixture), in: plugin)

        // A versão nova chega como uma cópia limpa do repositório do plugin, sem saber de nada.
        let fresh = plugin.installPath.appendingPathComponent("skills/vercel-functions")
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try "---\nname: vercel-functions\ndescription: Nova.\n---\n".write(
            to: fresh.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try fm.removeItem(at: plugin.installPath.appendingPathComponent("skills-off/vercel-functions"))

        let reapplied = mutations.reapplyDisabledSkills(of: plugin)

        XCTAssertEqual(reapplied, ["vercel-functions"])
        XCTAssertFalse(fixture.exists(fresh), "voltou a sair do sítio que o Claude lê")
    }

    func testEnablingAPluginSkillForgetsItSoUpdatesLeaveItAlone() throws {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["vercel-cli"])
        let mutations = Mutations(paths: fixture.paths)
        let plugin = InventoryScanner(paths: fixture.paths).installedPlugins().first!
        try mutations.disablePluginSkill(item("vercel-cli", in: fixture), in: plugin)

        try mutations.enablePluginSkill(item("vercel-cli", in: fixture), in: plugin)

        XCTAssertTrue(fixture.exists(
            plugin.installPath.appendingPathComponent("skills/vercel-cli/SKILL.md")
        ))
        XCTAssertTrue(mutations.records.pluginSkills(of: plugin.id).isEmpty)
    }

    func testASkillThePluginNoLongerShipsIsSkippedNotForgotten() throws {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["vercel-cli"])
        let mutations = Mutations(paths: fixture.paths)
        let plugin = InventoryScanner(paths: fixture.paths).installedPlugins().first!
        try mutations.records.rememberPluginEntry("skills/desaparecida", in: plugin.id)

        let reapplied = mutations.reapplyDisabledSkills(of: plugin)

        XCTAssertEqual(reapplied, [], "não havia nada para mover")
        XCTAssertEqual(
            mutations.records.pluginSkills(of: plugin.id), ["desaparecida"],
            "a escolha fica, caso a skill volte numa versão futura"
        )
    }

    func testPluginItemsCarryTheirPluginID() {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["vercel-cli"])

        XCTAssertEqual(item("vercel-cli", in: fixture).pluginID, "vercel@official")
    }

    // MARK: - AC3.19 project skills

    func testAProjectSkillParksInsideItsOwnRepository() throws {
        let fixture = Fixture()
        let repo = fixture.projectRepo("APPS/loadout", skills: ["do-repo"])
        fixture.projectsIndex("""
        | Caminho | Descrição |
        |---|---|
        | `APPS/loadout` | A app |
        """)
        let project = ProjectsIndex(paths: fixture.paths).load().first!
        let scanner = InventoryScanner(paths: fixture.paths)
        let mutations = Mutations(paths: fixture.paths)
        let skill = scanner.scanAll(project: project).items.first { $0.name == "do-repo" }!

        try mutations.disableSkill(skill)

        XCTAssertTrue(fixture.exists(repo.appendingPathComponent(".claude/skills-off/do-repo/SKILL.md")))
        XCTAssertFalse(fixture.exists(repo.appendingPathComponent(".claude/skills/do-repo")))

        let parked = scanner.scanAll(project: project).items.first { $0.name == "do-repo" }!
        XCTAssertFalse(parked.enabled, "continua listada, desligada")

        try mutations.enableSkill(parked)
        XCTAssertTrue(fixture.exists(repo.appendingPathComponent(".claude/skills/do-repo/SKILL.md")))
    }
}

/// What a release audit found in the enable path: a destination that was already occupied was
/// skipped, the call reported success, and the off-record — the only remaining evidence of where
/// the skill belonged — was thrown away.
extension DisableAcrossAssistantsTests {

    func testEnablingRefusesWhenOneAssistantAlreadyHasThatName() throws {
        let fixture = Fixture()
        skill("demo", forAssistant: "claude", in: fixture)
        try! fm.createDirectory(
            at: fixture.paths.skillsRoot(forAssistant: "codex"), withIntermediateDirectories: true
        )
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(item("demo", in: fixture), assistants: assistants(fixture))
        // Something else of the same name turns up in Codex while it is parked.
        skill("demo", forAssistant: "codex", in: fixture)

        XCTAssertThrowsError(
            try mutations.enableSkill(
                item("demo", in: fixture, enabled: false),
                into: assistants(fixture).filter { ["claude", "codex"].contains($0.id) },
                assistants: assistants(fixture)
            )
        ) { error in
            guard case LoadoutError.alreadyExists = error as! LoadoutError else {
                return XCTFail("erro errado: \(error)")
            }
        }

        XCTAssertNotNil(
            mutations.records.entry(named: "demo"),
            "o registo fica: sem ele ninguém sabe onde a skill devia voltar"
        )
        XCTAssertTrue(
            fixture.exists(fixture.paths.home.appendingPathComponent(".claude/skills-off/demo/SKILL.md")),
            "e a pasta não saiu do sítio"
        )
        XCTAssertFalse(
            fixture.exists(fixture.paths.sharedSkills.appendingPathComponent("demo")),
            "nada foi movido antes de se saber que dava"
        )
    }
}
