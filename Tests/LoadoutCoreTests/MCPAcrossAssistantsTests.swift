import XCTest
@testable import LoadoutCore

/// MCP servers from three owners in one list: each row says whose it is, and the switch writes
/// only the owner's own file, the owner's own way.
final class MCPAcrossAssistantsTests: XCTestCase {

    private func antigravityConfig(_ fixture: Fixture, servers: [String: Any]) -> URL {
        let file = fixture.paths.antigravityConfig.appendingPathComponent("mcp_config.json")
        fixture.write(json: ["mcpServers": servers], to: file)
        return file
    }

    private func servers(_ fixture: Fixture) -> [Item] {
        InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .mcp }
    }

    // MARK: - Reading

    func testEachRowCarriesItsOwner() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm")
        let file = antigravityConfig(fixture, servers: [
            "sqlite": ["command": "sqlite-mcp", "args": ["db.sqlite"]],
            "remote": ["serverUrl": "https://mcp.example.com/sse", "disabled": true],
        ])

        let rows = servers(fixture)
        let claude = try XCTUnwrap(rows.first { $0.name == "notebooklm" })
        let sqlite = try XCTUnwrap(rows.first { $0.name == "sqlite" })
        let remote = try XCTUnwrap(rows.first { $0.name == "remote" })

        XCTAssertEqual(claude.assistants, ["claude"])
        XCTAssertEqual(claude.id, "mcp:personal:notebooklm", "Claude's ids are what 0.4.x users have")
        XCTAssertEqual(sqlite.assistants, ["antigravity"])
        XCTAssertEqual(sqlite.id, "mcp:antigravity:sqlite")
        XCTAssertEqual(sqlite.description, "sqlite-mcp db.sqlite")
        XCTAssertEqual(sqlite.path, file)
        XCTAssertTrue(sqlite.enabled)
        XCTAssertEqual(remote.description, "https://mcp.example.com/sse")
        XCTAssertFalse(remote.enabled)
    }

    func testTheSameNameInTwoOwnersIsTwoRowsAndNeverInMoreThanOne() {
        let fixture = Fixture()
        fixture.mcpServer("github")
        antigravityConfig(fixture, servers: ["github": ["command": "gh-mcp"]])

        let rows = servers(fixture).filter { $0.name == "github" }

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)), ["mcp:personal:github", "mcp:antigravity:github"])
        XCTAssertTrue(Filtering.filter(rows, by: .multiple).isEmpty)
        XCTAssertEqual(Filtering.filter(rows, by: .one("antigravity")).map(\.id), ["mcp:antigravity:github"])
    }

    func testCodexRowsComeFromWhatCodexResolvedWithEnabledDefaultingToTrue() throws {
        let fixture = Fixture()
        let config: [String: Any] = ["mcp_servers": [
            "node_repl": ["command": "/bin/node_repl", "args": [], "enabled": true, "env": ["A": "1"]],
            "computer-use": ["command": "./cua", "args": ["mcp"], "enabled": false],
            "plain": ["url": "https://x.example/mcp"],
        ]]

        let rows = try CodexPlugins(paths: fixture.paths)
            .inventory(installed: ["marketplaces": []], skills: ["data": []], settings: ["config": config])
            .items.filter { $0.kind == .mcp }

        XCTAssertEqual(rows.map(\.name), ["computer-use", "node_repl", "plain"])
        XCTAssertEqual(rows.map(\.enabled), [false, true, true])
        XCTAssertEqual(rows.map(\.assistants), [["codex"], ["codex"], ["codex"]])
        XCTAssertEqual(rows[2].description, "https://x.example/mcp")
        XCTAssertEqual(rows[0].description, "./cua mcp")
        XCTAssertEqual(rows[0].path, fixture.paths.codexConfig)
    }

    func testAMissingOrBrokenAntigravityFileYieldsNoRowsAndNoError() {
        let fixture = Fixture()
        XCTAssertTrue(AntigravityMCP(paths: fixture.paths).items().isEmpty)
        let file = fixture.paths.antigravityConfig.appendingPathComponent("mcp_config.json")
        try! FileManager.default.createDirectory(at: fixture.paths.antigravityConfig, withIntermediateDirectories: true)
        try! "{ not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(AntigravityMCP(paths: fixture.paths).items().isEmpty)
    }

    // MARK: - Switching Antigravity's

    func testSwitchingAnAntigravityServerOffFlipsOnlyTheFlag() throws {
        let fixture = Fixture()
        let file = antigravityConfig(fixture, servers: [
            "sqlite": ["command": "sqlite-mcp", "args": ["db.sqlite"], "env": ["RO": "1"]],
            "other": ["serverUrl": "https://o.example"],
        ])
        let item = try XCTUnwrap(servers(fixture).first { $0.name == "sqlite" })

        try Mutations(paths: fixture.paths).setServer(item, enabled: false)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let all = root["mcpServers"] as! [String: Any]
        let sqlite = all["sqlite"] as! [String: Any]
        XCTAssertEqual(sqlite["disabled"] as? Bool, true)
        XCTAssertEqual(sqlite["command"] as? String, "sqlite-mcp")
        XCTAssertEqual(sqlite["args"] as? [String], ["db.sqlite"])
        XCTAssertEqual(sqlite["env"] as? [String: String], ["RO": "1"])
        XCTAssertEqual((all["other"] as? [String: Any])?["serverUrl"] as? String, "https://o.example")
        XCTAssertFalse(try XCTUnwrap(servers(fixture).first { $0.name == "sqlite" }).enabled)

        // Claude's file was never involved.
        XCTAssertFalse(fixture.exists(fixture.paths.claudeJSON))
    }

    func testSwitchingItBackOnRemovesTheFlagAndTheFileWasSnapshottedFirst() throws {
        let fixture = Fixture()
        let file = antigravityConfig(fixture, servers: ["sqlite": ["command": "sqlite-mcp", "disabled": true]])
        let item = try XCTUnwrap(servers(fixture).first { $0.name == "sqlite" })
        XCTAssertFalse(item.enabled)

        try Mutations(paths: fixture.paths).setServer(item, enabled: true)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let sqlite = (root["mcpServers"] as! [String: Any])["sqlite"] as! [String: Any]
        XCTAssertNil(sqlite["disabled"])
        XCTAssertTrue(try XCTUnwrap(servers(fixture).first { $0.name == "sqlite" }).enabled)
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.backups.path)
        XCTAssertFalse(snapshots.isEmpty, "a snapshot is taken before every write")
    }

    func testRemovingAnAntigravityServerTakesOnlyItsEntryOut() throws {
        let fixture = Fixture()
        let file = antigravityConfig(fixture, servers: [
            "sqlite": ["command": "sqlite-mcp"], "other": ["command": "o"],
        ])
        let item = try XCTUnwrap(servers(fixture).first { $0.name == "sqlite" })

        try Mutations(paths: fixture.paths).removeServer(item)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual((root["mcpServers"] as! [String: Any]).keys.sorted(), ["other"])
    }

    func testAnAntigravityServerThatIsGoneIsRefusedAndNothingIsWritten() throws {
        let fixture = Fixture()
        let file = antigravityConfig(fixture, servers: ["real": ["command": "r"]])
        let before = try Data(contentsOf: file)
        let ghost = Item(id: "mcp:antigravity:ghost", name: "ghost", kind: .mcp, origin: .personal,
                         assistants: ["antigravity"])

        XCTAssertThrowsError(try Mutations(paths: fixture.paths).setServer(ghost, enabled: false))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testABrokenAntigravityFileIsNeverOverwritten() throws {
        let fixture = Fixture()
        let file = fixture.paths.antigravityConfig.appendingPathComponent("mcp_config.json")
        try FileManager.default.createDirectory(at: fixture.paths.antigravityConfig, withIntermediateDirectories: true)
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        let item = Item(id: "mcp:antigravity:x", name: "x", kind: .mcp, origin: .personal, assistants: ["antigravity"])

        XCTAssertThrowsError(try Mutations(paths: fixture.paths).setServer(item, enabled: false))
        XCTAssertEqual(fixture.read(file), "{ not json")
    }

    // MARK: - Codex: what the app refuses without Codex

    func testACodexServerIsNeverRemovedByLoadout() {
        let fixture = Fixture()
        let item = Item(id: "mcp:codex:node_repl", name: "node_repl", kind: .mcp, origin: .personal, assistants: ["codex"])
        XCTAssertThrowsError(try Mutations(paths: fixture.paths).removeServer(item))
    }

    func testSwitchingACodexServerWithoutCodexFailsWithoutTouchingClaudesFile() {
        let fixture = Fixture()
        fixture.mcpServer("node_repl")
        let before = fixture.read(fixture.paths.claudeJSON)
        let item = Item(id: "mcp:codex:node_repl", name: "node_repl", kind: .mcp, origin: .personal, assistants: ["codex"])

        XCTAssertThrowsError(try Mutations(paths: fixture.paths).setServer(item, enabled: false))
        XCTAssertEqual(fixture.read(fixture.paths.claudeJSON), before)
    }

    // MARK: - Filters

    func testNeverUsedDoesNotAccuseAServerWhoseOwnerLeavesNoTrace() {
        let claude = Item(id: "mcp:personal:a", name: "a", kind: .mcp, origin: .personal, assistants: ["claude"])
        let codex = Item(id: "mcp:codex:b", name: "b", kind: .mcp, origin: .personal, assistants: ["codex"])
        let agy = Item(id: "mcp:antigravity:c", name: "c", kind: .mcp, origin: .personal, assistants: ["antigravity"])
        let skill = Item(id: "s", name: "s", kind: .skill, origin: .personal, assistants: ["codex"])

        let unused = Filtering.filter([claude, codex, agy, skill], by: .neverUsed)

        XCTAssertEqual(unused.map(\.id), ["mcp:personal:a", "s"])
    }

    func testOwnerFallsBackToClaudeForAnUnmarkedRow() {
        let legacy = Item(id: "mcp:personal:a", name: "a", kind: .mcp, origin: .personal)
        XCTAssertEqual(Mutations.owner(of: legacy), "claude")
    }
}
