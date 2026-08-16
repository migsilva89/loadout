import XCTest
@testable import LoadoutCore

/// What a skill costs, measured against the limits Anthropic's own `skill-creator` documents:
/// metadata always in context, body under 500 lines and under 5k words on trigger, name at
/// most 64 characters and description at most 1024 (the two the validator hard-rejects).
final class BudgetTests: XCTestCase {

    private func document(name: String = "exemplo", description: String, body: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)"
    }

    // MARK: Measuring

    func testMeasuresDescriptionAndBodySeparately() {
        let budget = Budget.measure(
            document: document(description: "Sixteen chars.!!", body: "one line\nanother line")
        )

        XCTAssertEqual(budget.descriptionCharacters, 16)
        XCTAssertEqual(budget.bodyLines, 2)
        XCTAssertEqual(budget.bodyWords, 4)
        XCTAssertEqual(budget.nameCharacters, 7)
    }

    /// The two numbers are never added together: one is paid in every session, the other only
    /// when the skill fires, and a single total would hide which of the two is the problem.
    func testTheTwoTokenEstimatesAreReportedApart() {
        let budget = Budget.measure(
            document: document(description: String(repeating: "a", count: 400),
                               body: String(repeating: "b", count: 4_000))
        )

        XCTAssertEqual(budget.descriptionTokens, 100, "roughly four characters per token")
        XCTAssertEqual(budget.bodyTokens, 1_000)
    }

    func testAnEmptyDocumentCostsNothingRatherThanCrashing() {
        let budget = Budget.measure(document: "")
        XCTAssertEqual(budget.descriptionTokens, 0)
        XCTAssertEqual(budget.bodyLines, 0)
        XCTAssertFalse(budget.isOverBudget)
    }

    // MARK: The documented limits

    func testABodyOverFiveHundredLinesIsFlaggedWithTheAdviceThatFixesIt() {
        let body = Array(repeating: "linha", count: 501).joined(separator: "\n")
        let budget = Budget.measure(document: document(description: "curta", body: body))

        XCTAssertTrue(budget.isOverBudget)
        XCTAssertEqual(budget.breaches.count, 1)
        XCTAssertTrue(budget.breaches[0].contains("501 lines"))
        XCTAssertTrue(
            budget.breaches[0].contains("reference files"),
            "the message has to say what to do, not just that a number is too big"
        )
    }

    func testExactlyAtTheLimitIsNotABreach() {
        let body = Array(repeating: "linha", count: Budget.maxBodyLines).joined(separator: "\n")
        let budget = Budget.measure(document: document(description: "curta", body: body))

        XCTAssertFalse(budget.isOverBudget, "500 lines is the limit, not one past it")
    }

    func testADescriptionOverTenTwentyFourIsFlagged() {
        let budget = Budget.measure(
            document: document(description: String(repeating: "d", count: 1_025), body: "corpo")
        )

        XCTAssertTrue(budget.breaches.contains { $0.contains("1025 characters") })
    }

    func testANameOverSixtyFourIsFlagged() {
        let budget = Budget.measure(
            document: document(name: String(repeating: "n", count: 65), description: "x", body: "y")
        )

        XCTAssertTrue(budget.breaches.contains { $0.contains("65 characters") })
    }

    func testEveryBrokenLimitIsListed() {
        let body = Array(repeating: "palavra", count: 5_001).joined(separator: "\n")
        let budget = Budget.measure(
            document: document(description: String(repeating: "d", count: 1_100), body: body)
        )

        XCTAssertEqual(budget.breaches.count, 3, "description, lines and words all broken")
    }

    // MARK: Reaching the inventory and the filter

    func testTheScannerMeasuresEverySkillItFinds() {
        let fixture = Fixture()
        fixture.rawSkill("gorda", contents: document(
            name: "gorda",
            description: "Uma description normal.",
            body: Array(repeating: "linha", count: 600).joined(separator: "\n")
        ))
        fixture.skill("magra", description: "Curta.")

        let items = InventoryScanner(paths: fixture.paths).scanAll().items

        XCTAssertTrue(items.first { $0.name == "gorda" }!.budget.isOverBudget)
        XCTAssertFalse(items.first { $0.name == "magra" }!.budget.isOverBudget)
    }

    func testTheOverBudgetChipShowsOnlyTheOnesThatBreakALimit() {
        let fixture = Fixture()
        fixture.rawSkill("gorda", contents: document(
            name: "gorda", description: "x",
            body: Array(repeating: "linha", count: 600).joined(separator: "\n")
        ))
        fixture.skill("magra")
        let items = InventoryScanner(paths: fixture.paths).scanAll().items

        let over = Filtering.filter(items, by: .overBudget)

        XCTAssertEqual(over.map(\.name), ["gorda"])
    }

    /// The chip has to combine with the sidebar's kind the way every other chip does.
    func testOverBudgetComposesWithTheKindSlice() {
        let fixture = Fixture()
        fixture.rawSkill("gorda", contents: document(
            name: "gorda", description: "x",
            body: Array(repeating: "linha", count: 600).joined(separator: "\n")
        ))
        fixture.command("um-comando")
        let items = InventoryScanner(paths: fixture.paths).scanAll().items

        let result = Filtering.apply(
            items, selection: .skills, filter: .overBudget, assistant: .any, query: "", order: .name
        )

        XCTAssertEqual(result.map(\.name), ["gorda"])
    }
}
