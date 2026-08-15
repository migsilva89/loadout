import XCTest
@testable import LoadoutCore

/// The assistant is given write permission and runs commands of its own accord, so it is never
/// pointed at `~/.claude`. It gets a copy. These tests are the proof of that promise: the real
/// folder must come out of a conversation untouched, and a copy must never be thrown away while a
/// change inside it is still waiting for a decision.
final class AskWorkspaceTests: XCTestCase {
    private let fm = FileManager.default
    private var temporary: URL!

    override func setUp() {
        super.setUp()
        temporary = fm.temporaryDirectory.appendingPathComponent("loadout-ask-\(UUID().uuidString)")
        try! fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: temporary)
        super.tearDown()
    }

    /// A skill folder as it really is: the document, plus a script in a subfolder beside it.
    private func makeSkill() -> URL {
        let folder = temporary.appendingPathComponent("real/my-skill")
        try! fm.createDirectory(at: folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try! "---\nname: my-skill\ndescription: does stuff\n---\n\n# My skill\n"
            .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try! "#!/bin/sh\necho old\n"
            .write(to: folder.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
        return folder
    }

    private var workspaces: AskWorkspaces {
        AskWorkspaces(root: temporary.appendingPathComponent("ask-workspaces"))
    }

    func testTheCopyHasEverythingTheFolderHad() throws {
        let origin = makeSkill()

        let workspace = try workspaces.open(itemID: "skill:my-skill", origin: origin)

        XCTAssertTrue(fm.fileExists(atPath: workspace.root.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(fm.fileExists(atPath: workspace.root.appendingPathComponent("scripts/run.sh").path))
        XCTAssertNotEqual(workspace.root.path, origin.path)
    }

    /// A second message in the same conversation must land in the copy the first one edited, or the
    /// assistant would keep rediscovering a file it had already changed.
    func testOpeningTwiceKeepsTheEditsOfTheFirstTurn() throws {
        let origin = makeSkill()
        let first = try workspaces.open(itemID: "skill:my-skill", origin: origin)
        try "changed by the assistant".write(
            to: first.root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        let second = try workspaces.open(itemID: "skill:my-skill", origin: origin)

        XCTAssertEqual(
            try String(contentsOf: second.root.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "changed by the assistant"
        )
    }

    func testChangesReportEveryFileTheAssistantTouched() throws {
        let origin = makeSkill()
        let workspace = try workspaces.open(itemID: "skill:my-skill", origin: origin)
        try "---\nname: my-skill\ndescription: better\n---\n\n# My skill\n".write(
            to: workspace.root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "#!/bin/sh\necho new\n".write(
            to: workspace.root.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8
        )

        let changes = workspaces.changes(in: workspace)

        XCTAssertEqual(changes.map(\.id), ["SKILL.md", "scripts/run.sh"])
        XCTAssertEqual(changes[0].blocks.count, 1)
        XCTAssertFalse(changes[0].isNew)
    }

    func testAFileTheAssistantCreatedIsReportedAsNew() throws {
        let origin = makeSkill()
        let workspace = try workspaces.open(itemID: "skill:my-skill", origin: origin)
        try "reference material".write(
            to: workspace.root.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8
        )

        let notes = workspaces.changes(in: workspace).first { $0.id == "NOTES.md" }

        XCTAssertEqual(notes?.isNew, true)
        XCTAssertEqual(notes?.original, "")
    }

    func testAnUntouchedFolderReportsNoChanges() throws {
        let origin = makeSkill()
        let workspace = try workspaces.open(itemID: "skill:my-skill", origin: origin)

        XCTAssertTrue(workspaces.changes(in: workspace).isEmpty)
    }

    /// The whole point of the copy: whatever happened in there, the real folder is as it was.
    func testTheRealFolderIsNeverTouched() throws {
        let origin = makeSkill()
        let before = try String(contentsOf: origin.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let workspace = try workspaces.open(itemID: "skill:my-skill", origin: origin)
        try "wrecked".write(
            to: workspace.root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(
            try String(contentsOf: origin.appendingPathComponent("SKILL.md"), encoding: .utf8), before
        )
    }

    func testACopyWithUndecidedChangesIsNotThrownAway() throws {
        let origin = makeSkill()
        let workspace = try workspaces.open(itemID: "skill:my-skill", origin: origin)

        XCTAssertThrowsError(try workspaces.remove(itemID: "skill:my-skill", hasPendingBlocks: true))
        XCTAssertTrue(fm.fileExists(atPath: workspace.root.path))
    }

    func testRemovingACopyWithNothingPendingWorks() throws {
        let origin = makeSkill()
        let workspace = try workspaces.open(itemID: "skill:my-skill", origin: origin)

        try workspaces.remove(itemID: "skill:my-skill", hasPendingBlocks: false)

        XCTAssertFalse(fm.fileExists(atPath: workspace.root.path))
    }

    /// Nothing else in the app remembers these folders exist, so launch sweeps the ones whose
    /// conversation is gone. The ones still in use must survive that sweep.
    func testLaunchSweepsCopiesWhoseConversationIsGone() throws {
        let origin = makeSkill()
        try workspaces.open(itemID: "skill:kept", origin: origin)
        try workspaces.open(itemID: "skill:gone", origin: origin)

        let removed = workspaces.removeOrphans(keeping: ["skill:kept"])

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(workspaces.exists(for: "skill:kept"))
        XCTAssertFalse(workspaces.exists(for: "skill:gone"))
    }

    /// A shared skill's folder in `~/.claude/skills` is a symlink into `~/.agents/skills`. Copying
    /// the link instead of the files gave the assistant a working directory that pointed at nothing,
    /// and it refused to start — which is exactly what happened the first time this was run against
    /// a real home.
    func testASkillWhoseFolderIsASymlinkIsCopiedProperly() throws {
        let real = makeSkill()
        let link = temporary.appendingPathComponent("real/linked-skill")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let workspace = try workspaces.open(itemID: "skill:linked", origin: link)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: workspace.root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            try String(contentsOf: workspace.root.appendingPathComponent("SKILL.md"), encoding: .utf8),
            try String(contentsOf: real.appendingPathComponent("SKILL.md"), encoding: .utf8)
        )
    }

    /// And its changes must be compared against the files the link points at, not the link.
    func testChangesToALinkedSkillAreFound() throws {
        let real = makeSkill()
        let link = temporary.appendingPathComponent("real/linked-skill")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let workspace = try workspaces.open(itemID: "skill:linked", origin: link)
        try "---\nname: my-skill\ndescription: better\n---\n\n# My skill\n".write(
            to: workspace.root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        let changes = workspaces.changes(in: workspace)

        XCTAssertEqual(changes.map(\.id), ["SKILL.md"])
        XCTAssertEqual(changes[0].blocks.count, 1)
        XCTAssertFalse(changes[0].isNew)
    }

    /// The copies the broken version left behind are dangling links. One must not block the
    /// conversation until somebody deletes it by hand.
    func testADanglingCopyFromTheBrokenVersionIsReplaced() throws {
        let origin = makeSkill()
        try fm.createDirectory(at: workspaces.root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: workspaces.directory(for: "skill:my-skill"),
            withDestinationURL: temporary.appendingPathComponent("nowhere")
        )

        let workspace = try workspaces.open(itemID: "skill:my-skill", origin: origin)

        XCTAssertTrue(fm.fileExists(atPath: workspace.root.appendingPathComponent("SKILL.md").path))
    }

    /// An item id is built from a path and can hold a slash, which would otherwise be read as a
    /// subfolder and put the copy somewhere nobody looks for it.
    func testAnIDWithASlashStaysOneFolder() {
        XCTAssertFalse(workspaces.slug("skill:~/.claude/skills/a").contains("/"))
    }
}
