import XCTest
@testable import LoadoutCore

/// The document as it is shown while the assistant's changes are undecided. What matters is that
/// the file is still recognisable around the change, that both sides of an undecided change are
/// there, and that a decision taken makes the shown document collapse to one side.
final class ReviewLayoutTests: XCTestCase {
    private let file = """
        ---
        name: test-skill
        description: does stuff
        ---

        # Test skill

        Some body text here.
        """

    private func blocks(_ modified: String) -> [DiffBlock] {
        DiffBlocks.blocks(from: file, to: modified)
    }

    func testAnUndecidedChangeShowsBothSides() {
        let modified = file.replacingOccurrences(of: "does stuff", with: "does something specific")
        let found = blocks(modified)

        let layout = ReviewLayout.make(original: file, blocks: found, decisions: [:])

        XCTAssertTrue(layout.text.contains("description: does stuff"))
        XCTAssertTrue(layout.text.contains("description: does something specific"))
        XCTAssertEqual(layout.pendingRanges.count, 1)
        // And the rest of the file is still there, unchanged, around it.
        XCTAssertTrue(layout.text.contains("# Test skill"))
        XCTAssertTrue(layout.text.contains("Some body text here."))
    }

    func testTheKindsLineUpWithTheLines() {
        let modified = file.replacingOccurrences(of: "does stuff", with: "changed")
        let layout = ReviewLayout.make(original: file, blocks: blocks(modified), decisions: [:])

        let lines = DiffBlocks.lines(of: layout.text)

        XCTAssertEqual(lines.count, layout.kinds.count)
        let removedIndex = lines.firstIndex { $0.contains("does stuff") }!
        let addedIndex = lines.firstIndex { $0.contains("changed") }!
        XCTAssertEqual(layout.kinds[removedIndex], .removed(block: 0))
        XCTAssertEqual(layout.kinds[addedIndex], .added(block: 0))
        // The old line is shown above the new one, which is the whole point of the arrangement.
        XCTAssertLessThan(removedIndex, addedIndex)
    }

    func testAcceptingLeavesOnlyTheNewLine() {
        let modified = file.replacingOccurrences(of: "does stuff", with: "changed")
        let found = blocks(modified)

        let layout = ReviewLayout.make(
            original: file, blocks: found, decisions: [found[0].signature: true]
        )

        XCTAssertFalse(layout.text.contains("does stuff"))
        XCTAssertTrue(layout.text.contains("changed"))
        XCTAssertFalse(layout.hasPending)
    }

    func testRejectingLeavesTheFileAsItWas() {
        let modified = file.replacingOccurrences(of: "does stuff", with: "changed")
        let found = blocks(modified)

        let layout = ReviewLayout.make(
            original: file, blocks: found, decisions: [found[0].signature: false]
        )

        XCTAssertEqual(layout.text, file)
        XCTAssertFalse(layout.hasPending)
        XCTAssertTrue(layout.kinds.allSatisfy { $0 == .context })
    }

    /// One decided and one not: the decided one collapses, the other still shows both sides.
    func testAMixOfDecisions() {
        var modified = file.replacingOccurrences(of: "does stuff", with: "changed")
        modified = modified.replacingOccurrences(of: "Some body text here.", with: "New body.")
        let found = blocks(modified)
        XCTAssertEqual(found.count, 2)

        let layout = ReviewLayout.make(
            original: file, blocks: found, decisions: [found[0].signature: true]
        )

        XCTAssertFalse(layout.text.contains("does stuff"))
        XCTAssertTrue(layout.text.contains("changed"))
        XCTAssertTrue(layout.text.contains("Some body text here."))
        XCTAssertTrue(layout.text.contains("New body."))
        XCTAssertEqual(layout.pendingRanges.count, 1)
        XCTAssertEqual(Array(layout.pendingRanges.keys), [found[1].id])
    }

    /// A decision is remembered against what the change *is*. When the assistant edits the same
    /// line again the signature changes, so it comes back undecided rather than sitting there
    /// marked accepted over text nobody has read.
    func testASecondEditToAnAcceptedLineComesBackUndecided() {
        let first = file.replacingOccurrences(of: "does stuff", with: "changed once")
        let firstBlocks = blocks(first)
        let decisions = [firstBlocks[0].signature: true]

        let second = file.replacingOccurrences(of: "does stuff", with: "changed twice")
        let secondBlocks = blocks(second)

        let layout = ReviewLayout.make(original: file, blocks: secondBlocks, decisions: decisions)

        XCTAssertEqual(layout.pendingRanges.count, 1)
        XCTAssertTrue(layout.text.contains("changed twice"))
        XCTAssertTrue(layout.text.contains("does stuff"))
    }

    func testNoChangesIsJustTheFile() {
        let layout = ReviewLayout.make(original: file, blocks: [], decisions: [:])

        XCTAssertEqual(layout.text, file)
        XCTAssertFalse(layout.hasPending)
    }

    /// The ranges are what the Accept and Reject buttons are positioned against, so they have to
    /// point at exactly the lines of their own change and nothing else.
    func testEachRangeCoversItsOwnChangeOnly() {
        var modified = file.replacingOccurrences(of: "does stuff", with: "changed")
        modified = modified.replacingOccurrences(of: "Some body text here.", with: "New body.")
        let found = blocks(modified)

        let layout = ReviewLayout.make(original: file, blocks: found, decisions: [:])
        let lines = DiffBlocks.lines(of: layout.text)

        for (block, range) in layout.pendingRanges {
            for index in range {
                XCTAssertEqual(layout.kinds[index].block, block)
            }
            XCTAssertEqual(range.count, 2, "one line out, one line in")
            XCTAssertLessThanOrEqual(range.upperBound, lines.count)
        }
    }
}
