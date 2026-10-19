import XCTest
@testable import LoadoutCore

/// An assistant that left a dot-directory behind is not an assistant the person can use. Which
/// ones count as installed is decided by the app or the command-line tool, never by the folder.
final class InstalledAssistantsTests: XCTestCase {
    private let fm = FileManager.default

    private func folder(_ name: String, in fixture: Fixture) {
        try! fm.createDirectory(
            at: fixture.paths.home.appendingPathComponent(".\(name)/skills"), withIntermediateDirectories: true
        )
    }

    private func found(_ id: String, in fixture: Fixture, tools: Set<String>) -> Assistant? {
        AssistantRegistry.discover(paths: fixture.paths) { tools.contains($0) ? URL(fileURLWithPath: "/usr/bin/\($0)") : nil }
            .first { $0.id == id }
    }

    func testALeftoverFolderWithNoToolIsDiscoveredButNotInstalled() {
        let fixture = Fixture()
        folder("zzz", in: fixture)

        let leftover = found("zzz", in: fixture, tools: [])

        XCTAssertNotNil(leftover, "the scanner still has to read what is linked into it")
        XCTAssertEqual(leftover?.isInstalled, false)
    }

    func testAToolOnThePathMakesItInstalled() {
        let fixture = Fixture()
        folder("zzz", in: fixture)

        XCTAssertEqual(found("zzz", in: fixture, tools: ["zzz"])?.isInstalled, true)
    }

    func testAKnownAssistantIsFoundThroughItsOwnBinaryName() {
        let fixture = Fixture()
        folder("antigravity", in: fixture)
        try! fm.createDirectory(at: fixture.paths.antigravityHome, withIntermediateDirectories: true)

        // Antigravity's tool is called `agy`, not `antigravity`.
        XCTAssertEqual(found("antigravity", in: fixture, tools: ["agy"])?.isInstalled, true)
    }

    func testCodexIsInstalledWhenLoadoutWasGivenItsExecutable() {
        let fixture = Fixture()
        try! fm.createDirectory(at: fixture.paths.codexHome, withIntermediateDirectories: true)
        let paths = Paths(home: fixture.root, codexExecutable: URL(fileURLWithPath: "/usr/bin/true"))

        let codex = AssistantRegistry.discover(paths: paths) { _ in nil }.first { $0.id == "codex" }

        XCTAssertEqual(codex?.isInstalled, true)
    }

    func testOpencodeIsFoundFromItsConfigFolderAlone() {
        let fixture = Fixture()
        try! fm.createDirectory(
            at: fixture.paths.opencodeConfig.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let opencode = found("opencode", in: fixture, tools: ["opencode"])

        XCTAssertEqual(opencode?.isInstalled, true)
        XCTAssertEqual(opencode?.configHome, fixture.paths.opencodeConfig.deletingLastPathComponent())
    }

    func testTheScannerKeepsReadingAnUninstalledAssistantsSkills() {
        let fixture = Fixture()
        folder("zzz", in: fixture)
        let skill = fixture.paths.home.appendingPathComponent(".zzz/skills/linked")
        try! fm.createDirectory(at: skill, withIntermediateDirectories: true)
        try! "---\nname: linked\ndescription: Left behind.\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        let item = InventoryScanner(paths: fixture.paths) { _ in nil }.scanAll().items.first { $0.name == "linked" }

        XCTAssertEqual(item?.assistants, ["zzz"])
    }
}
