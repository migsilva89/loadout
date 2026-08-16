import XCTest
@testable import LoadoutCore

/// AC6 — the usage index, AC7.2 — the copilot's missing binary, AC8.3 — coalescing.
final class UsageTests: XCTestCase {

    private func iso(daysAgo: Int) -> String {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: AC6.1

    func testCountsAllFourKindsOfUsage() throws {
        let fixture = Fixture()
        fixture.transcript("sessao", lines: [
            Line.skill("imark-review", at: iso(daysAgo: 1)),
            Line.skill("imark-review", at: iso(daysAgo: 2)),
            Line.command("codex:review", at: iso(daysAgo: 1)),
            Line.agent("Explore", at: iso(daysAgo: 3)),
            Line.mcp("notebooklm", at: iso(daysAgo: 1)),
        ])
        let index = try UsageIndex(paths: fixture.paths)

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill)["imark-review"]?.count, 2)
        XCTAssertEqual(index.usage(kind: .command)["review"]?.count, 1, "o prefixo do plugin cai")
        XCTAssertEqual(index.usage(kind: .agent)["Explore"]?.count, 1)
        XCTAssertEqual(index.usage(kind: .mcp)["notebooklm"]?.count, 1)
    }

    func testPluginQualifiedSkillsCountUnderTheBareName() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [Line.skill("anthropic-skills:pdf", at: iso(daysAgo: 1))])
        let index = try UsageIndex(paths: fixture.paths)

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill)["pdf"]?.count, 1)
    }

    // MARK: AC6.2

    func testUnchangedTranscriptsAreNotReread() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [Line.skill("uma", at: iso(daysAgo: 1))])
        let index = try UsageIndex(paths: fixture.paths)
        let file = index.transcriptFiles()[0]

        XCTAssertEqual(index.indexFile(file, since: .distantPast), 1, "the first pass reads")
        XCTAssertEqual(index.indexFile(file, since: .distantPast), -1, "segunda passagem salta")

        // Touching the file must bring it back into the pass.
        try "\(Line.skill("uma", at: iso(daysAgo: 1)))\n\(Line.skill("outra", at: iso(daysAgo: 1)))"
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(index.indexFile(file, since: .distantPast), 2)
    }

    func testReindexingReplacesEventsRatherThanDuplicatingThem() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [Line.skill("uma", at: iso(daysAgo: 1))])
        let index = try UsageIndex(paths: fixture.paths)
        let file = index.transcriptFiles()[0]

        index.indexFile(file, since: .distantPast)
        try "\(Line.skill("uma", at: iso(daysAgo: 1)))".write(to: file, atomically: true, encoding: .utf8)
        index.indexFile(file, since: .distantPast)

        XCTAssertEqual(index.usage(kind: .skill)["uma"]?.count, 1)
    }

    // MARK: AC6.3

    func testTheDefaultWindowIsNinetyDaysAndFullHistoryIsOptIn() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [
            Line.skill("recente", at: iso(daysAgo: 10)),
            Line.skill("old-one", at: iso(daysAgo: 200)),
        ])
        let index = try UsageIndex(paths: fixture.paths)

        index.refresh()
        XCTAssertEqual(index.usage(kind: .skill)["recente"]?.count, 1)
        XCTAssertNil(index.usage(kind: .skill)["old-one"], "outside the window")

        index.refresh(since: .distantPast)
        XCTAssertEqual(index.usage(kind: .skill)["old-one"]?.count, 1, "full history on demand")
    }

    // MARK: AC6.5

    func testUsageKnowsCountRecencyAndHowManyProjects() throws {
        let fixture = Fixture()
        fixture.transcript("a", lines: [
            Line.skill("spread-out", at: iso(daysAgo: 9), cwd: "/Users/me/repo-um"),
            Line.skill("spread-out", at: iso(daysAgo: 3), cwd: "/Users/me/repo-two"),
            Line.skill("spread-out", at: iso(daysAgo: 1), cwd: "/Users/me/repo-two"),
        ])
        let index = try UsageIndex(paths: fixture.paths)

        index.refresh()
        let usage = try XCTUnwrap(index.usage(kind: .skill)["spread-out"])

        XCTAssertEqual(usage.count, 3)
        XCTAssertEqual(usage.projectCount, 2)
        let age = Date().timeIntervalSince(try XCTUnwrap(usage.lastUsed))
        XCTAssertEqual(age / 86_400, 1, accuracy: 0.1, "the last use is the most recent one")
    }

    func testProjectsNamesThemBusiestFirst() throws {
        let fixture = Fixture()
        fixture.transcript("a", lines: [
            Line.skill("spread-out", at: iso(daysAgo: 9), cwd: "/Users/me/repo-um"),
            Line.skill("spread-out", at: iso(daysAgo: 3), cwd: "/Users/me/repo-two"),
            Line.skill("spread-out", at: iso(daysAgo: 1), cwd: "/Users/me/repo-two"),
            Line.skill("outra", at: iso(daysAgo: 1), cwd: "/Users/me/repo-tres"),
        ])
        let index = try UsageIndex(paths: fixture.paths)
        index.refresh()

        let projects = index.projects(kind: .skill, key: "spread-out")

        XCTAssertEqual(
            projects, [
                ProjectUsage(project: "repo-two", count: 2),
                ProjectUsage(project: "repo-um", count: 1),
            ],
            "projects come most-used first, and only this skill's"
        )
    }

    func testProjectsHonoursItsLimit() throws {
        let fixture = Fixture()
        fixture.transcript("a", lines: (1...5).map { index in
            Line.skill("larga", at: iso(daysAgo: 1), cwd: "/Users/me/repo-\(index)")
        })
        let index = try UsageIndex(paths: fixture.paths)
        index.refresh()

        XCTAssertEqual(index.projects(kind: .skill, key: "larga", limit: 2).count, 2)
        XCTAssertEqual(index.projects(kind: .skill, key: "larga").count, 5)
    }

    func testProjectsAreEmptyForSomethingNeverUsed() throws {
        let fixture = Fixture()
        fixture.transcript("a", lines: [Line.skill("usada", at: iso(daysAgo: 1))])
        let index = try UsageIndex(paths: fixture.paths)
        index.refresh()

        XCTAssertEqual(index.projects(kind: .skill, key: "nunca-usada"), [])
    }

    // MARK: AC6.6

    func testACorruptedLineDoesNotStopTheRest() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [
            Line.skill("before", at: iso(daysAgo: 1)),
            Line.corrupted,
            "",
            "{\"type\":\"assistant\"}",
            Line.skill("after", at: iso(daysAgo: 1)),
        ])
        let index = try UsageIndex(paths: fixture.paths)

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill)["before"]?.count, 1)
        XCTAssertEqual(index.usage(kind: .skill)["after"]?.count, 1)
    }

    func testTranscriptsSpreadOverManyDirectoriesAreAllFound() throws {
        let fixture = Fixture()
        fixture.transcript("a", lines: [Line.skill("x", at: iso(daysAgo: 1))], project: "um")
        fixture.transcript("b", lines: [Line.skill("x", at: iso(daysAgo: 1))], project: "two")
        let index = try UsageIndex(paths: fixture.paths)

        index.refresh()

        XCTAssertEqual(index.indexedFileCount, 2)
        XCTAssertEqual(index.usage(kind: .skill)["x"]?.count, 2)
    }

    // MARK: annotate

    func testAnnotateJoinsUsageOntoTheInventoryAndLeavesUnusedAtZero() throws {
        let fixture = Fixture()
        fixture.skill("usada")
        fixture.skill("nunca")
        fixture.transcript("s", lines: [Line.skill("usada", at: iso(daysAgo: 2))])
        let index = try UsageIndex(paths: fixture.paths)
        index.refresh()

        let items = index.annotate(InventoryScanner(paths: fixture.paths).scanAll().items)

        XCTAssertEqual(items.first { $0.name == "usada" }?.usage.count, 1)
        XCTAssertTrue(items.first { $0.name == "nunca" }!.usage.neverUsed)
    }

    // MARK: date parsing

    func testTheHandRolledISOReaderMatchesFoundation() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for offset in [0.0, 86_400, 1_000_000, 60_000_000] {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + offset)
            let text = formatter.string(from: date)
            let parsed = try XCTUnwrap(UsageIndex.isoDate(text))
            XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.002)
        }
        XCTAssertNil(UsageIndex.isoDate("nem por sombras"))
        XCTAssertNil(UsageIndex.isoDate(""))
    }

    // MARK: AC7.2

    private func cli(
        id: String = "claude", executable: URL, template: String = "-p {prompt}"
    ) -> AssistantCLI {
        AssistantCLI(id: id, label: "Claude Code", executable: executable, argumentTemplate: template, isCustom: false)
    }

    func testCopilotSaysSoWhenNoCLIIsGiven() {
        let copilot = Copilot()

        XCTAssertThrowsError(try copilot.run(cli: nil, prompt: "hello", in: URL(fileURLWithPath: "/tmp"))) {
            XCTAssertEqual($0 as? LoadoutError, .claudeNotFound)
        }
    }

    func testCopilotReportsAPathThatIsNotRunnable() {
        let copilot = Copilot()
        let bogus = cli(executable: URL(fileURLWithPath: "/nao/existe/claude"))

        XCTAssertThrowsError(try copilot.run(cli: bogus, prompt: "hello", in: URL(fileURLWithPath: "/tmp"))) {
            guard case LoadoutError.io = $0 as! LoadoutError else {
                return XCTFail("it should explain that it could not run; got \($0)")
            }
        }
    }

    func testCopilotRunsAProcessAndCapturesItsOutput() throws {
        // `echo` stands in for the CLI: the point is the plumbing, not the model.
        let copilot = Copilot()
        let result = try copilot.run(
            cli: cli(executable: URL(fileURLWithPath: "/bin/echo")),
            prompt: "hello", in: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertTrue(result.output.contains("hello"))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testCopilotKillsAProcessThatOverrunsTheTimeout() throws {
        // A stand-in that ignores its arguments and hangs, the way a stuck CLI would.
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loadout-hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let copilot = Copilot()
        let started = Date()

        let result = try copilot.run(
            cli: cli(executable: script), prompt: "hello", in: URL(fileURLWithPath: "/tmp"), timeout: 0.4
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "it did not hang")
    }

    // MARK: AC8.3

    func testTheWatcherCoalescesABurstIntoASingleCallback() {
        let expectation = expectation(description: "one callback only")
        let watcher = Watcher(coalescing: 0.15) { expectation.fulfill() }

        for _ in 0..<50 { watcher.schedule() }

        wait(for: [expectation], timeout: 2)
        // Give any stragglers a chance to arrive before counting.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(watcher.firedCount, 1, "50 eventos, um varrimento")
    }
}
