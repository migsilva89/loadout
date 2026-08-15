import XCTest
@testable import LoadoutCore

/// Loadout remembers conversations by id, never by content — the assistant keeps the exchanges
/// themselves. So what is checked here is that the right ones are offered for the skill on screen,
/// that the list stays bounded, and that reading a saved exchange back works against a real
/// transcript file of the shape the `claude` CLI writes.
final class AskConversationTests: XCTestCase {
    private let skillFolder = URL(fileURLWithPath: "/Users/x/.claude/skills/demo")

    private func conversation(
        _ id: String, item: String = "skill:demo", cli: String = "claude",
        origin: URL? = nil, day: Int, title: String = "asked something"
    ) -> AskConversation {
        AskConversation(
            id: id, itemID: item, cliID: cli,
            originPath: (origin ?? skillFolder).standardizedFileURL.path,
            startedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
            title: title
        )
    }

    func testOnlyTheConversationsAboutThisSkillAndThisAssistantAreOffered() {
        let all = [
            conversation("a", day: 3),
            conversation("b", item: "skill:other", day: 4),
            conversation("c", cli: "codex", day: 5),
            conversation("d", day: 1),
        ]

        let matching = AskConversationStore.matching(
            itemID: "skill:demo", cliID: "claude", origin: skillFolder, in: all
        )

        XCTAssertEqual(matching.map(\.id), ["a", "d"], "newest first, and nobody else's")
    }

    /// A skill that has moved, or been deleted and made again, must not inherit an exchange that was
    /// about a different folder.
    func testAConversationAboutAnotherFolderIsNotOffered() {
        let all = [conversation("a", origin: URL(fileURLWithPath: "/somewhere/else"), day: 2)]

        XCTAssertTrue(
            AskConversationStore.matching(
                itemID: "skill:demo", cliID: "claude", origin: skillFolder, in: all
            ).isEmpty
        )
    }

    func testCarryingOnAConversationDoesNotDuplicateIt() {
        var all = [conversation("a", day: 1, title: "the first thing I asked")]

        all = AskConversationStore.upsert(conversation("a", day: 1, title: "the first thing I asked"), into: all)

        XCTAssertEqual(all.count, 1)
    }

    func testTheListStaysBounded() {
        var all: [AskConversation] = []
        for day in 0..<(AskConversationStore.limit + 10) {
            all = AskConversationStore.upsert(conversation("c\(day)", day: day), into: all)
        }

        XCTAssertEqual(all.count, AskConversationStore.limit)
        XCTAssertEqual(all.first?.id, "c\(AskConversationStore.limit + 9)", "the newest survives")
    }

    // MARK: - Reading an exchange back

    /// The shape the `claude` CLI really writes: one JSON object per line, content as blocks.
    func testMessagesAreReadBackFromTheCLIsOwnRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadout-transcripts-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-x-work")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"s1"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"melhora a description"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Feito."}]}}"#,
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":[{"type":"text","text":"a subagent talking"}]}}"#,
        ]
        try lines.joined(separator: "\n")
            .write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let messages = ChatTranscript.messages(sessionID: "s1", transcripts: root)

        XCTAssertEqual(messages.count, 2, "prose only — no thinking, no subagent chatter")
        XCTAssertEqual(messages[0], ChatTranscript.Message(speaker: .you, text: "melhora a description"))
        XCTAssertEqual(messages[1], ChatTranscript.Message(speaker: .assistant, text: "Feito."))
    }

    /// A conversation the CLI has since pruned reopens empty rather than failing.
    func testAMissingTranscriptIsNotAnError() {
        let messages = ChatTranscript.messages(
            sessionID: "nope", transcripts: URL(fileURLWithPath: "/nowhere/at/all")
        )

        XCTAssertTrue(messages.isEmpty)
    }
}
