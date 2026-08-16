import XCTest
@testable import LoadoutCore

/// Sharing skills between Claude Code and Codex.
final class AssistantTests: XCTestCase {
    private let fm = FileManager.default

    private func codexSkill(_ name: String, in fixture: Fixture) {
        let folder = fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent(name)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! "---\nname: \(name)\ndescription: From Codex.\n---\n\nBody.".write(
            to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
    }

    private func item(_ name: String, in fixture: Fixture) -> Item {
        InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.name == name }!
    }

    /// The assistants as the app discovers them, straight off the fixture's fake home.
    /// Creates the assistant's own directory first, which is what having it installed means.
    private func assistant(_ id: String, in fixture: Fixture) -> Assistant {
        try? fm.createDirectory(
            at: fixture.paths.skillsRoot(forAssistant: id), withIntermediateDirectories: true
        )
        return AssistantRegistry.discover(paths: fixture.paths).first { $0.id == id }!
    }

    private func allAssistants(_ fixture: Fixture) -> [Assistant] {
        AssistantRegistry.discover(paths: fixture.paths)
    }

    // MARK: Seeing the gap

    func testASkillIsOneRowCarryingTheAssistantsThatLoadIt() {
        let fixture = Fixture()
        fixture.skill("on-both")
        codexSkill("on-both", in: fixture)
        fixture.skill("claude-only")
        codexSkill("codex-only", in: fixture)

        let skills = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }

        XCTAssertEqual(skills.count, 3, "the one on both shows up once, not twice")
        XCTAssertEqual(item("on-both", in: fixture).assistants, ["claude", "codex"])
        XCTAssertEqual(item("claude-only", in: fixture).assistants, ["claude"])
        XCTAssertEqual(item("codex-only", in: fixture).assistants, ["codex"])
    }

    func testASkillOnlyCodexHasIsStillListed() {
        let fixture = Fixture()
        codexSkill("orphan", in: fixture)

        let skills = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }

        XCTAssertEqual(skills.map(\.name), ["orphan"], "seeing the breakage is the point")
        XCTAssertEqual(skills.first?.description, "From Codex.")
    }

    // MARK: Filling the gap

    func testSharingPromotesToTheCommonTreeAndLinksBothSides() throws {
        let fixture = Fixture()
        fixture.skill("shareable", extraFile: "echo hello")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(item("shareable", in: fixture), with: assistant("codex", in: fixture))

        let canonical = fixture.paths.sharedSkills.appendingPathComponent("shareable")
        XCTAssertTrue(fixture.exists(canonical.appendingPathComponent("SKILL.md")))
        XCTAssertTrue(
            fixture.exists(canonical.appendingPathComponent("scripts/run.sh")),
            "the whole folder travels"
        )
        XCTAssertTrue(mutations.isSymlink(fixture.paths.skills.appendingPathComponent("shareable")))
        XCTAssertTrue(mutations.isSymlink(fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("shareable")))
        XCTAssertEqual(item("shareable", in: fixture).assistants, ["claude", "codex"])
    }

    func testSharingWorksInTheOtherDirectionToo() throws {
        let fixture = Fixture()
        codexSkill("came-from-codex", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(item("came-from-codex", in: fixture), with: assistant("claude", in: fixture))

        XCTAssertEqual(item("came-from-codex", in: fixture).assistants, ["claude", "codex"])
        XCTAssertTrue(fixture.exists(
            fixture.paths.sharedSkills.appendingPathComponent("came-from-codex/SKILL.md")
        ))
    }

    func testEditingTheSharedCopyIsSeenFromBothSides() throws {
        let fixture = Fixture()
        fixture.skill("one-copy-only")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.share(item("one-copy-only", in: fixture), with: assistant("codex", in: fixture))

        try mutations.save(
            item("one-copy-only", in: fixture),
            contents: "---\nname: one-copy-only\ndescription: Edited once.\n---\n\nNew."
        )

        let viaCodex = fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("one-copy-only/SKILL.md")
        XCTAssertTrue(fixture.read(viaCodex).contains("Edited once."))
    }

    func testSharingTwiceChangesNothing() throws {
        let fixture = Fixture()
        fixture.skill("idempotent")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(item("idempotent", in: fixture), with: assistant("codex", in: fixture))
        XCTAssertNoThrow(try mutations.share(item("idempotent", in: fixture), with: assistant("codex", in: fixture)))
        XCTAssertEqual(item("idempotent", in: fixture).assistants, ["claude", "codex"])
    }

    // MARK: Refusing to lose work

    func testTwoIndependentCopiesAreNotMergedBehindTheUsersBack() {
        let fixture = Fixture()
        fixture.skill("diverged", description: "Claude's version.")
        codexSkill("diverged", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        XCTAssertThrowsError(try mutations.promoteToShared(named: "diverged", across: allAssistants(fixture))) {
            XCTAssertTrue(
                $0.localizedDescription.contains("more than one assistant"),
                "it explains why it refuses"
            )
        }
        XCTAssertTrue(fixture.exists(fixture.paths.skills.appendingPathComponent("diverged/SKILL.md")))
        XCTAssertTrue(fixture.exists(fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("diverged/SKILL.md")))
    }

    func testUnsharingRemovesOnlyTheLink() throws {
        let fixture = Fixture()
        fixture.skill("lent-out")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.share(item("lent-out", in: fixture), with: assistant("codex", in: fixture))

        try mutations.unshare(item("lent-out", in: fixture), from: assistant("codex", in: fixture))

        XCTAssertEqual(item("lent-out", in: fixture).assistants, ["claude"])
        XCTAssertTrue(
            fixture.exists(fixture.paths.sharedSkills.appendingPathComponent("lent-out/SKILL.md")),
            "the skill still exists"
        )
    }

    func testUnsharingTheLastAssistantIsRefused() throws {
        let fixture = Fixture()
        fixture.skill("only-one")
        let mutations = Mutations(paths: fixture.paths)

        XCTAssertThrowsError(try mutations.unshare(item("only-one", in: fixture), from: assistant("claude", in: fixture))) {
            XCTAssertTrue($0.localizedDescription.contains("Disable"), "it points at the right alternative")
        }
        XCTAssertTrue(fixture.exists(fixture.paths.skills.appendingPathComponent("only-one/SKILL.md")))
    }

    func testUnsharingNeverDeletesARealFolder() throws {
        let fixture = Fixture()
        // Both sides hold real folders, so neither is a link that can be safely removed.
        fixture.skill("both-real")
        codexSkill("both-real", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        XCTAssertThrowsError(try mutations.unshare(item("both-real", in: fixture), from: assistant("codex", in: fixture)))
        XCTAssertTrue(fixture.exists(fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("both-real/SKILL.md")))
    }

    func testSharingSnapshotsBeforeMoving() throws {
        let fixture = Fixture()
        fixture.skill("with-a-net")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(item("with-a-net", in: fixture), with: assistant("codex", in: fixture))

        let backups = (fm.enumerator(at: fixture.paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.path } ?? [])
        XCTAssertTrue(backups.contains { $0.hasSuffix("skills/with-a-net/SKILL.md") })
    }
}
