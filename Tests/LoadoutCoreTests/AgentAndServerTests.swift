import XCTest
@testable import LoadoutCore

/// AC11.6–AC11.13 — the last two kinds that could only be deleted, never switched off.
final class AgentAndServerTests: XCTestCase {
    private let fm = FileManager.default

    private func item(_ name: String, in fixture: Fixture, kind: ItemKind) -> Item {
        InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.kind == kind && $0.name == name }!
    }

    // MARK: - Subagents

    func testDisablingAnAgentMovesItNextDoorAndKeepsItListed() throws {
        let fixture = Fixture()
        fixture.agent("explorer")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.setCommand(item("explorer", in: fixture, kind: .agent), enabled: false)

        XCTAssertTrue(fixture.exists(fixture.paths.agentsOff.appendingPathComponent("explorer.md")))
        XCTAssertFalse(fixture.exists(fixture.paths.agents.appendingPathComponent("explorer.md")))
        let parked = item("explorer", in: fixture, kind: .agent)
        XCTAssertFalse(parked.enabled)

        try mutations.setCommand(parked, enabled: true)
        XCTAssertTrue(fixture.exists(fixture.paths.agents.appendingPathComponent("explorer.md")))
    }

    func testAPluginAgentIsRecordedAndReappliedAfterAnUpdate() throws {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["vercel-cli"])
        let plugin = InventoryScanner(paths: fixture.paths).installedPlugins().first!
        let agents = plugin.installPath.appendingPathComponent("agents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try "---\nname: deployment-expert\ndescription: Deploys.\n---\n".write(
            to: agents.appendingPathComponent("deployment-expert.md"), atomically: true, encoding: .utf8
        )
        let mutations = Mutations(paths: fixture.paths)

        try mutations.setCommand(
            item("deployment-expert", in: fixture, kind: .agent), enabled: false, plugin: plugin
        )
        XCTAssertEqual(mutations.records.pluginEntries(of: plugin.id), ["agents/deployment-expert.md"])

        // The new version arrives as a clean copy — the agent back in `agents` and nothing in
        // `agents-off`, which is what the plugin publishes.
        try "---\nname: deployment-expert\ndescription: Nova.\n---\n".write(
            to: agents.appendingPathComponent("deployment-expert.md"), atomically: true, encoding: .utf8
        )
        try fm.removeItem(
            at: plugin.installPath.appendingPathComponent("agents-off/deployment-expert.md")
        )
        XCTAssertEqual(mutations.reapplyDisabledSkills(of: plugin), ["deployment-expert.md"])
        XCTAssertFalse(fixture.exists(agents.appendingPathComponent("deployment-expert.md")))
    }

    func testCreatingASubagentWritesANameField() throws {
        let fixture = Fixture()
        let mutations = Mutations(paths: fixture.paths)

        let file = try mutations.createCommand(
            name: "reviewer", description: "Reviews what everyone else writes.", kind: .agent
        )

        let text = fixture.read(file)
        XCTAssertTrue(text.contains("name: reviewer"), "a subagent is called by its name, not by its file")
        XCTAssertEqual(item("reviewer", in: fixture, kind: .agent).description, "Reviews what everyone else writes.")
    }

    // MARK: - MCP servers

    func testDisablingAServerLiftsOnlyItsEntryOut() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm", command: "npx notebooklm-mcp")
        fixture.mcpServer("paseo", command: "npx paseo-mcp")
        // Something else in the same file, none of our business.
        var root = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.claudeJSON)
        )) as? [String: Any] ?? [:]
        root["numStartups"] = 42
        fixture.write(json: root, to: fixture.paths.claudeJSON)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.setServer(item("notebooklm", in: fixture, kind: .mcp), enabled: false)

        let after = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.claudeJSON)
        )) as? [String: Any] ?? [:]
        let servers = after["mcpServers"] as? [String: Any] ?? [:]
        XCTAssertNil(servers["notebooklm"], "left the file")
        XCTAssertNotNil(servers["paseo"], "the other one stayed")
        XCTAssertEqual(after["numStartups"] as? Int, 42, "the rest of the file was left alone")
        XCTAssertNotNil(mutations.records.server(named: "notebooklm"), "it was kept")
    }

    func testADisabledServerIsStillListedWithItsCommand() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm", command: "npx notebooklm-mcp")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.setServer(item("notebooklm", in: fixture, kind: .mcp), enabled: false)

        let listed = item("notebooklm", in: fixture, kind: .mcp)
        XCTAssertFalse(listed.enabled, "switched off, not vanished")
        XCTAssertEqual(listed.description, "npx notebooklm-mcp", "you can still read what it was")
    }

    func testEnablingPutsBackExactlyWhatWasLifted() throws {
        let fixture = Fixture()
        fixture.write(json: ["mcpServers": [
            "notebooklm": ["command": "npx", "args": ["notebooklm-mcp", "--verbose"], "env": ["KEY": "x"]],
        ]], to: fixture.paths.claudeJSON)
        let mutations = Mutations(paths: fixture.paths)
        let before = fixture.read(fixture.paths.claudeJSON)

        try mutations.setServer(item("notebooklm", in: fixture, kind: .mcp), enabled: false)
        try mutations.setServer(item("notebooklm", in: fixture, kind: .mcp), enabled: true)

        let after = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.claudeJSON)
        )) as? [String: Any] ?? [:]
        let entry = (after["mcpServers"] as? [String: Any])?["notebooklm"] as? [String: Any] ?? [:]
        XCTAssertEqual(entry["command"] as? String, "npx")
        XCTAssertEqual(entry["args"] as? [String], ["notebooklm-mcp", "--verbose"])
        XCTAssertEqual((entry["env"] as? [String: String])?["KEY"], "x")
        XCTAssertTrue(mutations.records.servers().isEmpty, "the record was cleared")
        XCTAssertFalse(before.isEmpty)
    }

    func testAServerThatIsNotThereIsRefusedRatherThanInvented() {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm")
        let mutations = Mutations(paths: fixture.paths)
        let ghost = Item(id: "mcp:personal:ghost", name: "ghost", kind: .mcp, origin: .personal)

        XCTAssertThrowsError(try mutations.setServer(ghost, enabled: false))
        XCTAssertThrowsError(try mutations.setServer(ghost, enabled: true))
    }

    /// Removing one of your own servers takes its entry out of the file for good, leaves the rest of
    /// that file alone, and copies it first — there being no Trash for a few lines of JSON.
    func testRemovingYourOwnServerTakesItOutForGood() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm", command: "npx notebooklm-mcp")
        fixture.mcpServer("paseo", command: "npx paseo-mcp")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.removeServer(item("notebooklm", in: fixture, kind: .mcp))

        let after = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.claudeJSON)
        )) as? [String: Any] ?? [:]
        let servers = after["mcpServers"] as? [String: Any] ?? [:]
        XCTAssertNil(servers["notebooklm"], "gone")
        XCTAssertNotNil(servers["paseo"], "the other one stayed")
        XCTAssertNil(mutations.records.server(named: "notebooklm"), "and not kept as switched off")
        let backups = (fm.enumerator(at: fixture.paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? [])
        XCTAssertTrue(backups.contains(".claude.json"), "the copy before the write is the way back")

        // Listing it again must not resurrect it: the entry and the record are both gone.
        let listed = InventoryScanner(paths: fixture.paths).scanAll().items(kind: .mcp).map(\.name)
        XCTAssertEqual(listed, ["paseo"])
    }

    /// A server that was switched off lives only in Loadout's record — its entry is already out of
    /// the file. Removing it has to forget that record, or the row comes back on the next scan.
    func testRemovingAServerThatWasSwitchedOffForgetsIt() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm", command: "npx notebooklm-mcp")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.setServer(item("notebooklm", in: fixture, kind: .mcp), enabled: false)
        let off = InventoryScanner(paths: fixture.paths).scanAll().items(kind: .mcp).first!
        XCTAssertFalse(off.enabled)

        try mutations.removeServer(off)

        XCTAssertTrue(mutations.records.servers().isEmpty, "the record went with it")
        XCTAssertTrue(
            InventoryScanner(paths: fixture.paths).scanAll().items(kind: .mcp).isEmpty,
            "and it does not come back on the next scan"
        )
    }

    /// The team's file is not ours to cut lines out of, so a repository's server has no removal at
    /// all — the switch is the whole of what this app does to it.
    func testARepositoryServerCannotBeRemoved() throws {
        let fixture = Fixture()
        let repo = fixture.projectRepo("TGC/open-mercato")
        fixture.repositoryMCP(repo, servers: ["linear": "npx linear-mcp"])
        let project = Project(name: "open-mercato", relativePath: "TGC/open-mercato", path: repo)
        let linear = InventoryScanner(paths: fixture.paths).scanAll(project: project)
            .items(kind: .mcp).first!
        let before = fixture.read(fixture.paths.projectMCPJSON(repo))

        XCTAssertThrowsError(try Mutations(paths: fixture.paths).removeServer(linear))
        XCTAssertEqual(fixture.read(fixture.paths.projectMCPJSON(repo)), before)
    }

    /// Switching off a server the repository ships must leave the repository's file untouched —
    /// deleting the line there would take the server from the whole team at their next pull. The
    /// refusal goes in the reader's own config, where Claude Code already keeps that answer.
    func testDecliningARepositoryServerLeavesTheRepositoryFileAlone() throws {
        let fixture = Fixture()
        let repo = fixture.projectRepo("TGC/open-mercato")
        fixture.repositoryMCP(repo, servers: ["linear": "npx linear-mcp"])
        let file = fixture.paths.projectMCPJSON(repo)
        let before = fixture.read(file)
        let mutations = Mutations(paths: fixture.paths)
        let project = Project(name: "open-mercato", relativePath: "TGC/open-mercato", path: repo)
        let linear = InventoryScanner(paths: fixture.paths).scanAll(project: project)
            .items(kind: .mcp).first { $0.name == "linear" }!

        try mutations.setServer(linear, enabled: false)

        XCTAssertEqual(fixture.read(file), before, "the team's file is untouched")
        let after = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.claudeJSON)
        )) as? [String: Any] ?? [:]
        let entry = (after["projects"] as? [String: Any])?[repo.path] as? [String: Any] ?? [:]
        XCTAssertEqual(entry["disabledMcpjsonServers"] as? [String], ["linear"])

        // And back on: the refusal is lifted and the yes is explicit, so Claude stops asking.
        var off = linear
        off.enabled = false
        try mutations.setServer(off, enabled: true)
        let back = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.claudeJSON)
        )) as? [String: Any] ?? [:]
        let reopened = (back["projects"] as? [String: Any])?[repo.path] as? [String: Any] ?? [:]
        XCTAssertEqual(reopened["disabledMcpjsonServers"] as? [String], [])
        XCTAssertEqual(reopened["enabledMcpjsonServers"] as? [String], ["linear"])
        XCTAssertEqual(fixture.read(file), before, "still untouched on the way back")
    }

    func testTheFileIsSnapshottedBeforeItIsChanged() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.setServer(item("notebooklm", in: fixture, kind: .mcp), enabled: false)

        let backups = (fm.enumerator(at: fixture.paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? [])
        XCTAssertTrue(backups.contains(".claude.json"), "there is always a copy before a write")
    }
}

extension AgentAndServerTests {

    /// Two checkouts can be called the same thing. Acting on the folder's name switched off a
    /// server belonging to the other one.
    func testTwoProjectsWithTheSameFolderNameDoNotCollide() throws {
        let fixture = Fixture()
        fixture.write(json: ["projects": [
            "/Users/me/work/app": ["mcpServers": ["shared": ["command": "work"]]],
            "/Users/me/personal/app": ["mcpServers": ["shared": ["command": "personal"]]],
        ]], to: fixture.paths.claudeJSON)
        let mutations = Mutations(paths: fixture.paths)
        let items = InventoryScanner(paths: fixture.paths).scanAll().items
            .filter { $0.kind == .mcp && $0.name == "shared" }
        XCTAssertEqual(items.count, 2)
        let work = items.first { $0.projectDirectory == "/Users/me/work/app" }!

        try mutations.setServer(work, enabled: false)

        let after = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.claudeJSON)
        )) as? [String: Any] ?? [:]
        let projects = after["projects"] as? [String: Any] ?? [:]
        let workServers = (projects["/Users/me/work/app"] as? [String: Any])?["mcpServers"] as? [String: Any]
        let otherServers = (projects["/Users/me/personal/app"] as? [String: Any])?["mcpServers"] as? [String: Any]
        XCTAssertNil(workServers?["shared"], "the one switched off left")
        XCTAssertNotNil(otherServers?["shared"], "the other project's stayed")

        // And it goes back to the right place.
        let parked = InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.kind == .mcp && $0.name == "shared" && !$0.enabled }!
        try mutations.setServer(parked, enabled: true)
        let back = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.claudeJSON)
        )) as? [String: Any] ?? [:]
        let backProjects = back["projects"] as? [String: Any] ?? [:]
        let backWork = (backProjects["/Users/me/work/app"] as? [String: Any])?["mcpServers"] as? [String: Any]
        XCTAssertEqual((backWork?["shared"] as? [String: Any])?["command"] as? String, "work")
    }

    /// A record can outlive its server: someone puts the entry back by hand. The live one wins,
    /// rather than two rows sharing an id and the stale copy overwriting the working config.
    func testARecordThatOutlivedItsServerDoesNotDoubleTheRow() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm", command: "npx notebooklm-mcp")
        let mutations = Mutations(paths: fixture.paths)
        try mutations.setServer(item("notebooklm", in: fixture, kind: .mcp), enabled: false)

        // Put back by hand, with a different configuration.
        fixture.write(json: ["mcpServers": ["notebooklm": ["command": "npx something-else"]]],
                      to: fixture.paths.claudeJSON)

        let rows = InventoryScanner(paths: fixture.paths).scanAll().items
            .filter { $0.kind == .mcp && $0.name == "notebooklm" }

        XCTAssertEqual(rows.count, 1, "one row, not two sharing an id")
        XCTAssertTrue(rows[0].enabled)
        XCTAssertEqual(rows[0].description, "npx something-else", "what is in the file is what counts")
    }
}

/// What five agents driving the interface found, each one kept here so it cannot come back.
extension AgentAndServerTests {

    func testASubagentCannotBeSavedWithoutTheNameItIsCalledBy() throws {
        let fixture = Fixture()
        fixture.agent("reviewer")
        let mutations = Mutations(paths: fixture.paths)
        let agent = item("reviewer", in: fixture, kind: .agent)
        let before = fixture.read(agent.path!)

        XCTAssertThrowsError(try mutations.save(agent, contents: "---\ndescription: no name\n---\n"))
        XCTAssertEqual(fixture.read(agent.path!), before, "the file was left alone")
    }

    func testASubagentWhoseNameDisagreesWithItsFileSaysSo() throws {
        let fixture = Fixture()
        try fm.createDirectory(at: fixture.paths.agents, withIntermediateDirectories: true)
        try "---\nname: another-name\ndescription: x\n---\n".write(
            to: fixture.paths.agents.appendingPathComponent("mismatched.md"),
            atomically: true, encoding: .utf8
        )

        XCTAssertEqual(
            item("mismatched", in: fixture, kind: .agent).warning,
            "The name in the frontmatter (another-name) doesn't match the file (mismatched)."
        )
    }

    func testTwoWritesInTheSameSecondKeepBothCopies() throws {
        let fixture = Fixture()
        fixture.skill("twice")
        let mutations = Mutations(paths: fixture.paths)
        let skill = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.name == "twice" }!

        let stamp = Date()
        try mutations.backups.snapshot(skill.path!, stamp: stamp)
        try "---\nname: twice\ndescription: changed in the meantime.\n---\n".write(
            to: skill.path!, atomically: true, encoding: .utf8
        )
        try mutations.backups.snapshot(skill.path!, stamp: stamp)

        let copies = (fm.enumerator(at: fixture.paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL) } ?? []).filter { $0.pathExtension == "md" }
        XCTAssertEqual(copies.count, 2, "the second copy must not erase the first")
        let texts = copies.map { fixture.read($0) }
        XCTAssertTrue(texts.contains { $0.contains("Does things.") }, "the one from before it all survives")
        XCTAssertTrue(texts.contains { $0.contains("changed in the meantime") })
    }

    func testAnUnreadableRecordIsReportedRatherThanReadAsEmpty() throws {
        let fixture = Fixture()
        let records = OffRecords(paths: fixture.paths)
        try fm.createDirectory(at: fixture.paths.support, withIntermediateDirectories: true)
        try "{{ this is not json".write(to: records.serversFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(records.servers(), [:], "it does not invent what it cannot read")
        XCTAssertEqual(
            records.unreadable().map(\.lastPathComponent), ["mcp-off.json"],
            "but it says the file exists and could not be read — otherwise a switched-off server vanishes with no explanation"
        )
    }
}
