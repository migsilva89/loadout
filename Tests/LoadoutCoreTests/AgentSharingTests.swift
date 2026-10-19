import XCTest
@testable import LoadoutCore

/// Subagents shared between assistants, the way commands already are: one file, linked.
final class AgentSharingTests: XCTestCase {
    private let fm = FileManager.default

    /// A machine with Claude Code, opencode (agents in its own `agent` folder) and Codex.
    private func machine() -> Fixture {
        let fixture = Fixture()
        fixture.agent("reviewer")
        try! fm.createDirectory(
            at: fixture.paths.opencodeConfig.deletingLastPathComponent().appendingPathComponent("agent"),
            withIntermediateDirectories: true
        )
        try! fm.createDirectory(at: fixture.paths.codexHome, withIntermediateDirectories: true)
        return fixture
    }

    private func assistant(_ id: String, in fixture: Fixture) -> Assistant {
        AssistantRegistry.discover(paths: fixture.paths).first { $0.id == id }!
    }

    private func agent(_ name: String, in fixture: Fixture) -> Item? {
        InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .agent && $0.name == name }
    }

    func testOnlyAssistantsThatReadAgentFoldersHaveOne() {
        let fixture = machine()

        XCTAssertNotNil(assistant("claude", in: fixture).agentsRoot)
        XCTAssertEqual(assistant("opencode", in: fixture).agentsRoot?.lastPathComponent, "agent", "the folder it already has")
        XCTAssertNil(assistant("codex", in: fixture).agentsRoot, "Codex defines its agents in TOML")
    }

    func testSharingAnAgentLinksTheOneFile() throws {
        let fixture = machine()
        let opencode = assistant("opencode", in: fixture)

        let link = try Mutations(paths: fixture.paths).shareAgent(agent("reviewer", in: fixture)!, with: opencode)

        XCTAssertEqual((try fm.attributesOfItem(atPath: link.path))[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(link.deletingLastPathComponent().lastPathComponent, "agent")
        XCTAssertEqual(agent("reviewer", in: fixture)?.assistants, ["claude", "opencode"])
    }

    func testAnAssistantWithNoAgentFolderIsRefusedAndNothingIsCreated() {
        let fixture = machine()
        let codex = assistant("codex", in: fixture)

        XCTAssertThrowsError(try Mutations(paths: fixture.paths).shareAgent(agent("reviewer", in: fixture)!, with: codex))
        XCTAssertFalse(fm.fileExists(atPath: fixture.paths.codexHome.appendingPathComponent("agents").path))
    }

    func testUnsharingRemovesTheLinkAndNeverTheRealCopy() throws {
        let fixture = machine()
        let mutations = Mutations(paths: fixture.paths)
        let opencode = assistant("opencode", in: fixture)
        try mutations.shareAgent(agent("reviewer", in: fixture)!, with: opencode)

        try mutations.unshareAgent(agent("reviewer", in: fixture)!, from: opencode)
        XCTAssertEqual(agent("reviewer", in: fixture)?.assistants, ["claude"])

        XCTAssertThrowsError(
            try mutations.unshareAgent(agent("reviewer", in: fixture)!, from: assistant("claude", in: fixture)),
            "the real file is not a link"
        )
        XCTAssertTrue(fixture.exists(fixture.paths.agents.appendingPathComponent("reviewer.md")))
    }

    func testAnExistingRealFileInTheTargetIsNeverOverwritten() throws {
        let fixture = machine()
        let opencode = assistant("opencode", in: fixture)
        let theirs = opencode.agentsRoot!.appendingPathComponent("reviewer.md")
        try "their own".write(to: theirs, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try Mutations(paths: fixture.paths).shareAgent(agent("reviewer", in: fixture)!, with: opencode))
        XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "their own")
    }

    func testSwitchingASharedAgentOffTakesEveryCopyAndOnBringsThemBack() throws {
        let fixture = machine()
        let mutations = Mutations(paths: fixture.paths)
        let opencode = assistant("opencode", in: fixture)
        try mutations.shareAgent(agent("reviewer", in: fixture)!, with: opencode)

        try mutations.setCommand(agent("reviewer", in: fixture)!, enabled: false)

        XCTAssertFalse(fixture.exists(fixture.paths.agents.appendingPathComponent("reviewer.md")))
        XCTAssertNil((try? fm.attributesOfItem(atPath: opencode.agentsRoot!.appendingPathComponent("reviewer.md").path)),
                     "the link is parked too, or opencode would still load it")
        let parked = agent("reviewer", in: fixture)
        XCTAssertEqual(parked?.enabled, false)
        XCTAssertFalse(parked?.description.isEmpty ?? true, "a parked link must not hide the real file's text")

        try mutations.setCommand(parked!, enabled: true)

        XCTAssertTrue(fixture.exists(fixture.paths.agents.appendingPathComponent("reviewer.md")))
        XCTAssertEqual(agent("reviewer", in: fixture)?.assistants, ["claude", "opencode"])
        XCTAssertEqual(try String(contentsOf: opencode.agentsRoot!.appendingPathComponent("reviewer.md"), encoding: .utf8).contains("Instructions."), true,
                       "and the link points at a real file again")
    }

    func testACommandSharedToOpencodeGoesWhereOpencodeReadsIt() throws {
        let fixture = machine()
        fixture.command("ship")
        let item = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .command }!
        let opencode = assistant("opencode", in: fixture)

        let link = try Mutations(paths: fixture.paths).shareCommand(item, with: opencode)

        XCTAssertEqual(link.deletingLastPathComponent().deletingLastPathComponent(), fixture.paths.opencodeConfig.deletingLastPathComponent())
        XCTAssertTrue(["command", "commands"].contains(link.deletingLastPathComponent().lastPathComponent))
        XCTAssertFalse(link.path.contains("/.opencode/"), "not the dot-directory opencode never reads")
    }
}
