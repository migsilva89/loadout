import XCTest
@testable import LoadoutCore

/// Choosing which model answers. The flag has to land where each CLI actually takes it — verified
/// against `claude --help`, `codex exec --help` and `codex exec resume --help` on a real machine —
/// and has to disappear completely when no model is chosen, rather than leaving an empty argument.
final class ChatModelTests: XCTestCase {
    func testNoModelChosenLeavesTheCommandExactlyAsItWas() {
        let before = AssistantChat.claude.arguments(prompt: "hi", resuming: nil)
        let after = AssistantChat.claude.arguments(prompt: "hi", resuming: nil, model: nil)
        XCTAssertEqual(before, after)
        XCTAssertFalse(before.contains("--model"))
        XCTAssertFalse(before.contains(""), "no empty argument is left behind")
    }

    func testClaudeTakesTheFlagBeforeItsOwnArguments() {
        let argv = AssistantChat.claude.arguments(prompt: "hi", resuming: nil, model: "opus")
        XCTAssertEqual(argv.first, "--model")
        XCTAssertEqual(argv.dropFirst().first, "opus")
        XCTAssertTrue(argv.contains("-p"))
    }

    /// `-m` after `exec`, not before it: `codex` takes it on the subcommand.
    func testCodexTakesTheFlagAfterExec() {
        let argv = AssistantChat.codex.arguments(prompt: "hi", resuming: nil, model: "gpt-5.6-sol")
        XCTAssertEqual(argv.first, "exec")
        XCTAssertEqual(Array(argv.prefix(3)), ["exec", "-m", "gpt-5.6-sol"])
    }

    /// And after the session id on a resume, which is a different position again.
    func testCodexResumeKeepsTheSessionIdBeforeTheFlag() {
        let argv = AssistantChat.codex.arguments(prompt: "hi", resuming: "abc123", model: "gpt-5.6-sol")
        XCTAssertEqual(Array(argv.prefix(5)), ["exec", "resume", "abc123", "-m", "gpt-5.6-sol"])
    }

    /// A resumed turn carries the model too. Dropping it would let the CLI fall back to its own
    /// default halfway through a conversation, which reads as the assistant changing its mind.
    func testAResumedTurnStillNamesTheModel() {
        let argv = AssistantChat.claude.arguments(prompt: "hi", resuming: "abc123", model: "sonnet")
        XCTAssertTrue(argv.contains("--model"))
        XCTAssertTrue(argv.contains("sonnet"))
        XCTAssertTrue(argv.contains("--resume"))
    }

    /// A name of nothing but spaces is not a choice.
    func testABlankNameIsTreatedAsNoChoice() {
        let argv = AssistantChat.codex.arguments(prompt: "hi", resuming: nil, model: "   ")
        XCTAssertFalse(argv.contains("-m"))
        XCTAssertEqual(argv, AssistantChat.codex.arguments(prompt: "hi", resuming: nil))
    }

    func testTheNameIsTrimmedRatherThanPassedWithItsSpaces() {
        let argv = AssistantChat.claude.arguments(prompt: "hi", resuming: nil, model: "  opus \n")
        XCTAssertEqual(argv.dropFirst().first, "opus")
    }

    /// The whole prompt stays one argument even with a model in front of it — the same rule the
    /// rest of this file lives by, checked again because a new token was added to the template.
    func testThePromptIsStillOneArgument() {
        let nasty = "fix this; rm -rf / \"quoted\""
        let argv = AssistantChat.claude.arguments(prompt: nasty, resuming: nil, model: "opus")
        XCTAssertEqual(argv.filter { $0 == nasty }.count, 1)
    }

    // MARK: - The written list

    func testEveryKnownModelBelongsToAnAssistantThatCanBeToldOne() {
        for id in ["claude", "codex", "opencode"] {
            XCTAssertTrue(AssistantModels.acceptsAModel(assistantID: id), "\(id) takes a model flag")
            XCTAssertFalse(AssistantModels.known(for: id).isEmpty, "\(id) offers models")
        }
    }

    /// cursor-agent holds no conversation at all, so it has no model flag and offers no list —
    /// the picker uses this to stay hidden rather than offer a choice that would be ignored.
    func testAnAssistantWithNoModelFlagOffersNothing() {
        XCTAssertFalse(AssistantModels.acceptsAModel(assistantID: "cursor-agent"))
        XCTAssertTrue(AssistantModels.known(for: "cursor-agent").isEmpty)
    }

    /// One remembered choice per assistant: picking Opus for claude must not become what codex is
    /// asked for, since the two do not share a vocabulary.
    func testEachAssistantRemembersItsOwnChoice() {
        XCTAssertNotEqual(
            AssistantModels.defaultsKey(assistantID: "claude"),
            AssistantModels.defaultsKey(assistantID: "codex")
        )
    }
}
