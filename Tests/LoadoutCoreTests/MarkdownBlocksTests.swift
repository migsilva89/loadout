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

    // MARK: - Boundaries between rules

    func testARuleAndABulletAreToldApartByWhatFollowsTheMarker() {
        XCTAssertEqual(
            MarkdownBlocks.parse("A\n---\n- one\n***\n* two"),
            [.paragraph("A"), .rule, .bullet("one"), .rule, .bullet("two")]
        )
    }

    func testAHeadingEndsTheParagraphAboveItWithoutABlankLine() {
        XCTAssertEqual(
            MarkdownBlocks.parse("Some text\n# Heading"),
            [.paragraph("Some text"), .heading(level: 1, text: "Heading")]
        )
    }

    func testALineOfOnlySpacesEndsAParagraph() {
        XCTAssertEqual(
            MarkdownBlocks.parse("First\n   \nSecond"),
            [.paragraph("First"), .paragraph("Second")]
        )
    }

    func testAnIndentedHeadingIsStillAHeading() {
        XCTAssertEqual(MarkdownBlocks.parse("  ## Indented"), [.heading(level: 2, text: "Indented")])
    }

    func testADecimalOrALongNumberIsNotANumberedItem() {
        XCTAssertEqual(
            MarkdownBlocks.parse("1.5 litres\n\n1234. x"),
            [.paragraph("1.5 litres"), .paragraph("1234. x")]
        )
    }

    func testABareQuoteMarkerIsAnEmptyQuote() {
        XCTAssertEqual(MarkdownBlocks.parse(">"), [.quote("")])
    }

    func testAnUnclosedFenceRunsToTheEndAsCode() {
        XCTAssertEqual(
            MarkdownBlocks.parse("Before\n```\ncode line\n# not a heading"),
            [.paragraph("Before"), .code("code line\n# not a heading")]
        )
    }

    func testAnOpeningDashLineWithoutAClosingOneIsNotFrontmatter() {
        XCTAssertEqual(
            MarkdownBlocks.parse("---\nname: x\n\nBody"),
            [.rule, .paragraph("name: x"), .paragraph("Body")]
        )
    }

    func testAnEmptyDocumentHasNoBlocks() {
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
    }

    // MARK: - Tables

    func testATableIsOneTableBlockNotAParagraphOfPipes() {
        let blocks = MarkdownBlocks.parse("""
            | Mode | Form |
            |---|---|
            | Tutorial | a lesson |
            | How-to | `steps` |
            """)

        XCTAssertEqual(blocks, [.table(MarkdownTable(
            header: ["Mode", "Form"],
            alignments: [.leading, .leading],
            rows: [["Tutorial", "a lesson"], ["How-to", "`steps`"]]
        ))])
    }

    func testColonsInTheDelimiterRowSetEachColumnsAlignment() {
        let blocks = MarkdownBlocks.parse("| a | b | c | d |\n| --- | :-- | :-: | --: |\n| 1 | 2 | 3 | 4 |")

        guard case .table(let table) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(table.alignments, [.leading, .leading, .center, .trailing])
    }

    func testOuterPipesAreOptionalAndAnEscapedPipeStaysInItsCell() {
        let blocks = MarkdownBlocks.parse("Flag | Means\n--- | ---\n`a \\| b` | either")

        XCTAssertEqual(blocks, [.table(MarkdownTable(
            header: ["Flag", "Means"],
            alignments: [.leading, .leading],
            rows: [["`a | b`", "either"]]
        ))])
    }

    func testADelimiterRowOfTheWrongWidthIsNotATable() {
        XCTAssertEqual(
            MarkdownBlocks.parse("| a | b |\n|---|"),
            [.paragraph("| a | b | |---|")]
        )
    }

    func testASentenceWithAPipeAboveARuleIsNotATable() {
        XCTAssertEqual(
            MarkdownBlocks.parse("Pick one | or the other\n---"),
            [.paragraph("Pick one | or the other"), .rule]
        )
    }

    func testABlankLineEndsTheTable() {
        let blocks = MarkdownBlocks.parse("Intro.\n| a |\n|---|\n| 1 |\n\nAfter.")

        XCTAssertEqual(blocks, [
            .paragraph("Intro."),
            .table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]])),
            .paragraph("After."),
        ])
    }

    func testRowsArePaddedOrCutToTheHeadersWidth() {
        let blocks = MarkdownBlocks.parse("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")

        guard case .table(let table) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(table.rows, [["1", ""], ["1", "2"]])
    }

    func testATableInsideAFenceStaysCode() {
        XCTAssertEqual(
            MarkdownBlocks.parse("```\n| a |\n|---|\n```"),
            [.code("| a |\n|---|")]
        )
    }

    func testALineWithoutAPipeEndsTheTable() {
        XCTAssertEqual(MarkdownBlocks.parse("| a |\n|---|\n| 1 |\n# Next"), [
            .table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]])),
            .heading(level: 1, text: "Next"),
        ])
    }

    func testAHeaderAndDelimiterWithNoRowsIsAnEmptyTable() {
        XCTAssertEqual(
            MarkdownBlocks.parse("| a | b |\n|---|---|"),
            [.table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading], rows: []))]
        )
    }

    func testADelimiterRowWithoutDashesIsNotATable() {
        XCTAssertEqual(MarkdownBlocks.parse("| a |\n| x |"), [.paragraph("| a | | x |")])
    }

    func testALineAnotherRuleClaimsDoesNotStartATable() {
        let blocks = MarkdownBlocks.parse("""
            # Plan | Cost
            --- | ---

            - a | b
            --- | ---

            > c | d
            --- | ---

            1. e | f
            --- | ---
            """)

        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Plan | Cost"), .paragraph("--- | ---"),
            .bullet("a | b"), .paragraph("--- | ---"),
            .quote("c | d"), .paragraph("--- | ---"),
            .numbered(marker: "1.", text: "e | f"), .paragraph("--- | ---"),
        ])
    }

    func testABulletWithAPipeUnderATableEndsTheTable() {
        XCTAssertEqual(MarkdownBlocks.parse("| a |\n|---|\n| 1 |\n- x | y\n> q | r\n2. n | m"), [
            .table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]])),
            .bullet("x | y"),
            .quote("q | r"),
            .numbered(marker: "2.", text: "n | m"),
        ])
    }

    func testInlineFormattingInACellIsLeftForTheInlineReader() {
        let blocks = MarkdownBlocks.parse("| a |\n|---|\n| **b** and `c` |")

        guard case .table(let table) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(table.rows, [["**b** and `c`"]])
    }

    func testAPipeInsideBackticksStillSplitsTheCellAsOnGitHub() {
        let blocks = MarkdownBlocks.parse("| a | b |\n|---|---|\n| `c|d` |")

        guard case .table(let table) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(table.rows, [["`c", "d`"]])
    }

    func testATrailingEscapedPipeIsContentNotTheOuterPipe() {
        let blocks = MarkdownBlocks.parse("| a |\n|---|\n| x \\| |")

        guard case .table(let table) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(table.rows, [["x |"]])
    }

    func testAnIndentedTableIsStillATable() {
        XCTAssertEqual(
            MarkdownBlocks.parse("   | a |\n   |---|\n   | 1 |"),
            [.table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]]))]
        )
    }

    func testTwoTablesSeparatedByABlankLineAreTwoBlocks() {
        XCTAssertEqual(MarkdownBlocks.parse("| a |\n|---|\n| 1 |\n\n| b |\n|---|\n| 2 |"), [
            .table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]])),
            .table(MarkdownTable(header: ["b"], alignments: [.leading], rows: [["2"]])),
        ])
    }

    func testALoneColonOrStrayTextInTheDelimiterRowIsNotATable() {
        XCTAssertEqual(MarkdownBlocks.parse("| a |\n|:|\n| 1 |"), [.paragraph("| a | |:| | 1 |")])
        XCTAssertEqual(MarkdownBlocks.parse("| a |\n|--- x|\n| 1 |"), [.paragraph("| a | |--- x| | 1 |")])
    }
}
