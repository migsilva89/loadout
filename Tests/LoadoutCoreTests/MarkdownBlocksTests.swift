import XCTest
@testable import LoadoutCore

/// The reading pane draws whatever these blocks say, so a line read as the wrong kind of block is
/// a document that looks wrong while every file on disk is fine.
final class MarkdownBlocksTests: XCTestCase {
    func testFrontmatterComesFirstAndIsNotReadAsARule() {
        let blocks = MarkdownBlocks.parse("""
            ---
            name: demo
            description: Does a thing.
            ---

            Body.
            """)

        XCTAssertEqual(blocks.count, 2)
        guard case .frontmatter(let fields) = blocks[0] else { return XCTFail("\(blocks[0])") }
        XCTAssertEqual(fields.map(\.0), ["name", "description"])
        XCTAssertEqual(blocks[1], .paragraph("Body."))
    }

    func testHeadingLevelsAreCountedFromTheHashes() {
        XCTAssertEqual(MarkdownBlocks.parse("# One\n## Two\n### Three"), [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 3, text: "Three"),
        ])
    }

    func testConsecutiveLinesJoinIntoOneParagraph() {
        XCTAssertEqual(
            MarkdownBlocks.parse("First line\nsecond line.\n\nNext paragraph."),
            [.paragraph("First line second line."), .paragraph("Next paragraph.")]
        )
    }

    func testEveryBulletMarkerIsABullet() {
        XCTAssertEqual(
            MarkdownBlocks.parse("- dash\n* star\n+ plus"),
            [.bullet("dash"), .bullet("star"), .bullet("plus")]
        )
    }

    func testNumberedItemsKeepTheirMarker() {
        XCTAssertEqual(MarkdownBlocks.parse("1. first\n12) twelfth"), [
            .numbered(marker: "1.", text: "first"),
            .numbered(marker: "12)", text: "twelfth"),
        ])
    }

    func testAYearStartingASentenceIsNotANumberedItem() {
        XCTAssertEqual(MarkdownBlocks.parse("2026.10 was the date"), [.paragraph("2026.10 was the date")])
    }

    func testQuoteLosesItsMarker() {
        XCTAssertEqual(MarkdownBlocks.parse("> quoted words"), [.quote("quoted words")])
    }

    func testFencedCodeIsKeptVerbatim() {
        let blocks = MarkdownBlocks.parse("""
            ```bash
              indented  # comment
            - not a bullet
            ```
            After.
            """)

        XCTAssertEqual(blocks, [.code("  indented  # comment\n- not a bullet"), .paragraph("After.")])
    }

    func testHorizontalRulesBetweenParagraphs() {
        XCTAssertEqual(
            MarkdownBlocks.parse("Above.\n\n---\n\nBelow.\n\n***"),
            [.paragraph("Above."), .rule, .paragraph("Below."), .rule]
        )
    }
}
