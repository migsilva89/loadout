import XCTest
@testable import LoadoutCore

/// Sharing skills between Claude Code and Codex.
final class AssistantTests: XCTestCase {
    private let fm = FileManager.default

    private func codexSkill(_ name: String, in fixture: Fixture) {
        let folder = fixture.paths.codexSkills.appendingPathComponent(name)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! "---\nname: \(name)\ndescription: Do Codex.\n---\n\nCorpo.".write(
            to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
    }

    private func item(_ name: String, in fixture: Fixture) -> Item {
        InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.name == name }!
    }

    // MARK: Seeing the gap

    func testASkillIsOneRowCarryingTheAssistantsThatLoadIt() {
        let fixture = Fixture()
        fixture.skill("nos-dois")
        codexSkill("nos-dois", in: fixture)
        fixture.skill("so-no-claude")
        codexSkill("so-no-codex", in: fixture)

        let skills = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }

        XCTAssertEqual(skills.count, 3, "a que está nos dois aparece uma vez, não duas")
        XCTAssertEqual(item("nos-dois", in: fixture).assistants, [.claudeCode, .codex])
        XCTAssertEqual(item("so-no-claude", in: fixture).assistants, [.claudeCode])
        XCTAssertEqual(item("so-no-codex", in: fixture).assistants, [.codex])
    }

    func testASkillOnlyCodexHasIsStillListed() {
        let fixture = Fixture()
        codexSkill("orfa", in: fixture)

        let skills = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }

        XCTAssertEqual(skills.map(\.name), ["orfa"], "ver a falha é o objetivo")
        XCTAssertEqual(skills.first?.description, "Do Codex.")
    }

    // MARK: Filling the gap

    func testSharingPromotesToTheCommonTreeAndLinksBothSides() throws {
        let fixture = Fixture()
        fixture.skill("partilhavel", extraFile: "echo olá")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(item("partilhavel", in: fixture), with: .codex)

        let canonical = fixture.paths.sharedSkills.appendingPathComponent("partilhavel")
        XCTAssertTrue(fixture.exists(canonical.appendingPathComponent("SKILL.md")))
        XCTAssertTrue(
            fixture.exists(canonical.appendingPathComponent("scripts/run.sh")),
            "a pasta inteira viaja"
        )
        XCTAssertTrue(mutations.isSymlink(fixture.paths.skills.appendingPathComponent("partilhavel")))
        XCTAssertTrue(mutations.isSymlink(fixture.paths.codexSkills.appendingPathComponent("partilhavel")))
        XCTAssertEqual(item("partilhavel", in: fixture).assistants, [.claudeCode, .codex])
    }

    func testSharingWorksInTheOtherDirectionToo() throws {
        let fixture = Fixture()
        codexSkill("veio-do-codex", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(item("veio-do-codex", in: fixture), with: .claudeCode)

        XCTAssertEqual(item("veio-do-codex", in: fixture).assistants, [.claudeCode, .codex])
        XCTAssertTrue(fixture.exists(
            fixture.paths.sharedSkills.appendingPathComponent("veio-do-codex/SKILL.md")
        ))
    }

    func testEditingTheSharedCopyIsSeenFromBothSides() throws {
        let fixture = Fixture()
        fixture.skill("uma-so-copia")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.share(item("uma-so-copia", in: fixture), with: .codex)

        try mutations.save(
            item("uma-so-copia", in: fixture),
            contents: "---\nname: uma-so-copia\ndescription: Editada uma vez.\n---\n\nNovo."
        )

        let viaCodex = fixture.paths.codexSkills.appendingPathComponent("uma-so-copia/SKILL.md")
        XCTAssertTrue(fixture.read(viaCodex).contains("Editada uma vez."))
    }

    func testSharingTwiceChangesNothing() throws {
        let fixture = Fixture()
        fixture.skill("idempotente")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(item("idempotente", in: fixture), with: .codex)
        XCTAssertNoThrow(try mutations.share(item("idempotente", in: fixture), with: .codex))
        XCTAssertEqual(item("idempotente", in: fixture).assistants, [.claudeCode, .codex])
    }

    // MARK: Refusing to lose work

    func testTwoIndependentCopiesAreNotMergedBehindTheUsersBack() {
        let fixture = Fixture()
        fixture.skill("divergente", description: "Versão do Claude.")
        codexSkill("divergente", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        XCTAssertThrowsError(try mutations.promoteToShared(named: "divergente")) {
            XCTAssertTrue(
                $0.localizedDescription.contains("mais do que um assistente"),
                "explica porque é que se recusa"
            )
        }
        XCTAssertTrue(fixture.exists(fixture.paths.skills.appendingPathComponent("divergente/SKILL.md")))
        XCTAssertTrue(fixture.exists(fixture.paths.codexSkills.appendingPathComponent("divergente/SKILL.md")))
    }

    func testUnsharingRemovesOnlyTheLink() throws {
        let fixture = Fixture()
        fixture.skill("emprestada")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.share(item("emprestada", in: fixture), with: .codex)

        try mutations.unshare(item("emprestada", in: fixture), from: .codex)

        XCTAssertEqual(item("emprestada", in: fixture).assistants, [.claudeCode])
        XCTAssertTrue(
            fixture.exists(fixture.paths.sharedSkills.appendingPathComponent("emprestada/SKILL.md")),
            "a skill continua a existir"
        )
    }

    func testUnsharingTheLastAssistantIsRefused() throws {
        let fixture = Fixture()
        fixture.skill("unica")
        let mutations = Mutations(paths: fixture.paths)

        XCTAssertThrowsError(try mutations.unshare(item("unica", in: fixture), from: .claudeCode)) {
            XCTAssertTrue($0.localizedDescription.contains("Desativar"), "aponta para a alternativa certa")
        }
        XCTAssertTrue(fixture.exists(fixture.paths.skills.appendingPathComponent("unica/SKILL.md")))
    }

    func testUnsharingNeverDeletesARealFolder() throws {
        let fixture = Fixture()
        // Both sides hold real folders, so neither is a link that can be safely removed.
        fixture.skill("dupla-real")
        codexSkill("dupla-real", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        XCTAssertThrowsError(try mutations.unshare(item("dupla-real", in: fixture), from: .codex))
        XCTAssertTrue(fixture.exists(fixture.paths.codexSkills.appendingPathComponent("dupla-real/SKILL.md")))
    }

    func testSharingSnapshotsBeforeMoving() throws {
        let fixture = Fixture()
        fixture.skill("com-rede")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(item("com-rede", in: fixture), with: .codex)

        let backups = (fm.enumerator(at: fixture.paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.path } ?? [])
        XCTAssertTrue(backups.contains { $0.hasSuffix("skills/com-rede/SKILL.md") })
    }
}
