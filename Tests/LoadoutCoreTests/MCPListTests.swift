import XCTest
@testable import LoadoutCore

/// The MCP list folds same-named personal rows into one — display only. The owners' own rows
/// keep existing for the matrix, the Assistants card and every switch.
final class MCPListTests: XCTestCase {

    private func owner(_ assistant: String, name: String, enabled: Bool = true,
                       usage: Int = 0) -> Item {
        Item(id: "mcp:\(assistant):\(name)", name: name, kind: .mcp, origin: .personal,
             description: "\(name) via \(assistant)",
             enabled: enabled, usage: Usage(count: usage, lastUsed: nil, projectCount: 0),
             assistants: [assistant])
    }

    func testFourOwnersBecomeOneRow() {
        let items = [
            owner("claude", name: "iosef"),
            owner("gemini", name: "iosef"),
            owner("opencode", name: "iosef"),
            owner("antigravity", name: "iosef"),
        ]

        let merged = MCPList.mergeDuplicates(items)

        XCTAssertEqual(merged.count, 1)
        let row = merged[0]
        XCTAssertEqual(row.id, "mcp:merged:iosef")
        XCTAssertEqual(row.name, "iosef")
        XCTAssertEqual(row.assistants, ["claude", "gemini", "opencode", "antigravity"])
        XCTAssertTrue(row.enabled)
        XCTAssertTrue(MCPList.isMerged(row))
    }

    func testANameOnlyOneAssistantHasKeepsItsOwnRow() {
        let single = owner("codex", name: "node_repl")

        let result = MCPList.mergeDuplicates([single])

        XCTAssertEqual(result, [single], "identity, id included — nothing changes for a solo server")
        XCTAssertFalse(MCPList.isMerged(result[0]))
    }

    func testOneRowOnAndOneOffReadsAsOnAndSaysWhoIsOff() {
        let merged = MCPList.mergeDuplicates([
            owner("claude", name: "codegraph"),
            owner("opencode", name: "codegraph", enabled: false),
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].enabled, "on somewhere means the machine is running it")
        XCTAssertEqual(merged[0].assistants, ["claude", "opencode"])
    }

    func testAllCopiesOffStaysOff() {
        let merged = MCPList.mergeDuplicates([
            owner("claude", name: "x", enabled: false),
            owner("cursor", name: "x", enabled: false),
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertFalse(merged[0].enabled)
    }

    func testProjectRowsNeverFoldWithPersonalOrEachOther() {
        let personal = owner("claude", name: "context7")
        let projectA = Item(id: "mcp:app:context7", name: "context7", kind: .mcp,
                            origin: .project("app"), assistants: ["claude"],
                            projectDirectory: "/Users/me/app")
        let projectB = Item(id: "mcp:other:context7", name: "context7", kind: .mcp,
                            origin: .project("other"), assistants: ["claude"],
                            projectDirectory: "/Users/me/other")

        let result = MCPList.mergeDuplicates([personal, projectA, projectB])

        XCTAssertEqual(result.count, 3, "the two repositories stay themselves, and neither folds with yours")
        XCTAssertTrue(result.filter { MCPList.isMerged($0) }.isEmpty,
                      "nothing folds here: one personal row, two project rows of other scopes")
        XCTAssertEqual(result.first?.id, "mcp:claude:context7")
    }

    func testTheLoudestUsageCountWinsAndThePrimaryOwnerSuppliesTheIdentity() throws {
        let loud = owner("claude", name: "iosef", usage: 316)
        var quiet = owner("gemini", name: "iosef", usage: 316)
        quiet.enabled = false
        quiet.description = "gemini's spelling of it"

        let merged = MCPList.mergeDuplicates([loud, quiet])

        XCTAssertEqual(merged[0].usage.count, 316)
        XCTAssertEqual(merged[0].description, "iosef via claude",
                       "the switchable owner's definition describes the row")
    }

    func testOtherKindsPassThroughUntouched() {
        let skill = Item(id: "s", name: "s", kind: .skill, origin: .personal)

        let result = MCPList.mergeDuplicates([skill])

        XCTAssertEqual(result, [skill])
    }

    func testMergingIsIdempotent() {
        let items = [owner("claude", name: "a"), owner("cursor", name: "a"),
                     owner("codex", name: "b")]

        let once = MCPList.mergeDuplicates(items)
        let twice = MCPList.mergeDuplicates(once)

        XCTAssertEqual(once, twice, "folding a folded list changes nothing")
    }
}
