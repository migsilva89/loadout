import XCTest
@testable import LoadoutCore

/// Removing something takes every link to it along, the original is known, and a skill, command or
/// subagent can be copied to another assistant as a file of its own.
final class RemoveAndCopyTests: XCTestCase {
    private let fm = FileManager.default

    /// Claude Code, plus two assistants with folders (`zzz`, `yyy`) and opencode with its agent folder.
    private func machine() -> Fixture {
        let fixture = Fixture()
        for id in ["zzz", "yyy", "cursor", "codex"] {
            try! fm.createDirectory(at: fixture.paths.home.appendingPathComponent(".\(id)/skills"), withIntermediateDirectories: true)
        }
        try! fm.createDirectory(
            at: fixture.paths.opencodeConfig.deletingLastPathComponent().appendingPathComponent("agent"),
            withIntermediateDirectories: true
        )
        return fixture
    }

    private func assistant(_ id: String, _ fixture: Fixture) -> Assistant {
        AssistantRegistry.discover(paths: fixture.paths).first { $0.id == id }!
    }

    private func item(_ name: String, _ kind: ItemKind, _ fixture: Fixture) -> Item? {
        InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.name == name && $0.kind == kind }
    }

    private func linked(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func gone(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) == nil }

    // MARK: - Removing takes every link

    func testDeletingASharedSkillRemovesTheRealFolderAndEveryLink() throws {
        let fixture = machine()
        fixture.skill("shared-one")
        let mutations = Mutations(paths: fixture.paths)
        for id in ["zzz", "yyy"] { try mutations.share(item("shared-one", .skill, fixture)!, with: assistant(id, fixture)) }
        let report = try mutations.delete(item("shared-one", .skill, fixture)!)

        XCTAssertNil(item("shared-one", .skill, fixture))
        for root in [fixture.paths.skills, fixture.paths.home.appendingPathComponent(".zzz/skills"),
                     fixture.paths.home.appendingPathComponent(".yyy/skills"), fixture.paths.sharedSkills] {
            XCTAssertTrue(gone(root.appendingPathComponent("shared-one")), root.path)
        }
        XCTAssertEqual(report.links.count, 3, "Claude, zzz and yyy: \(report.links)")
        XCTAssertEqual(report.copies.count, 1, "the one real folder")
    }

    func testDeletingACommandAndASubagentRemovesTheirLinksToo() throws {
        let fixture = machine()
        fixture.command("ship")
        fixture.agent("reviewer")
        let mutations = Mutations(paths: fixture.paths)
        let zzz = assistant("cursor", fixture)
        let opencode = assistant("opencode", fixture)
        let commandLink = try mutations.shareCommand(item("ship", .command, fixture)!, with: zzz)
        let agentLink = try mutations.shareAgent(item("reviewer", .agent, fixture)!, with: opencode)

        try mutations.delete(item("ship", .command, fixture)!)
        try mutations.delete(item("reviewer", .agent, fixture)!)

        XCTAssertTrue(gone(commandLink) && gone(agentLink), "no dangling link left behind")
        XCTAssertTrue(gone(fixture.paths.commands.appendingPathComponent("ship.md")))
        XCTAssertTrue(gone(fixture.paths.agents.appendingPathComponent("reviewer.md")))
    }

    func testAParkedItemsLinksAreRemovedToo() throws {
        let fixture = machine()
        fixture.command("ship")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.shareCommand(item("ship", .command, fixture)!, with: assistant("cursor", fixture))
        try mutations.setCommand(item("ship", .command, fixture)!, enabled: false)

        try mutations.delete(item("ship", .command, fixture)!)

        for root in [fixture.paths.home.appendingPathComponent(".cursor/prompts-off"),
                     fixture.paths.home.appendingPathComponent(".cursor/commands-off"),
                     fixture.paths.home.appendingPathComponent(".claude/commands-off")] {
            XCTAssertTrue(gone(root.appendingPathComponent("ship.md")), root.path)
        }
    }

    func testALinkUnderAnotherNameThatPointsAtTheDeletedCopyGoesToo() throws {
        let fixture = machine()
        fixture.command("ship")
        let real = fixture.paths.commands.appendingPathComponent("ship.md")
        let odd = fixture.paths.home.appendingPathComponent(".cursor/commands")
        try fm.createDirectory(at: odd, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: odd.appendingPathComponent("shipping.md"), withDestinationURL: real)

        try Mutations(paths: fixture.paths).delete(item("ship", .command, fixture)!)

        XCTAssertTrue(gone(odd.appendingPathComponent("shipping.md")))
    }

    func testDeletingAProjectItemStillTouchesOnlyThatOne() throws {
        let fixture = Fixture()
        fixture.skill("mine")
        let item = item("mine", .skill, fixture)!

        let report = try Mutations(paths: fixture.paths).delete(item)

        XCTAssertEqual(report.copies.count, 1)
        XCTAssertNil(self.item("mine", .skill, fixture))
    }

    // MARK: - The original

    func testACommandsOriginalIsTheAssistantHoldingTheRealFile() throws {
        let fixture = machine()
        fixture.command("ship")
        try Mutations(paths: fixture.paths).shareCommand(item("ship", .command, fixture)!, with: assistant("cursor", fixture))

        let shared = item("ship", .command, fixture)!

        XCTAssertEqual(shared.original, "claude")
        XCTAssertEqual(shared.realCopyIn, ["claude"])
        XCTAssertEqual(shared.assistants, ["claude", "cursor"])
    }

    func testASkillRemembersWhereItStartedAfterEveryoneHoldsALink() throws {
        let fixture = machine()
        fixture.skill("remembered")
        try Mutations(paths: fixture.paths).share(item("remembered", .skill, fixture)!, with: assistant("zzz", fixture))

        let shared = item("remembered", .skill, fixture)!

        XCTAssertEqual(shared.realCopyIn, [], "all links now, the real folder is in ~/.agents/skills")
        XCTAssertEqual(shared.original, "claude", "from Loadout's own record")
    }

    func testASkillSharedBeforeTheRecordExistedSaysNothingRatherThanGuess() throws {
        let fixture = machine()
        fixture.skill("old")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.share(item("old", .skill, fixture)!, with: assistant("zzz", fixture))
        try fm.removeItem(at: OriginRecords(paths: fixture.paths).file)

        XCTAssertNil(item("old", .skill, fixture)!.original)
    }

    // MARK: - Copying

    func testCopyingASkillMakesAFolderOfItsOwnThatDriftsFreely() throws {
        let fixture = machine()
        fixture.skill("wording", extraFile: "echo hi")
        let mutations = Mutations(paths: fixture.paths)
        let zzz = assistant("zzz", fixture)

        let copy = try mutations.copy(item("wording", .skill, fixture)!, to: zzz)

        XCTAssertFalse(linked(copy), "a copy is a folder, not a link")
        XCTAssertTrue(fixture.exists(copy.appendingPathComponent("scripts/run.sh")), "whole")
        try "edited".write(to: copy.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try String(contentsOf: fixture.paths.skills.appendingPathComponent("wording/SKILL.md"), encoding: .utf8).contains("Does things"),
                      "editing one never touches the other")
        let both = item("wording", .skill, fixture)!
        XCTAssertEqual(both.assistants, ["claude", "zzz"])
        XCTAssertEqual(both.realCopyIn, ["claude", "zzz"])
        XCTAssertNil(both.original, "two separate copies have no single original")
        XCTAssertThrowsError(try mutations.copy(both, to: zzz), "never over something already there")
    }

    func testCopyingAFollowsALinkToTheRealFileAndCopiesAFile() throws {
        let fixture = machine()
        fixture.command("ship")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.shareCommand(item("ship", .command, fixture)!, with: assistant("cursor", fixture))

        let copy = try mutations.copy(item("ship", .command, fixture)!, to: assistant("codex", fixture))

        XCTAssertFalse(linked(copy))
        XCTAssertTrue(try String(contentsOf: copy, encoding: .utf8).contains("Faz isto"))
    }

    func testASubagentCopyNeedsAnAssistantThatReadsAgentFolders() throws {
        let fixture = machine()
        fixture.agent("reviewer")
        let mutations = Mutations(paths: fixture.paths)

        let copy = try mutations.copy(item("reviewer", .agent, fixture)!, to: assistant("opencode", fixture))
        XCTAssertEqual(copy.deletingLastPathComponent().lastPathComponent, "agent")
        XCTAssertFalse(linked(copy))
        XCTAssertThrowsError(try mutations.copy(item("reviewer", .agent, fixture)!, to: assistant("zzz", fixture)))
    }

    // MARK: - Removing a copy

    func testACopyCanBeRemovedFromOneAssistantAndTheOthersKeepTheirs() throws {
        let fixture = machine()
        fixture.skill("wording")
        let mutations = Mutations(paths: fixture.paths)
        let zzz = assistant("zzz", fixture)
        let copy = try mutations.copy(item("wording", .skill, fixture)!, to: zzz)

        try mutations.removeCopy(of: item("wording", .skill, fixture)!, from: zzz)

        XCTAssertTrue(gone(copy))
        XCTAssertEqual(item("wording", .skill, fixture)?.assistants, ["claude"])
    }

    func testTheOriginalCannotBeRemovedFromItsAssistantWhileOthersLinkToIt() throws {
        let fixture = machine()
        fixture.command("ship")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.shareCommand(item("ship", .command, fixture)!, with: assistant("cursor", fixture))

        XCTAssertThrowsError(try mutations.removeCopy(of: item("ship", .command, fixture)!, from: assistant("claude", fixture))) { error in
            XCTAssertTrue((error as? LoadoutError)?.errorDescription?.contains("remove ship itself") == true)
        }
        XCTAssertTrue(fixture.exists(fixture.paths.commands.appendingPathComponent("ship.md")))
    }

    func testTheOnlyCopyCannotBeRemoved() {
        let fixture = machine()
        fixture.command("ship")

        XCTAssertThrowsError(try Mutations(paths: fixture.paths).removeCopy(of: item("ship", .command, fixture)!, from: assistant("claude", fixture)))
    }
}
