import XCTest
@testable import LoadoutCore

/// Each of these lines was copied out of a real run: the CLIs were pointed at a throwaway
/// `SKILL.md` and asked to improve its `description`. They are here verbatim so that if an
/// assistant changes its output shape one day, this fails instead of the panel going quiet.
final class ChatEventTests: XCTestCase {
    // MARK: - claude

    func testClaudeEditCarriesBothVersionsOfTheLine() {
        let line = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1",\
            "name":"Edit","input":{"file_path":"/tmp/w/SKILL.md","old_string":"description: does stuff",\
            "new_string":"description: Use when testing skill discovery.","replace_all":false}}]}}
            """

        let events = ChatEventParser.events(from: line, dialect: .claudeStreamJSON)

        XCTAssertEqual(events, [.edited(
            path: "/tmp/w/SKILL.md",
            before: "description: does stuff",
            after: "description: Use when testing skill discovery."
        )])
    }

    func testClaudeReportsItsShellCommandsAsActivity() {
        let line = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t0",\
            "name":"Bash","input":{"command":"find /tmp/w -name SKILL.md"}}]}}
            """

        XCTAssertEqual(
            ChatEventParser.events(from: line, dialect: .claudeStreamJSON),
            [.activity(tool: "Bash", detail: "find /tmp/w -name SKILL.md")]
        )
    }

    func testClaudeAnnouncesItsSessionSoTheNextTurnCanResumeIt() {
        let line = #"{"type":"system","subtype":"init","session_id":"22386cbc-5ccf-427f-a0b5-07309d858307"}"#

        XCTAssertEqual(
            ChatEventParser.events(from: line, dialect: .claudeStreamJSON),
            [.session("22386cbc-5ccf-427f-a0b5-07309d858307")]
        )
    }

    func testClaudeTextAndThinkingAreKeptApart() {
        let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#
        let thinking = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Let me look."}]}}"#

        XCTAssertEqual(ChatEventParser.events(from: text, dialect: .claudeStreamJSON), [.text("Done.")])
        XCTAssertEqual(
            ChatEventParser.events(from: thinking, dialect: .claudeStreamJSON),
            [.reasoning("Let me look.")]
        )
    }

    func testClaudeResultEndsTheRun() {
        XCTAssertEqual(
            ChatEventParser.events(from: #"{"type":"result","subtype":"success","is_error":false}"#,
                                   dialect: .claudeStreamJSON),
            [.finished(error: nil)]
        )
    }

    // MARK: - codex

    /// codex says which file it touched but never what it changed in it. That is the whole reason
    /// the accepted blocks are computed by comparing folders rather than read from the stream.
    func testCodexNamesTheFileWithoutSayingWhatChanged() {
        let line = """
            {"msg":{"type":"item.completed","item":{"id":"item_3","type":"file_change",\
            "changes":[{"path":"/tmp/w/SKILL.md","kind":"update"}],"status":"completed"}}}
            """

        XCTAssertEqual(
            ChatEventParser.events(from: line, dialect: .codexJSONL),
            [.edited(path: "/tmp/w/SKILL.md", before: nil, after: nil)]
        )
    }

    func testCodexShellCommandBecomesActivity() {
        let line = """
            {"msg":{"type":"item.completed","item":{"id":"item_1","type":"command_execution",\
            "command":"/bin/zsh -lc \\"sed -n '1,8p' SKILL.md\\"","exit_code":0,"status":"completed"}}}
            """

        XCTAssertEqual(
            ChatEventParser.events(from: line, dialect: .codexJSONL),
            [.activity(tool: "Shell", detail: "/bin/zsh -lc \"sed -n '1,8p' SKILL.md\"")]
        )
    }

    func testCodexMessageIsProse() {
        let line = """
            {"msg":{"type":"item.completed","item":{"id":"item_0","type":"agent_message",\
            "text":"I'll inspect the skill first."}}}
            """

        XCTAssertEqual(
            ChatEventParser.events(from: line, dialect: .codexJSONL),
            [.text("I'll inspect the skill first.")]
        )
    }

    func testCodexTurnCompletedEndsTheRun() {
        XCTAssertEqual(
            ChatEventParser.events(from: #"{"msg":{"type":"turn.completed"}}"#, dialect: .codexJSONL),
            [.finished(error: nil)]
        )
    }

    // MARK: - opencode

    func testOpenCodeEditCarriesBothVersionsAndItsSession() {
        let line = """
            {"type":"tool_use","timestamp":1786718595436,"sessionID":"ses_fff45f584ffeDfQSCrgc0wwKpL",\
            "part":{"type":"tool","tool":"edit","callID":"call_00","state":{"status":"completed",\
            "input":{"filePath":"/tmp/w/SKILL.md","oldString":"description: does stuff",\
            "newString":"description: Demonstrates a minimal SKILL.md."},"output":"Edit applied successfully."}}}
            """

        XCTAssertEqual(ChatEventParser.events(from: line, dialect: .openCodeJSON), [
            .session("ses_fff45f584ffeDfQSCrgc0wwKpL"),
            .edited(
                path: "/tmp/w/SKILL.md",
                before: "description: does stuff",
                after: "description: Demonstrates a minimal SKILL.md."
            ),
        ])
    }

    // MARK: - Anything else

    /// The CLIs print banners, warnings and login prompts on the same pipe. Showing them is how an
    /// assistant that is stuck — asking to sign in, say — explains itself instead of hanging blank.
    func testNonJSONLinesAreShownRatherThanDropped() {
        XCTAssertEqual(
            ChatEventParser.events(from: "Press any key to sign in...", dialect: .claudeStreamJSON),
            [.unparsed("Press any key to sign in...")]
        )
    }

    func testBlankLinesAreIgnored() {
        XCTAssertTrue(ChatEventParser.events(from: "   \n", dialect: .claudeStreamJSON).isEmpty)
    }

    // MARK: - Invocation

    func testResumingSubstitutesTheSessionAsOneArgument() {
        let arguments = AssistantChat.claude.arguments(prompt: "make it shorter; ok", resuming: "abc-123")

        XCTAssertTrue(arguments.contains("--resume"))
        XCTAssertTrue(arguments.contains("abc-123"))
        XCTAssertEqual(arguments.last, "make it shorter; ok")
    }

    func testWithoutASessionTheStartTemplateIsUsed() {
        let arguments = AssistantChat.claude.arguments(prompt: "hello", resuming: nil)

        XCTAssertFalse(arguments.contains("--resume"))
        XCTAssertEqual(arguments.last, "hello")
    }

    /// cursor-agent wants an interactive login, so it is not offered a conversation — a panel that
    /// asks for a password nobody can type into it is worse than not being there.
    func testCursorIsNotOfferedAConversation() {
        XCTAssertNotNil(AssistantChat.builtin(id: "claude"))
        XCTAssertNotNil(AssistantChat.builtin(id: "codex"))
        XCTAssertNotNil(AssistantChat.builtin(id: "opencode"))
        XCTAssertNil(AssistantChat.builtin(id: "cursor-agent"))
        XCTAssertEqual(AssistantCLIRegistry.chatCapableLabels, ["Claude Code", "Codex", "opencode"])
    }

    func testCustomCLIsGetNoConversation() {
        let custom = AssistantCLI(
            id: "gemini", label: "Gemini", executable: URL(fileURLWithPath: "/usr/local/bin/gemini"),
            argumentTemplate: "-p {prompt}", isCustom: true
        )
        let builtin = AssistantCLI(
            id: "claude", label: "Claude Code", executable: URL(fileURLWithPath: "/usr/local/bin/claude"),
            argumentTemplate: "-p {prompt}", isCustom: false
        )

        XCTAssertNil(custom.chat)
        XCTAssertEqual(builtin.chat?.dialect, .claudeStreamJSON)
    }
}
