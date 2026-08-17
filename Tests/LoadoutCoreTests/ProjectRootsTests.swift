import XCTest
@testable import LoadoutCore

/// Finding somebody's repositories without asking them to maintain a list.
///
/// The case this exists for: a person whose repositories sit in `~/work`, `~/side` and
/// `~/clients`, who has never heard of `~/Projects/INDEX.md`. Before this, they saw no projects
/// at all and nothing on screen explained why.
final class ProjectRootsTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loadout-roots-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    @discardableResult
    private func repo(_ relative: String, marker: String = ".git") -> URL {
        let url = home.appendingPathComponent(relative)
        try! fm.createDirectory(at: url.appendingPathComponent(marker), withIntermediateDirectories: true)
        return url
    }

    private func roots(_ relatives: [String]) -> ProjectRoots {
        ProjectRoots(folders: relatives.map { home.appendingPathComponent($0) })
    }

    // MARK: - Finding them

    func testRepositoriesAreFoundInEveryChosenFolder() {
        repo("work/acme-api")
        repo("work/acme-web")
        repo("side/pixel-garden")

        let found = roots(["work", "side"]).discover(home: home)

        XCTAssertEqual(found.map(\.name).sorted(), ["acme-api", "acme-web", "pixel-garden"])
    }

    /// A repository one level deeper still counts — `~/clients/nova/site` is a real shape.
    func testARepositoryTwoLevelsDownIsStillFound() {
        repo("clients/nova/site")
        XCTAssertEqual(roots(["clients"]).discover(home: home).map(\.name), ["site"])
    }

    /// A folder configured for an assistant but not under git is still somewhere you work.
    func testAFolderWithClaudeButNoGitCounts() {
        repo("work/notes", marker: ".claude")
        XCTAssertEqual(roots(["work"]).discover(home: home).map(\.name), ["notes"])
    }

    /// The search stops at a repository rather than walking into it, so a monorepo's own
    /// subfolders do not each become a project.
    func testItDoesNotDescendIntoARepository() {
        repo("work/monorepo")
        try! fm.createDirectory(
            at: home.appendingPathComponent("work/monorepo/packages/web/.git"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(roots(["work"]).discover(home: home).map(\.name), ["monorepo"])
    }

    func testNodeModulesIsNeverSearched() {
        try! fm.createDirectory(
            at: home.appendingPathComponent("work/node_modules/some-package/.git"),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(roots(["work"]).discover(home: home).isEmpty)
    }

    /// Two repositories with the same folder name are told apart by where they sit.
    func testTwoProjectsNamedTheSameAreDistinguishedByTheirPath() {
        repo("clients/nova/site")
        repo("clients/acme/site")

        let found = roots(["clients"]).discover(home: home)

        XCTAssertEqual(found.map(\.relativePath).sorted(), ["acme/site", "nova/site"])
        XCTAssertEqual(Set(found.map(\.id)).count, 2, "two rows, not one hiding the other")
    }

    func testAFolderListedTwiceDoesNotDoubleItsProjects() {
        repo("work/acme-api")
        XCTAssertEqual(roots(["work", "work"]).discover(home: home).count, 1)
    }

    func testAChosenFolderThatDoesNotExistIsIgnoredRatherThanFatal() {
        repo("work/acme-api")
        XCTAssertEqual(roots(["work", "nowhere"]).discover(home: home).map(\.name), ["acme-api"])
    }

    /// The folder somebody points at is a place to look inside, never the answer itself.
    ///
    /// A real `~/Projects` had a `.claude` of its own — house instructions for the whole tree — and
    /// the search stopped dead on it, reporting one project where there were seventy-nine.
    func testTheChosenFolderIsNotItselfTheProject() {
        try! fm.createDirectory(
            at: home.appendingPathComponent("Projects/.claude"), withIntermediateDirectories: true
        )
        repo("Projects/PERSONAL/brain-box")
        repo("Projects/TGC/open-mercato")

        let found = roots(["Projects"]).discover(home: home)

        XCTAssertEqual(found.map(\.name).sorted(), ["brain-box", "open-mercato"])
        XCTAssertFalse(found.contains { $0.name == "Projects" }, "the folder you chose is not a project")
    }

    /// Three levels down, which two was not: `~/Projects/PERSONAL/APPS/loadout` is a real path on a
    /// real machine, and a shallower limit found none of them while reporting success.
    func testARepositoryThreeLevelsDownIsFound() {
        repo("Projects/PERSONAL/APPS/loadout")
        XCTAssertEqual(roots(["Projects"]).discover(home: home).map(\.name), ["loadout"])
    }

    // MARK: - Remembering the choice

    /// Stored with `~` for the home folder, so the list survives the account being renamed.
    func testFoldersAreStoredRelativeToHome() {
        let defaults = UserDefaults(suiteName: "loadout-roots-test")!
        defaults.removePersistentDomain(forName: "loadout-roots-test")
        roots(["work", "side"]).save(to: defaults, home: home)

        XCTAssertEqual(
            defaults.stringArray(forKey: ProjectRoots.defaultsKey),
            ["~/work", "~/side"]
        )
        XCTAssertEqual(
            ProjectRoots.load(defaults: defaults, home: home).folders.map(\.lastPathComponent),
            ["work", "side"]
        )
    }

    func testAFolderOutsideHomeIsStoredWhole() {
        let outside = URL(fileURLWithPath: "/Volumes/Work/code")
        ProjectRoots(folders: [outside]).save(
            to: UserDefaults(suiteName: "loadout-roots-outside")!, home: home
        )
        XCTAssertEqual(
            UserDefaults(suiteName: "loadout-roots-outside")!
                .stringArray(forKey: ProjectRoots.defaultsKey),
            ["/Volumes/Work/code"]
        )
    }

    /// Nothing chosen yet is an empty list, not a crash and not a guess applied silently.
    func testNothingChosenYetFindsNothing() {
        let defaults = UserDefaults(suiteName: "loadout-roots-empty")!
        defaults.removePersistentDomain(forName: "loadout-roots-empty")
        XCTAssertTrue(ProjectRoots.load(defaults: defaults, home: home).folders.isEmpty)
    }

    // MARK: - One source only

    /// The hand-written `~/Projects/INDEX.md` used to be a second source. It was one person's
    /// habit, so everybody else opened the app to nothing and no explanation. A repository is now
    /// found the same way for everyone, and a stray index file changes nothing.
    func testAnIndexFileIsNoLongerRead() throws {
        repo("work/acme-api")
        let listed = home.appendingPathComponent("Projects/listed-by-hand")
        try fm.createDirectory(at: listed, withIntermediateDirectories: true)
        try "| `listed-by-hand` | written down |".write(
            to: home.appendingPathComponent("Projects/INDEX.md"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(roots(["work"]).discover(home: home).map(\.name), ["acme-api"])
    }

    /// And a folder listed in such a file is found like any other, once its folder is chosen —
    /// because it holds a repository, not because it was written down.
    func testAFolderIsFoundOnItsOwnMeritsOnce() throws {
        repo("Projects/listed-by-hand")
        XCTAssertEqual(
            roots(["Projects"]).discover(home: home).map(\.name), ["listed-by-hand"]
        )
    }

    // MARK: - Guessing on first run

    /// Only folders that exist AND hold a repository are offered: proposing an empty `~/Developer`
    /// teaches somebody the app is guessing.
    func testOnlyFoldersThatActuallyHoldRepositoriesAreSuggested() {
        repo("Projects/real-one")
        try! fm.createDirectory(at: home.appendingPathComponent("Developer"), withIntermediateDirectories: true)

        let suggested = ProjectRoots.likelyFolders(home: home).map(\.lastPathComponent)

        XCTAssertEqual(suggested, ["Projects"])
        XCTAssertFalse(suggested.contains("Developer"), "an empty folder is not a suggestion")
    }
}
