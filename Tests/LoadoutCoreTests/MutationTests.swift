import XCTest
@testable import LoadoutCore

/// AC3 — enable and disable, AC4 — edit, create, delete, AC5 — the safety net.
final class MutationTests: XCTestCase {

    private func item(named name: String, in fixture: Fixture) -> Item {
        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        return items.first { $0.name == name }!
    }

    // MARK: AC3.1 / AC3.2 / AC5.2

    func testDisablingMovesTheWholeFolderToSkillsOff() throws {
        let fixture = Fixture()
        fixture.skill("imark-review", extraFile: "echo olá")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(item(named: "imark-review", in: fixture))

        let parked = fixture.paths.skillsOff.appendingPathComponent("imark-review")
        XCTAssertFalse(fixture.exists(fixture.paths.skills.appendingPathComponent("imark-review")))
        XCTAssertTrue(fixture.exists(parked.appendingPathComponent("SKILL.md")))
        XCTAssertTrue(
            fixture.exists(parked.appendingPathComponent("scripts/run.sh")),
            "os ficheiros extra vão junto"
        )
    }

    func testEnablingBringsItBack() throws {
        let fixture = Fixture()
        fixture.skill("parada", disabled: true)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.enableSkill(item(named: "parada", in: fixture))

        XCTAssertTrue(fixture.exists(
            fixture.paths.skills.appendingPathComponent("parada/SKILL.md")
        ))
        XCTAssertFalse(fixture.exists(fixture.paths.skillsOff.appendingPathComponent("parada")))
    }

    // MARK: AC3.3

    func testDisablingRefusesWhenTheDestinationExists() {
        let fixture = Fixture()
        fixture.skill("dupla")
        fixture.skill("dupla", disabled: true)
        let mutations = Mutations(paths: fixture.paths)
        let live = InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.name == "dupla" && $0.enabled }!

        XCTAssertThrowsError(try mutations.disableSkill(live)) { error in
            guard case LoadoutError.alreadyExists = error as! LoadoutError else {
                return XCTFail("erro errado: \(error)")
            }
        }
        XCTAssertTrue(
            fixture.exists(fixture.paths.skills.appendingPathComponent("dupla/SKILL.md")),
            "a original continua no sítio"
        )
    }

    // MARK: AC3.4

    func testTogglingAPluginPreservesEverythingElseInSettings() throws {
        let fixture = Fixture()
        fixture.settings([
            "permissions": ["allow": ["WebSearch", "Bash(npx:*)"]],
            "enabledPlugins": ["outro@mkt": true],
        ])
        fixture.plugin("vercel", marketplace: "official", skills: ["deploy"])
        let mutations = Mutations(paths: fixture.paths)
        let plugin = InventoryScanner(paths: fixture.paths).installedPlugins().first { $0.name == "vercel" }!

        try mutations.setPlugin(plugin, enabled: false)

        let data = try Data(contentsOf: fixture.paths.localSettings)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let flags = root["enabledPlugins"] as! [String: Any]
        XCTAssertEqual(flags["vercel@official"] as? Bool, false)
        XCTAssertEqual(flags["outro@mkt"] as? Bool, true, "as outras flags ficam")
        let permissions = root["permissions"] as? [String: Any]
        XCTAssertEqual(
            (permissions?["allow"] as? [String])?.count, 2,
            "o resto do ficheiro sobrevive"
        )
        XCTAssertEqual(InventoryScanner(paths: fixture.paths).installedPlugins().first?.enabled, false)
    }

    // MARK: AC3.5 / AC4.6

    func testPluginItemsCannotBeDisabledOrSaved() {
        let fixture = Fixture()
        fixture.plugin("vercel", skills: ["deploy"])
        let mutations = Mutations(paths: fixture.paths)
        let pluginSkill = item(named: "deploy", in: fixture)
        let before = fixture.read(pluginSkill.path!)

        XCTAssertThrowsError(try mutations.disableSkill(pluginSkill))
        XCTAssertThrowsError(try mutations.save(pluginSkill, contents: "---\nname: x\ndescription: y\n---\n"))
        XCTAssertThrowsError(try mutations.delete(pluginSkill))
        XCTAssertEqual(fixture.read(pluginSkill.path!), before, "o ficheiro não foi tocado")
    }

    // MARK: AC4.2

    func testSavingValidatesTheFrontmatterBeforeTouchingTheDisk() {
        let fixture = Fixture()
        fixture.skill("valida")
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "valida", in: fixture)
        let original = fixture.read(skill.path!)

        XCTAssertThrowsError(try mutations.save(skill, contents: "---\ndescription: só isto\n---\n"))
        XCTAssertThrowsError(try mutations.save(skill, contents: "---\nname: valida\n---\n"))
        XCTAssertThrowsError(
            try mutations.save(skill, contents: "---\nname: Nome Errado\ndescription: x\n---\n")
        )
        XCTAssertEqual(fixture.read(skill.path!), original, "nada foi gravado")
    }

    func testSavingValidContentWrites() throws {
        let fixture = Fixture()
        fixture.skill("boa")
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "boa", in: fixture)
        let updated = "---\nname: boa\ndescription: Nova descrição.\n---\n\nCorpo novo."

        try mutations.save(skill, contents: updated)

        XCTAssertEqual(fixture.read(skill.path!), updated)
    }

    // MARK: AC4.3

    func testCreatingASkillWritesTheTemplate() throws {
        let fixture = Fixture()
        let mutations = Mutations(paths: fixture.paths)

        try mutations.createSkill(name: "nova-skill", description: "Dispara quando X.")

        let file = fixture.paths.skills.appendingPathComponent("nova-skill/SKILL.md")
        let text = fixture.read(file)
        XCTAssertTrue(text.contains("name: nova-skill"))
        XCTAssertTrue(text.contains("description: Dispara quando X."))
        XCTAssertNoThrow(try mutations.validateSkillDocument(text))
    }

    func testCreatingRejectsBadNamesAndCollisions() throws {
        let fixture = Fixture()
        let mutations = Mutations(paths: fixture.paths)
        try mutations.createSkill(name: "existe", description: "x")
        fixture.skill("parada", disabled: true)

        XCTAssertThrowsError(try mutations.createSkill(name: "Nome Errado", description: "x"))
        XCTAssertThrowsError(try mutations.createSkill(name: "existe", description: "x"))
        XCTAssertThrowsError(
            try mutations.createSkill(name: "parada", description: "x"),
            "colide com uma desativada"
        )
    }

    func testSkillNameRules() {
        XCTAssertTrue(isValidSkillName("imark-review"))
        XCTAssertTrue(isValidSkillName("seo2"))
        XCTAssertFalse(isValidSkillName(""))
        XCTAssertFalse(isValidSkillName("Imark"))
        XCTAssertFalse(isValidSkillName("com espaço"))
        XCTAssertFalse(isValidSkillName("acaba-"))
        XCTAssertFalse(isValidSkillName("-comeca"))
        XCTAssertFalse(isValidSkillName("under_score"))
    }

    // MARK: AC4.4

    func testDeletingSendsToTheTrashRatherThanUnlinking() throws {
        let fixture = Fixture()
        fixture.skill("descartavel")
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "descartavel", in: fixture)

        try mutations.delete(skill)

        XCTAssertFalse(fixture.exists(skill.directory!))
        // A cópia de segurança é o que garante que nada se perde de vez.
        XCTAssertTrue(backupContents(fixture).contains { $0.contains("descartavel") })
    }

    // MARK: AC5.1 / AC5.2

    func testEveryWriteLeavesASnapshotBehind() throws {
        let fixture = Fixture()
        fixture.skill("com-copia", extraFile: "echo x")
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "com-copia", in: fixture)

        try mutations.save(skill, contents: "---\nname: com-copia\ndescription: nova.\n---\n")
        try mutations.disableSkill(item(named: "com-copia", in: fixture))

        let backups = backupContents(fixture)
        XCTAssertTrue(backups.contains { $0.hasSuffix("skills/com-copia/SKILL.md") })
        XCTAssertTrue(
            backups.contains { $0.hasSuffix("skills/com-copia/scripts/run.sh") },
            "a árvore inteira, não só o SKILL.md"
        )
    }

    func testSnapshotOfAMissingSourceIsANoOpNotACrash() throws {
        let fixture = Fixture()
        let backups = Backups(paths: fixture.paths)
        XCTAssertNil(try backups.snapshot(fixture.paths.skills.appendingPathComponent("nao-existe")))
    }

    // MARK: AC5.4

    func testWriteIsAbortedWhenTheSnapshotCannotBeMade() {
        let fixture = Fixture()
        fixture.skill("bloqueada")
        // A file where the backups directory should be: creating the tree underneath must fail.
        try! "não sou uma pasta".write(
            to: fixture.paths.backups, atomically: true, encoding: .utf8
        )
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "bloqueada", in: fixture)
        let original = fixture.read(skill.path!)

        XCTAssertThrowsError(try mutations.save(skill, contents: "---\nname: bloqueada\ndescription: y\n---\n")) {
            guard case LoadoutError.backupFailed = $0 as! LoadoutError else {
                return XCTFail("devia falhar na cópia, falhou com \($0)")
            }
        }
        XCTAssertEqual(fixture.read(skill.path!), original, "não escreveu sem cópia")
    }

    private func backupContents(_ fixture: Fixture) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: fixture.paths.backups, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { ($0 as? URL)?.path }
    }
}
