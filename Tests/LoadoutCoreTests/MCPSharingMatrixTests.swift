import XCTest
@testable import LoadoutCore

/// The sharing matrix and the four JSON-config stores behind it: Cursor, Gemini CLI, Windsurf
/// and opencode read, switched, added and shared — each in its own format, each write
/// snapshotted first.
final class MCPSharingMatrixTests: XCTestCase {

    private func store(_ fixture: Fixture, _ assistant: String) -> MCPStore {
        try! XCTUnwrap(MCPStore.store(assistant: assistant, paths: fixture.paths))
    }

    private func json(_ fixture: Fixture, _ assistant: String) -> JSONMCP {
        JSONMCP(paths: fixture.paths, store: store(fixture, assistant))
    }

    private func rows(_ fixture: Fixture) -> [Item] {
        InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .mcp }
    }

    // MARK: - Reading

    func testClassicStoresReadRowsInTheOwnersFormat() throws {
        let fixture = Fixture()
        fixture.write(json: ["mcpServers": [
            "codegraph": ["command": "codegraph", "args": ["serve", "--mcp"]],
        ]], to: fixture.paths.cursorMCP)
        fixture.write(json: [
            "model": "gemini-2.5",
            "mcpServers": ["sqlite": ["command": "sqlite-mcp"]],
        ], to: fixture.paths.geminiSettings)
        fixture.write(json: ["mcpServers": [
            "remote": ["serverUrl": "https://mcp.example.com/sse"],
        ]], to: fixture.paths.windsurfMCP)

        let all = rows(fixture)
        let codegraph = try XCTUnwrap(all.first { $0.id == "mcp:cursor:codegraph" })
        let sqlite = try XCTUnwrap(all.first { $0.id == "mcp:gemini:sqlite" })
        let remote = try XCTUnwrap(all.first { $0.id == "mcp:windsurf:remote" })

        XCTAssertEqual(codegraph.description, "codegraph serve --mcp")
        XCTAssertTrue(codegraph.enabled)
        XCTAssertEqual(codegraph.path, fixture.paths.cursorMCP)
        XCTAssertEqual(sqlite.assistants, ["gemini"])
        XCTAssertEqual(remote.description, "https://mcp.example.com/sse")
    }

    func testTheGeminiSettingsKeepTheirOwnKeys() throws {
        let fixture = Fixture()
        let file = fixture.paths.geminiSettings
        fixture.write(json: ["model": "gemini-2.5", "mcpServers": ["a": ["command": "x"]]], to: file)

        try json(fixture, "gemini").setServer(named: "a", enabled: false)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(root["model"] as? String, "gemini-2.5", "the assistant's other settings are untouched")
        XCTAssertNil((root["mcpServers"] as? [String: Any])?["a"], "off is the entry lifted out")
    }

    func testOpencodeRowsReadItsOwnEntryShape() throws {
        let fixture = Fixture()
        fixture.write(json: ["mcp": [
            "codegraph": ["type": "local", "command": ["codegraph", "serve", "--mcp"],
                          "environment": ["KEY": "1"], "enabled": true],
            "sleepy": ["type": "local", "command": ["sleep-mcp"], "enabled": false],
            "remote": ["type": "remote", "url": "https://x.example/mcp"],
        ]], to: fixture.paths.opencodeConfig)

        let all = rows(fixture)
        let codegraph = try XCTUnwrap(all.first { $0.id == "mcp:opencode:codegraph" })
        let sleepy = try XCTUnwrap(all.first { $0.id == "mcp:opencode:sleepy" })
        let remote = try XCTUnwrap(all.first { $0.id == "mcp:opencode:remote" })

        XCTAssertEqual(codegraph.description, "codegraph serve --mcp")
        XCTAssertTrue(codegraph.enabled)
        XCTAssertFalse(sleepy.enabled)
        XCTAssertEqual(remote.description, "https://x.example/mcp")
        XCTAssertTrue(remote.enabled)
    }

    // MARK: - Switching

    func testSwitchingAnOpencodeServerFlipsOnlyItsEnabledFlag() throws {
        let fixture = Fixture()
        let file = fixture.paths.opencodeConfig
        fixture.write(json: ["mcp": [
            "codegraph": ["type": "local", "command": ["codegraph", "serve"],
                          "environment": ["KEY": "1"], "enabled": true],
        ]], to: file)
        let item = try XCTUnwrap(rows(fixture).first { $0.id == "mcp:opencode:codegraph" })

        try Mutations(paths: fixture.paths).setServer(item, enabled: false)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let entry = (root["mcp"] as! [String: Any])["codegraph"] as! [String: Any]
        XCTAssertEqual(entry["enabled"] as? Bool, false)
        XCTAssertEqual(entry["command"] as? [String], ["codegraph", "serve"])
        XCTAssertEqual(entry["environment"] as? [String: String], ["KEY": "1"])
        XCTAssertFalse(try XCTUnwrap(rows(fixture).first { $0.id == "mcp:opencode:codegraph" }).enabled)
        XCTAssertFalse(fixture.exists(fixture.paths.claudeJSON), "Claude's file was never involved")
    }

    func testSwitchingACursorServerOffLiftsTheEntryIntoARecordOfItsOwn() throws {
        let fixture = Fixture()
        let file = fixture.paths.cursorMCP
        fixture.write(json: ["mcpServers": [
            "codegraph": ["command": "codegraph", "args": ["serve"]],
            "other": ["command": "o"],
        ]], to: file)
        // Claude has a server of the same name, switched off and recorded: the two records
        // must not collide.
        try OffRecords(paths: fixture.paths).rememberServer(
            "{\"command\":\"claude-copy\"}", named: "codegraph", project: nil, assistant: "claude"
        )
        let item = try XCTUnwrap(rows(fixture).first { $0.id == "mcp:cursor:codegraph" })

        try Mutations(paths: fixture.paths).setServer(item, enabled: false)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual((root["mcpServers"] as! [String: Any]).keys.sorted(), ["other"])
        let records = OffRecords(paths: fixture.paths)
        XCTAssertEqual(records.server(named: "codegraph", project: nil, assistant: "cursor"),
                       "{\"args\":[\"serve\"],\"command\":\"codegraph\"}")
        XCTAssertEqual(records.server(named: "codegraph", project: nil, assistant: "claude"),
                       "{\"command\":\"claude-copy\"}", "the other assistant's record is untouched")
        // Off, not forgotten: the row is still there, reading from the record.
        let off = try XCTUnwrap(rows(fixture).first { $0.id == "mcp:cursor:codegraph" })
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(off.description, "codegraph serve")
    }

    func testSwitchingItBackOnRestoresTheEntryAndClearsTheRecord() throws {
        let fixture = Fixture()
        let file = fixture.paths.cursorMCP
        fixture.write(json: ["mcpServers": ["other": ["command": "o"]]], to: file)
        try json(fixture, "cursor").addServer(
            named: "codegraph", entry: MCPEntry(command: "codegraph", args: ["serve"])
        )
        let item = try XCTUnwrap(rows(fixture).first { $0.id == "mcp:cursor:codegraph" })
        try Mutations(paths: fixture.paths).setServer(item, enabled: false)

        try Mutations(paths: fixture.paths).setServer(
            try XCTUnwrap(rows(fixture).first { $0.id == "mcp:cursor:codegraph" }), enabled: true
        )

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let entry = (root["mcpServers"] as! [String: Any])["codegraph"] as! [String: Any]
        XCTAssertEqual(entry["command"] as? String, "codegraph")
        XCTAssertNil(OffRecords(paths: fixture.paths).server(named: "codegraph", project: nil,
                                                             assistant: "cursor"))
        XCTAssertTrue(try XCTUnwrap(rows(fixture).first { $0.id == "mcp:cursor:codegraph" }).enabled)
    }

    // MARK: - Adding

    func testAddingAServerStartsTheFileAndTranslatesTheEntry() throws {
        let fixture = Fixture()

        try json(fixture, "opencode").addServer(
            named: "codegraph",
            entry: MCPEntry(command: "codegraph", args: ["serve", "--mcp"], env: ["KEY": "1"])
        )

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.opencodeConfig)
        ) as! [String: Any]
        let entry = (root["mcp"] as! [String: Any])["codegraph"] as! [String: Any]
        XCTAssertEqual(entry["type"] as? String, "local")
        XCTAssertEqual(entry["command"] as? [String], ["codegraph", "serve", "--mcp"])
        XCTAssertEqual(entry["environment"] as? [String: String], ["KEY": "1"])
        XCTAssertEqual(entry["enabled"] as? Bool, true)
    }

    func testAddingANameThatIsThereIsRefusedAndChangesNothing() throws {
        let fixture = Fixture()
        let file = fixture.paths.cursorMCP
        fixture.write(json: ["mcpServers": ["codegraph": ["command": "old"]]], to: file)
        let before = try Data(contentsOf: file)

        XCTAssertThrowsError(try json(fixture, "cursor").addServer(
            named: "codegraph", entry: MCPEntry(command: "new")
        ))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testABrokenFileIsNeverOverwrittenByAnAdd() throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(
            at: fixture.paths.cursorMCP.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "{ not json".write(to: fixture.paths.cursorMCP, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try json(fixture, "cursor").addServer(
            named: "x", entry: MCPEntry(command: "x")
        ))
        XCTAssertEqual(fixture.read(fixture.paths.cursorMCP), "{ not json")
    }

    // MARK: - Removing

    func testRemovingAnOffServerForgetsTheRecordToo() throws {
        let fixture = Fixture()
        let file = fixture.paths.cursorMCP
        fixture.write(json: ["mcpServers": ["codegraph": ["command": "codegraph"]]], to: file)
        let item = try XCTUnwrap(rows(fixture).first { $0.id == "mcp:cursor:codegraph" })
        try Mutations(paths: fixture.paths).setServer(item, enabled: false)

        try Mutations(paths: fixture.paths).removeServer(item)

        XCTAssertNil(OffRecords(paths: fixture.paths).server(named: "codegraph", project: nil,
                                                             assistant: "cursor"))
        XCTAssertFalse(rows(fixture).contains { $0.id == "mcp:cursor:codegraph" })
    }

    // MARK: - Translation

    func testAClassicEntryRendersInEveryFormat() {
        let entry = MCPEntry(command: "codegraph", args: ["serve"], env: ["K": "1"])

        let classic = entry.rendered(for: .classic)
        XCTAssertEqual(classic["command"] as? String, "codegraph")
        XCTAssertEqual(classic["args"] as? [String], ["serve"])
        XCTAssertEqual(classic["env"] as? [String: String], ["K": "1"])

        let opencode = entry.rendered(for: .opencode)
        XCTAssertEqual(opencode["type"] as? String, "local")
        XCTAssertEqual(opencode["command"] as? [String], ["codegraph", "serve"])
        XCTAssertEqual(opencode["environment"] as? [String: String], ["K": "1"])
    }

    func testARemoteEntryKeepsItsMeaningInEveryFormat() throws {
        let fixture = Fixture()
        let url = "https://mcp.example.com/sse"

        let windsurf = MCPEntry(url: url).rendered(for: .classic)
        XCTAssertEqual(windsurf["url"] as? String, url)

        let antigravity = MCPEntry(url: url).rendered(for: .antigravity)
        XCTAssertEqual(antigravity["serverUrl"] as? String, url)
        XCTAssertNil(antigravity["url"])

        let opencode = MCPEntry(url: url).rendered(for: .opencode)
        XCTAssertEqual(opencode["type"] as? String, "remote")
        XCTAssertEqual(opencode["url"] as? String, url)

        // A round trip through another assistant keeps the description the row shows.
        try json(fixture, "cursor").addServer(named: "remote", entry: MCPEntry(url: url))
        let row = try XCTUnwrap(rows(fixture).first { $0.id == "mcp:cursor:remote" })
        XCTAssertEqual(row.description, url)
    }

    // MARK: - Sharing between assistants

    func testSharingCopiesTheDefinitionIntoTheOtherAssistantsOwnFormat() throws {
        let fixture = Fixture()
        fixture.mcpServer("codegraph", command: "codegraph serve --mcp")
        let source = try XCTUnwrap(rows(fixture).first { $0.id == "mcp:personal:codegraph" })

        try Mutations(paths: fixture.paths).copyServer(from: source, to: "opencode")

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.opencodeConfig)
        ) as! [String: Any]
        let entry = (root["mcp"] as! [String: Any])["codegraph"] as! [String: Any]
        XCTAssertEqual(entry["type"] as? String, "local")
        XCTAssertEqual(entry["command"] as? [String], ["codegraph serve --mcp"])
    }

    func testSharingIntoCodexIsRefusedWithTheCommandToDoIt() {
        let fixture = Fixture()
        fixture.mcpServer("codegraph")
        let source = try! XCTUnwrap(rows(fixture).first { $0.id == "mcp:personal:codegraph" })

        XCTAssertThrowsError(try Mutations(paths: fixture.paths).copyServer(from: source, to: "codex")) {
            XCTAssertTrue(($0 as? LoadoutError)?.errorDescription?.contains("codex mcp add") == true)
        }
    }

    func testSharingAnAssistantItsAlreadyHasIsANoOp() throws {
        let fixture = Fixture()
        fixture.mcpServer("codegraph")
        let source = try XCTUnwrap(rows(fixture).first { $0.id == "mcp:personal:codegraph" })

        try Mutations(paths: fixture.paths).copyServer(from: source, to: "claude")

        XCTAssertFalse(fixture.exists(fixture.paths.opencodeConfig))
    }

    // MARK: - The matrix itself

    private func item(_ name: String, assistant: String, enabled: Bool = true) -> Item {
        Item(id: "mcp:\(assistant):\(name)", name: name, kind: .mcp, origin: .personal,
             description: "cmd", enabled: enabled, assistants: [assistant])
    }

    func testRowsGroupServersByNameAcrossAssistants() {
        let items = [
            item("codegraph", assistant: "claude"),
            item("codegraph", assistant: "cursor"),
            item("codegraph", assistant: "opencode", enabled: false),
            item("onlymine", assistant: "claude"),
        ]

        let matrix = MCPMatrix.rows(
            items: items, assistants: ["claude", "codex", "cursor", "opencode"]
        )

        XCTAssertEqual(matrix.map(\.name), ["codegraph", "onlymine"])
        let codegraph = matrix[0]
        XCTAssertEqual(codegraph.cells["claude"]?.state, .on)
        XCTAssertEqual(codegraph.cells["cursor"]?.state, .on)
        XCTAssertEqual(codegraph.cells["opencode"]?.state, .off)
        XCTAssertEqual(codegraph.cells["codex"]?.state, .absent)
        XCTAssertEqual(codegraph.onCount, 2)
        XCTAssertEqual(matrix[1].cells["cursor"]?.state, .absent)
    }

    func testCodexCellsSayWhatLoadoutWillNotDo() {
        let matrix = MCPMatrix.rows(items: [item("a", assistant: "claude")],
                                    assistants: ["claude", "codex"])
        XCTAssertTrue(matrix[0].cells["codex"]?.refusal?.contains("codex mcp add") == true)
        XCTAssertNil(matrix[0].cells["claude"]?.refusal)
    }

    func testProjectScopedServersStayOutOfTheMatrix() {
        let project = Item(id: "mcp:proj:a", name: "a", kind: .mcp,
                           origin: .project("app"), assistants: ["claude"],
                           projectDirectory: "/Users/me/app")
        let matrix = MCPMatrix.rows(items: [project], assistants: ["claude"])
        XCTAssertTrue(matrix.isEmpty)
    }

    func testColumnsAreOnlyTheAssistantsWhoseConfigsLoadoutKnows() {
        let fixture = Fixture()
        let assistants = ["claude", "codex", "antigravity", "cursor", "gemini", "windsurf",
                          "opencode", "trae"].map {
            Assistant(id: $0, label: $0, skillsRoot: fixture.paths.home.appendingPathComponent(".\($0)/skills"))
        }

        let columns = MCPMatrix.columns(paths: fixture.paths, assistants: assistants)

        XCTAssertEqual(columns.map(\.id), ["claude", "codex", "antigravity", "cursor", "gemini",
                                           "windsurf", "opencode"])
    }

    func testTheScannerShowsEveryOwnerSideBySide() throws {
        let fixture = Fixture()
        fixture.mcpServer("shared")
        fixture.write(json: ["mcpServers": ["shared": ["command": "shared"]]],
                      to: fixture.paths.cursorMCP)
        fixture.write(json: ["mcp": ["solo": ["type": "local", "command": ["solo"]]]],
                      to: fixture.paths.opencodeConfig)

        let shared = rows(fixture).filter { $0.name == "shared" }

        XCTAssertEqual(Set(shared.flatMap(\.assistants)), ["claude", "cursor"])
        XCTAssertTrue(rows(fixture).contains { $0.id == "mcp:opencode:solo" })
    }
}
