import XCTest
@testable import LoadoutCore

/// Antigravity CLI: discovered by the folder agy leaves under `~/.gemini`, its skills read from
/// the one global folder agy actually loads, and its usage decoded from the protobuf steps of its
/// conversation databases.
final class AntigravityTests: XCTestCase {

    private func date(daysAgo: Int) -> Date { Date().addingTimeInterval(-Double(daysAgo) * 86_400) }

    private func skillRead(_ path: String, daysAgo: Int, labelled: Bool = true) -> Fixture.AntigravityStep {
        let action = labelled ? "\"toolAction\":\"Reading skill file\"" : "\"toolAction\":\"Reading file\""
        return Fixture.AntigravityStep(
            at: date(daysAgo: daysAgo), tool: "view_file",
            arguments: "{\"AbsolutePath\":\"\(path)\",\(action)}"
        )
    }

    // MARK: - Discovery

    func testAgyIsListedOnceItHasRunEvenWithNoSkillsFolderYet() {
        let fixture = Fixture()
        try! FileManager.default.createDirectory(
            at: fixture.paths.antigravityHome, withIntermediateDirectories: true
        )

        let found = AssistantRegistry.discover(paths: fixture.paths)
        let agy = found.first { $0.id == "antigravity" }

        XCTAssertEqual(agy?.label, "Antigravity")
        XCTAssertEqual(agy?.skillsRoot, fixture.paths.antigravitySkills)
        XCTAssertEqual(agy?.hasSkillsFolder, false)
    }

    func testAgyIsNotInventedFromTheGeminiFolderAlone() {
        let fixture = Fixture()
        try! FileManager.default.createDirectory(
            at: fixture.paths.home.appendingPathComponent(".gemini/skills"), withIntermediateDirectories: true
        )

        let ids = AssistantRegistry.discover(paths: fixture.paths).map(\.id)

        XCTAssertTrue(ids.contains("gemini"), "the Gemini CLI's own folder is still Gemini's")
        XCTAssertFalse(ids.contains("antigravity"))
    }

    func testAgySkillsAreReadFromTheConfigFolderAndMergedWithClaudes() {
        let fixture = Fixture()
        fixture.skill("shared-one")
        let root = fixture.paths.antigravitySkills.appendingPathComponent("shared-one")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! "---\nname: shared-one\ndescription: x\n---\n".write(
            to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try! FileManager.default.createDirectory(
            at: fixture.paths.antigravityHome, withIntermediateDirectories: true
        )

        let items = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.assistants, ["claude", "antigravity"])
    }

    func testTheSkillsRootForAgyIsNotADotDirectory() {
        let paths = Paths(home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(paths.skillsRoot(forAssistant: "antigravity").path, "/Users/me/.gemini/config/skills")
    }

    // MARK: - Usage

    func testALabelledSkillReadCountsAsAnExplicitUse() throws {
        let fixture = Fixture()
        fixture.antigravityConversation("C-1", steps: [
            Fixture.AntigravityStep(at: date(daysAgo: 3)),
            skillRead("/Users/me/.gemini/config/skills/human-copywrite/SKILL.md", daysAgo: 3),
        ])
        let index = try UsageIndex(paths: fixture.paths, sources: UsageIndex.liveSources(paths: fixture.paths))

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill)["human-copywrite"]?.count, 1)
        let occurrence = try XCTUnwrap(index.occurrences(kind: .skill, key: "human-copywrite").first)
        XCTAssertEqual(occurrence.assistant, "antigravity")
        XCTAssertEqual(occurrence.evidence, .explicit)
        XCTAssertEqual(occurrence.project, "meu-repo")
    }

    func testAPlainReadOfASkillFileIsInferredAndOtherReadsAreNothing() throws {
        let fixture = Fixture()
        fixture.antigravityConversation("C-2", workspace: nil, steps: [
            skillRead("/Users/me/.gemini/antigravity-cli/builtin/skills/antigravity_guide/SKILL.md", daysAgo: 1, labelled: false),
            skillRead("/Users/me/meu-repo/README.md", daysAgo: 1, labelled: false),
        ])
        let source = AntigravityUsageSource(paths: fixture.paths)

        let events = source.events(in: source.historyFiles()[0], since: date(daysAgo: 30))

        XCTAssertEqual(events.map(\.key), ["antigravity_guide"])
        XCTAssertEqual(events.first?.evidence, .inferred)
        XCTAssertEqual(events.first?.project, "?")
        XCTAssertEqual(events.first?.sessionID, "C-2")
    }

    func testStepsOlderThanTheWindowAreLeftOut() throws {
        let fixture = Fixture()
        fixture.antigravityConversation("C-3", steps: [
            skillRead("/x/skills/old/SKILL.md", daysAgo: 200),
            skillRead("/x/skills/new/SKILL.md", daysAgo: 2),
        ])
        let source = AntigravityUsageSource(paths: fixture.paths)

        let events = source.events(in: source.historyFiles()[0], since: date(daysAgo: 90))

        XCTAssertEqual(events.map(\.key), ["new"])
    }

    func testNoConversationsMeansNoHistoryNotAnError() {
        let fixture = Fixture()
        XCTAssertEqual(AntigravityUsageSource(paths: fixture.paths).state(), .noHistory)
    }

    func testTheProtobufWalkerStopsCleanlyOnATruncatedBlob() {
        let truncated = Data([0x0A, 0x0C, 0x08, 0xEE, 0xA0])
        XCTAssertTrue(Protobuf.fields(in: truncated).isEmpty)
        XCTAssertNil(AntigravityUsageSource.step(in: truncated))
    }

    // MARK: - Ask

    func testAgyIsAnAskTargetWhenInstalled() {
        let found = AssistantCLIRegistry.discover(customEntries: []) { name in
            name == "agy" ? URL(fileURLWithPath: "/usr/local/bin/agy") : nil
        }
        let agy = found.first { $0.id == "antigravity" }

        XCTAssertEqual(agy?.arguments(for: "hi there"), ["-p", "hi there"])
        XCTAssertNil(agy?.chat, "one-shot only: no conversation dialect has been mapped for agy yet")
    }
}
