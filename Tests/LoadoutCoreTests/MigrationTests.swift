import XCTest
@testable import LoadoutCore

/// Loadout's backups, usage index and assistant icons used to live inside `~/.claude`. Moving
/// them out is a one-off that runs at every launch, on machines that have data to lose — so
/// what is checked here is not only that it moves things, but that it never destroys anything
/// and never does the work twice.
final class MigrationTests: XCTestCase {
    private let fm = FileManager.default

    /// Puts a file where the old version of the app would have written it.
    private func writeLegacy(_ fixture: Fixture, at url: URL, _ contents: String) {
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testMovesAllThreeOutOfTheClaudeDirectory() {
        let fixture = Fixture()
        let paths = fixture.paths
        writeLegacy(fixture, at: paths.legacyBackups.appendingPathComponent("2026-01-01/skills/a/SKILL.md"), "copy")
        writeLegacy(fixture, at: paths.legacyIndex, "base de dados")
        writeLegacy(fixture, at: paths.legacyCLIIcons.appendingPathComponent("kiro.png"), "png")

        let moved = paths.migrateOutOfClaudeDirectory()

        XCTAssertEqual(moved, Paths.Migration(backups: true, index: true, icons: true))
        XCTAssertEqual(
            try? String(contentsOf: paths.backups.appendingPathComponent("2026-01-01/skills/a/SKILL.md"), encoding: .utf8),
            "copy"
        )
        XCTAssertEqual(try? String(contentsOf: paths.index, encoding: .utf8), "base de dados")
        XCTAssertTrue(fm.fileExists(atPath: paths.cliIcons.appendingPathComponent("kiro.png").path))
        // And nothing of ours is left behind in someone else's directory.
        XCTAssertFalse(fm.fileExists(atPath: paths.legacyBackups.path))
        XCTAssertFalse(fm.fileExists(atPath: paths.legacySupport.path))
    }

    /// SQLite keeps its write-ahead log beside the database. A database moved without it is a
    /// database that quietly lost its last transactions.
    func testTakesTheIndexSidecarFilesWithIt() {
        let fixture = Fixture()
        let paths = fixture.paths
        writeLegacy(fixture, at: paths.legacyIndex, "db")
        writeLegacy(fixture, at: URL(fileURLWithPath: paths.legacyIndex.path + "-wal"), "wal")
        writeLegacy(fixture, at: URL(fileURLWithPath: paths.legacyIndex.path + "-shm"), "shm")

        paths.migrateOutOfClaudeDirectory()

        XCTAssertEqual(try? String(contentsOf: URL(fileURLWithPath: paths.index.path + "-wal"), encoding: .utf8), "wal")
        XCTAssertEqual(try? String(contentsOf: URL(fileURLWithPath: paths.index.path + "-shm"), encoding: .utf8), "shm")
    }

    /// The second launch, and every launch after it.
    func testDoesNothingOnceThereIsNothingToMove() {
        let fixture = Fixture()
        XCTAssertFalse(fixture.paths.migrateOutOfClaudeDirectory().movedAnything)
        XCTAssertNil(fixture.paths.migrateOutOfClaudeDirectory().summary)
    }

    /// The case that must never lose data: something already at the destination. The old copy
    /// is left exactly where it is rather than being overwritten or merged blind.
    func testNeverOverwritesWhatIsAlreadyInTheNewPlace() {
        let fixture = Fixture()
        let paths = fixture.paths
        writeLegacy(fixture, at: paths.legacyIndex, "antigo")
        writeLegacy(fixture, at: paths.index, "novo")

        XCTAssertFalse(paths.migrateOutOfClaudeDirectory().index)
        XCTAssertEqual(try? String(contentsOf: paths.index, encoding: .utf8), "novo")
        XCTAssertEqual(try? String(contentsOf: paths.legacyIndex, encoding: .utf8), "antigo")
    }

    /// Whatever else is in `~/.claude/.loadout` is not ours to delete.
    func testLeavesTheOldFolderAloneWhenSomethingElseIsInIt() {
        let fixture = Fixture()
        let paths = fixture.paths
        writeLegacy(fixture, at: paths.legacyIndex, "db")
        writeLegacy(fixture, at: paths.legacySupport.appendingPathComponent("de-outra-pessoa.json"), "{}")

        paths.migrateOutOfClaudeDirectory()

        XCTAssertTrue(
            fm.fileExists(atPath: paths.legacySupport.appendingPathComponent("de-outra-pessoa.json").path)
        )
    }

    /// The whole point: none of it is inside `~/.claude` any more.
    func testTheNewPathsAreOutsideTheClaudeDirectory() {
        let paths = Paths(home: URL(fileURLWithPath: "/tmp/casa"))
        for url in [paths.backups, paths.index, paths.cliIcons] {
            XCTAssertFalse(url.path.contains("/.claude"), "\(url.path) is still inside .claude")
            XCTAssertTrue(url.path.hasPrefix(paths.support.path))
        }
    }
}
