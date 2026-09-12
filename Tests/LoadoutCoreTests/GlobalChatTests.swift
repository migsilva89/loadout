import XCTest
@testable import LoadoutCore

final class GlobalChatTests: XCTestCase {
    func testAttachmentsWithSameNameStayIndependentAndDetachRemovesOnlyItsCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ChatContext(id: "claude:shared", name: "shared", origin: root.appendingPathComponent("claude"))
        let second = ChatContext(id: "codex:shared", name: "shared", origin: root.appendingPathComponent("codex"))
        for context in [first, second] {
            try FileManager.default.createDirectory(at: context.origin, withIntermediateDirectories: true)
            try context.id.write(to: context.origin.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let workspace = GlobalChatWorkspace(root: root.appendingPathComponent("copy"))
        try workspace.prepare([first, second])
        let proposalID = first.prefix + "SKILL.md"
        try "changed".write(to: workspace.root.appendingPathComponent(proposalID), atomically: true, encoding: .utf8)
        try workspace.prepare([first, second])
        XCTAssertEqual(workspace.changes([first, second]).map(\.id), [proposalID])
        XCTAssertEqual(try String(contentsOf: first.origin.appendingPathComponent("SKILL.md"), encoding: .utf8), first.id)
        XCTAssertNil(second.relativePath(for: proposalID))
        XCTAssertNil(first.relativePath(for: first.prefix + "../outside"))
        try workspace.remove(first)
        XCTAssertTrue(workspace.changes([second]).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent(second.prefix + "SKILL.md").path))
    }

    func testEmptyGlobalWorkspaceDoesNotCopyUserHomeAndLinksAreOmitted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = GlobalChatWorkspace(root: root.appendingPathComponent("copy"))
        try workspace.prepare([])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.root.path), [])
        let origin = root.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("private.txt")
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: origin.appendingPathComponent("link"), withDestinationURL: outside)
        let context = ChatContext(id: "linked", name: "linked", origin: origin)
        try workspace.prepare([context])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent(context.prefix + "link").path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
    }

    func testConversationDecodesOldHistoryAndRoundTripsGlobalAttachments() throws {
        let old = AskConversation(id: "old", itemID: "skill", cliID: "codex", originPath: "/old", startedAt: Date(), title: "Old question")
        let oldData = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(AskConversation.self, from: oldData).contexts)
        var global = old
        global.contexts = [ChatContext(id: "skill", name: "skill", origin: URL(fileURLWithPath: "/skills/one"))]
        XCTAssertEqual(try JSONDecoder().decode(AskConversation.self, from: JSONEncoder().encode(global)), global)
    }

    func testBriefingReflectsCurrentAttachmentsAndEmptyGlobalContext() {
        let context = ChatContext(id: "a", name: "one", origin: URL(fileURLWithPath: "/private/origin"))
        let attached = GlobalChatWorkspace.briefing(contexts: [context])
        XCTAssertTrue(attached.contains(context.prefix + "SKILL.md"))
        XCTAssertFalse(attached.contains("/private/origin"))
        XCTAssertFalse(GlobalChatWorkspace.briefing(contexts: []).contains(context.prefix))
        XCTAssertTrue(GlobalChatWorkspace.briefing(contexts: []).contains("No files are attached"))
        let question = "Can you compare these?\nKeep the answer brief."
        XCTAssertEqual(GlobalChatWorkspace.userMessage(from: GlobalChatWorkspace.prompt(message: question, contexts: [context])), question)
        XCTAssertEqual(GlobalChatWorkspace.userMessage(from: "An older conversation"), "An older conversation")
    }
}
