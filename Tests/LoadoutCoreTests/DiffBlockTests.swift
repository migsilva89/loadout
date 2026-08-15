import XCTest
@testable import LoadoutCore

/// Blocks are how the assistant's work reaches Miguel's file: it edits a disposable copy, Loadout
/// compares the two and offers each change on its own. So what matters here is not only that the
/// differences are found, but that accepting some and refusing others lands the right text —
/// including when the accepted one sits after the refused one.
final class DiffBlockTests: XCTestCase {
    private let skill = """
        ---
        name: test-skill
        description: does stuff
        ---

        # Test skill

        Some body text here.
        """

    func testFindsTheOneChangedLine() {
        let after = skill.replacingOccurrences(
            of: "description: does stuff",
            with: "description: Use when verifying that skills load."
        )

        let blocks = DiffBlocks.blocks(from: skill, to: after)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].start, 2)
        XCTAssertEqual(blocks[0].removedText, ["description: does stuff"])
        XCTAssertEqual(blocks[0].addedText, ["description: Use when verifying that skills load."])
        XCTAssertEqual(blocks[0].summary, "1 line changed")
    }

    func testIdenticalFilesHaveNoBlocks() {
        XCTAssertTrue(DiffBlocks.blocks(from: skill, to: skill).isEmpty)
    }

    func testSeparateChangesBecomeSeparateBlocks() {
        var after = skill.replacingOccurrences(of: "does stuff", with: "does something specific")
        after = after.replacingOccurrences(of: "Some body text here.", with: "Rewritten body.")

        let blocks = DiffBlocks.blocks(from: skill, to: after)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertLessThan(blocks[0].start, blocks[1].start)
    }

    /// The point of blocks: refusing the first and taking the second must leave the first line
    /// exactly as it was, not shift the second one by the difference.
    func testAcceptingOnlyTheSecondBlockLeavesTheFirstAlone() {
        var after = skill.replacingOccurrences(of: "does stuff", with: "does something specific")
        after = after.replacingOccurrences(of: "Some body text here.", with: "Rewritten body.")
        let blocks = DiffBlocks.blocks(from: skill, to: after)

        let result = DiffBlocks.apply(blocks, accepting: [blocks[1].id], to: skill)

        XCTAssertTrue(result.contains("description: does stuff"))
        XCTAssertTrue(result.contains("Rewritten body."))
        XCTAssertFalse(result.contains("Some body text here."))
    }

    func testAcceptingEverythingReproducesTheAssistantsFile() {
        var after = skill.replacingOccurrences(of: "does stuff", with: "does something specific")
        after = after.replacingOccurrences(of: "Some body text here.", with: "Rewritten body.\nAnd more.")
        let blocks = DiffBlocks.blocks(from: skill, to: after)

        XCTAssertEqual(DiffBlocks.apply(blocks, accepting: Set(blocks.map(\.id)), to: skill), after)
    }

    func testAcceptingNothingLeavesTheFileUntouched() {
        let after = skill.replacingOccurrences(of: "does stuff", with: "changed")
        let blocks = DiffBlocks.blocks(from: skill, to: after)

        XCTAssertEqual(DiffBlocks.apply(blocks, accepting: [], to: skill), skill)
    }

    /// Text appended to a file whose last line had no newline. It is one block rather than a pure
    /// insertion, because that last line does change: it gains the newline the new text needs.
    func testTextAppendedAtTheEndIsOneBlock() {
        let after = skill + "\n\nA new closing paragraph.\n"

        let blocks = DiffBlocks.blocks(from: skill, to: after)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(DiffBlocks.apply(blocks, accepting: [0], to: skill), after)
        XCTAssertEqual(DiffBlocks.apply(blocks, accepting: [], to: skill), skill)
    }

    /// The same append to a file that already ended in a newline: nothing existing changes, so it
    /// is a plain insertion.
    func testAppendingToAFileThatEndsInANewlineIsAnInsertion() {
        let before = skill + "\n"
        let blocks = DiffBlocks.blocks(from: before, to: before + "A new closing paragraph.\n")

        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].isInsertion)
        XCTAssertEqual(blocks[0].addedText, ["A new closing paragraph."])
    }

    func testDeletionIsItsOwnBlock() {
        let after = skill.replacingOccurrences(of: "\nSome body text here.", with: "")

        let blocks = DiffBlocks.blocks(from: skill, to: after)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].isDeletion)
        XCTAssertEqual(DiffBlocks.apply(blocks, accepting: [0], to: skill), after)
    }

    /// A file created from nothing — the assistant adding a helper script beside the skill.
    func testWholeFileFromEmpty() {
        let blocks = DiffBlocks.blocks(from: "", to: "#!/bin/sh\necho hello\n")

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].addedText, ["#!/bin/sh", "echo hello"])
        XCTAssertEqual(DiffBlocks.apply(blocks, accepting: [0], to: ""), "#!/bin/sh\necho hello\n")
    }

    /// A file that does not end in a newline must not gain one just by being compared.
    func testTrailingNewlineIsPreserved() {
        let withoutNewline = "one\ntwo"
        let blocks = DiffBlocks.blocks(from: withoutNewline, to: "one\nTWO")

        XCTAssertEqual(DiffBlocks.apply(blocks, accepting: [0], to: withoutNewline), "one\nTWO")
    }

    func testRepeatedLinesDoNotConfuseTheAlignment() {
        let before = "a\nb\na\nb\na\n"
        let after = "a\nb\na\nCHANGED\na\n"

        let blocks = DiffBlocks.blocks(from: before, to: after)

        XCTAssertEqual(DiffBlocks.apply(blocks, accepting: Set(blocks.map(\.id)), to: before), after)
    }
}
