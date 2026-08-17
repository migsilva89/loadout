import XCTest
@testable import LoadoutCore

/// Clearing what Loadout leaves behind.
///
/// Backups had nothing removing them: every edit made a copy and no copy was ever taken away, so
/// the folder only grew. The rule is thirty days, and it now applies without anybody asking.
final class HousekeepingTests: XCTestCase {
    private let fm = FileManager.default

    private func snapshot(_ fixture: Fixture, daysAgo: Int, named name: String) {
        let stamp = Date().addingTimeInterval(-Double(daysAgo) * 24 * 3600)
        let skill = fixture.skill(name)
        try! Backups(paths: fixture.paths).snapshot(skill.deletingLastPathComponent(), stamp: stamp)
    }

    func testSnapshotsOlderThanThirtyDaysAreSweptAndNewerOnesAreNot() throws {
        let fixture = Fixture()
        snapshot(fixture, daysAgo: 60, named: "old-one")
        snapshot(fixture, daysAgo: 2, named: "recent-one")
        let housekeeping = Housekeeping(paths: fixture.paths)

        XCTAssertEqual(housekeeping.report().snapshots, 2)
        XCTAssertEqual(housekeeping.report().expiredSnapshots, 1, "only the old one is expired")

        let done = try housekeeping.sweep()

        XCTAssertEqual(done.expiredSnapshots, 1)
        XCTAssertEqual(housekeeping.report().snapshots, 1, "the recent copy is still there")
    }

    /// Sweeping twice does not report the same work twice.
    func testASecondSweepFindsNothingLeftToDo() throws {
        let fixture = Fixture()
        snapshot(fixture, daysAgo: 60, named: "old-one")
        let housekeeping = Housekeeping(paths: fixture.paths)

        _ = try housekeeping.sweep()

        XCTAssertEqual(try housekeeping.sweep().expiredSnapshots, 0)
        XCTAssertTrue(housekeeping.report().isEmpty)
    }

    func testNothingToSweepIsNotAnError() throws {
        let fixture = Fixture()
        let report = try Housekeeping(paths: fixture.paths).sweep()
        XCTAssertEqual(report.expiredSnapshots, 0)
        XCTAssertEqual(report.strandedRecords, 0)
    }

    // MARK: - Records that outlived what they described

    /// A record for a server that is merely switched off is doing its job, and must survive:
    /// forgetting it is how a switched-off server becomes unrecoverable.
    func testARecordForASwitchedOffServerIsKept() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm", command: "npx notebooklm-mcp")
        let mutations = Mutations(paths: fixture.paths)
        let server = InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.kind == .mcp && $0.name == "notebooklm" }!
        try mutations.setServer(server, enabled: false)

        let housekeeping = Housekeeping(paths: fixture.paths)

        XCTAssertEqual(housekeeping.report().strandedRecords, 0, "it is off, not gone")
        _ = try housekeeping.sweep()
        XCTAssertNotNil(
            OffRecords(paths: fixture.paths).server(named: "notebooklm"),
            "the record survives, or the server could never be put back"
        )
    }

    /// A record for a server that is back in the file is left over: the app shows the live one, and
    /// the remembered copy describes nothing.
    func testARecordForAServerThatCameBackIsForgotten() throws {
        let fixture = Fixture()
        fixture.mcpServer("notebooklm", command: "npx notebooklm-mcp")
        let records = OffRecords(paths: fixture.paths)
        try fm.createDirectory(at: fixture.paths.support, withIntermediateDirectories: true)
        try records.rememberServer(#"{"command":"npx old"}"#, named: "notebooklm")

        let housekeeping = Housekeeping(paths: fixture.paths)
        XCTAssertEqual(housekeeping.report().strandedRecords, 1)

        let done = try housekeeping.sweep()

        XCTAssertEqual(done.strandedRecords, 1)
        XCTAssertNil(OffRecords(paths: fixture.paths).server(named: "notebooklm"))
    }

    /// The bug this file exists to prevent. A record whose server is *not* in the file is a
    /// switched-off server, and that record is the only copy of its configuration.
    func testAnUnreadableClaudeJSONNeverStrandsAnything() throws {
        let fixture = Fixture()
        let records = OffRecords(paths: fixture.paths)
        try fm.createDirectory(at: fixture.paths.support, withIntermediateDirectories: true)
        try records.rememberServer(#"{"command":"npx notebooklm-mcp"}"#, named: "notebooklm")
        // Present but unreadable, which is the case that used to delete everything.
        try "{{ not json".write(to: fixture.paths.claudeJSON, atomically: true, encoding: .utf8)

        let housekeeping = Housekeeping(paths: fixture.paths)
        XCTAssertEqual(housekeeping.report().strandedRecords, 0)

        _ = try housekeeping.sweep()

        XCTAssertNotNil(
            OffRecords(paths: fixture.paths).server(named: "notebooklm"),
            "an unreadable file is unknown, and unknown is not permission to delete"
        )
    }

    /// And the same when there is no `~/.claude.json` at all.
    func testAMissingClaudeJSONNeverStrandsAnything() throws {
        let fixture = Fixture()
        let records = OffRecords(paths: fixture.paths)
        try fm.createDirectory(at: fixture.paths.support, withIntermediateDirectories: true)
        try records.rememberServer(#"{"command":"npx notebooklm-mcp"}"#, named: "notebooklm")

        _ = try Housekeeping(paths: fixture.paths).sweep()

        XCTAssertNotNil(OffRecords(paths: fixture.paths).server(named: "notebooklm"))
    }

    /// An unreadable record is reported and left alone. Deleting a file nobody can read answers a
    /// question the wrong way, and something switched off may be written in it.
    func testAnUnreadableRecordIsReportedAndNeverSwept() throws {
        let fixture = Fixture()
        let records = OffRecords(paths: fixture.paths)
        try fm.createDirectory(at: fixture.paths.support, withIntermediateDirectories: true)
        try "{{ this is not json".write(to: records.serversFile, atomically: true, encoding: .utf8)

        let housekeeping = Housekeeping(paths: fixture.paths)
        XCTAssertEqual(housekeeping.report().unreadableRecords.map(\.lastPathComponent), ["mcp-off.json"])

        _ = try housekeeping.sweep()

        XCTAssertTrue(fm.fileExists(atPath: records.serversFile.path), "left where it was")
    }
}
