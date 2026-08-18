import XCTest
@testable import LoadoutCore

/// AC3 — enable and disable, AC4 — edit, create, delete, AC5 — the safety net.
final class MutationTests: XCTestCase {

    private func item(named name: String, in fixture: Fixture) -> Item {
        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        return items.first { $0.name == name }!
    }

    // MARK: AC3.1 / AC3.2 / AC5.2

    func testDisablingMovesTheWholeFolderToSkillsOff() throws {
        let fixture = Fixture()
        fixture.skill("imark-review", extraFile: "echo hello")
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(item(named: "imark-review", in: fixture))

        let parked = fixture.paths.skillsOff.appendingPathComponent("imark-review")
        XCTAssertFalse(fixture.exists(fixture.paths.skills.appendingPathComponent("imark-review")))
        XCTAssertTrue(fixture.exists(parked.appendingPathComponent("SKILL.md")))
        XCTAssertTrue(
            fixture.exists(parked.appendingPathComponent("scripts/run.sh")),
            "the extra files travel with it"
        )
    }

    func testEnablingBringsItBack() throws {
        let fixture = Fixture()
        fixture.skill("parada", disabled: true)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.enableSkill(item(named: "parada", in: fixture))

        XCTAssertTrue(fixture.exists(
            fixture.paths.skills.appendingPathComponent("parada/SKILL.md")
        ))
        XCTAssertFalse(fixture.exists(fixture.paths.skillsOff.appendingPathComponent("parada")))
    }

    // MARK: AC3.3

    func testDisablingRefusesWhenTheDestinationExists() {
        let fixture = Fixture()
        fixture.skill("dupla")
        fixture.skill("dupla", disabled: true)
        let mutations = Mutations(paths: fixture.paths)
        let live = InventoryScanner(paths: fixture.paths).scanAll().items
            .first { $0.name == "dupla" && $0.enabled }!

        XCTAssertThrowsError(try mutations.disableSkill(live)) { error in
            guard case LoadoutError.alreadyExists = error as! LoadoutError else {
                return XCTFail("erro errado: \(error)")
            }
        }
        XCTAssertTrue(
            fixture.exists(fixture.paths.skills.appendingPathComponent("dupla/SKILL.md")),
            "the original stays where it was"
        )
    }

    // MARK: AC3.4

    func testTogglingAPluginPreservesEverythingElseInSettings() throws {
        let fixture = Fixture()
        fixture.settings([
            "permissions": ["allow": ["WebSearch", "Bash(npx:*)"]],
            "enabledPlugins": ["outro@mkt": true],
        ])
        fixture.plugin("vercel", marketplace: "official", skills: ["deploy"])
        let mutations = Mutations(paths: fixture.paths)
        let plugin = InventoryScanner(paths: fixture.paths).installedPlugins().first { $0.name == "vercel" }!

        try mutations.setPlugin(plugin, enabled: false)

        let data = try Data(contentsOf: fixture.paths.localSettings)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let flags = root["enabledPlugins"] as! [String: Any]
        XCTAssertEqual(flags["vercel@official"] as? Bool, false)
        XCTAssertEqual(flags["outro@mkt"] as? Bool, true, "as outras flags ficam")
        let permissions = root["permissions"] as? [String: Any]
        XCTAssertEqual(
            (permissions?["allow"] as? [String])?.count, 2,
            "the rest of the file survives"
        )
        XCTAssertEqual(InventoryScanner(paths: fixture.paths).installedPlugins().first?.enabled, false)
    }

    // MARK: Removing a whole plugin

    func testRemovingAPluginTakesTheFolderTheEntryAndTheFlag() throws {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["deploy"], enabled: false)
        fixture.plugin("remotion", marketplace: "official", skills: ["render"])
        let mutations = Mutations(paths: fixture.paths)
        let scanner = InventoryScanner(paths: fixture.paths)
        let plugin = scanner.installedPlugins().first { $0.name == "vercel" }!

        try mutations.removePlugin(plugin)

        XCTAssertFalse(fixture.exists(plugin.installPath), "the folder is gone from the cache")
        let register = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.installedPlugins)
        ) as! [String: Any]
        let plugins = register["plugins"] as! [String: Any]
        XCTAssertNil(plugins["vercel@official"], "the entry leaves Claude Code's register")
        XCTAssertNotNil(plugins["remotion@official"], "and the other plugin is untouched")
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.localSettings)
        ) as! [String: Any]
        let flags = settings["enabledPlugins"] as? [String: Any] ?? [:]
        XCTAssertNil(flags["vercel@official"], "the stale on/off answer goes with it")
        XCTAssertEqual(
            scanner.installedPlugins().count, 1, "and the app stops listing it"
        )
    }

    /// The install path comes out of a file this app does not write. Pointed anywhere outside the
    /// plugin cache it must refuse, or a corrupted register aims the Trash at a home directory.
    func testRemovingRefusesAnInstallPathOutsideThePluginCache() throws {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["deploy"])
        let outside = fixture.root.appendingPathComponent("Documents/precious")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let plugin = PluginInfo(
            id: "vercel@official", name: "vercel", marketplace: "official", version: "1.0.0",
            installPath: outside, enabled: true
        )
        let mutations = Mutations(paths: fixture.paths)

        XCTAssertThrowsError(try mutations.removePlugin(plugin))
        XCTAssertTrue(fixture.exists(outside), "nothing outside the cache is touched")
        let register = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.installedPlugins)
        ) as! [String: Any]
        XCTAssertNotNil(
            (register["plugins"] as! [String: Any])["vercel@official"],
            "and it refuses before writing the register"
        )
    }

    // MARK: AC4.6

    /// A plugin's files stay read-only. Its skills *can* now be switched off one by one, but only
    /// through `disablePluginSkill`, which moves the folder aside inside the plugin's own version —
    /// the personal path would park it in someone else's tree.
    func testPluginItemsAreReadOnlyAndNotDisabledThroughThePersonalPath() {
        let fixture = Fixture()
        fixture.plugin("vercel", skills: ["deploy"])
        let mutations = Mutations(paths: fixture.paths)
        let pluginSkill = item(named: "deploy", in: fixture)
        let before = fixture.read(pluginSkill.path!)

        XCTAssertThrowsError(try mutations.disableSkill(pluginSkill))
        XCTAssertThrowsError(try mutations.save(pluginSkill, contents: "---\nname: x\ndescription: y\n---\n"))
        XCTAssertThrowsError(try mutations.delete(pluginSkill))
        XCTAssertEqual(fixture.read(pluginSkill.path!), before, "the file was left alone")
    }

    // MARK: AC4.2

    func testSavingValidatesTheFrontmatterBeforeTouchingTheDisk() {
        let fixture = Fixture()
        fixture.skill("valida")
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "valida", in: fixture)
        let original = fixture.read(skill.path!)

        XCTAssertThrowsError(try mutations.save(skill, contents: "---\ndescription: this only\n---\n"))
        XCTAssertThrowsError(try mutations.save(skill, contents: "---\nname: valida\n---\n"))
        XCTAssertThrowsError(
            try mutations.save(skill, contents: "---\nname: Nome Errado\ndescription: x\n---\n")
        )
        XCTAssertEqual(fixture.read(skill.path!), original, "nada foi gravado")
    }

    func testSavingValidContentWrites() throws {
        let fixture = Fixture()
        fixture.skill("boa")
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "boa", in: fixture)
        let updated = "---\nname: good\ndescription: New description.\n---\n\nNew body."

        try mutations.save(skill, contents: updated)

        XCTAssertEqual(fixture.read(skill.path!), updated)
    }

    // MARK: AC4.3

    func testCreatingASkillWritesTheTemplate() throws {
        let fixture = Fixture()
        let mutations = Mutations(paths: fixture.paths)

        try mutations.createSkill(name: "nova-skill", description: "Dispara quando X.")

        let file = fixture.paths.skills.appendingPathComponent("nova-skill/SKILL.md")
        let text = fixture.read(file)
        XCTAssertTrue(text.contains("name: nova-skill"))
        XCTAssertTrue(text.contains("description: Dispara quando X."))
        XCTAssertNoThrow(try mutations.validateSkillDocument(text))
    }

    func testCreatingRejectsBadNamesAndCollisions() throws {
        let fixture = Fixture()
        let mutations = Mutations(paths: fixture.paths)
        try mutations.createSkill(name: "existe", description: "x")
        fixture.skill("parada", disabled: true)

        XCTAssertThrowsError(try mutations.createSkill(name: "Nome Errado", description: "x"))
        XCTAssertThrowsError(try mutations.createSkill(name: "existe", description: "x"))
        XCTAssertThrowsError(
            try mutations.createSkill(name: "parada", description: "x"),
            "it clashes with a disabled one"
        )
    }

    func testSkillNameRules() {
        XCTAssertTrue(isValidSkillName("imark-review"))
        XCTAssertTrue(isValidSkillName("seo2"))
        XCTAssertFalse(isValidSkillName(""))
        XCTAssertFalse(isValidSkillName("Imark"))
        XCTAssertFalse(isValidSkillName("with space"))
        XCTAssertFalse(isValidSkillName("acaba-"))
        XCTAssertFalse(isValidSkillName("-comeca"))
        XCTAssertFalse(isValidSkillName("under_score"))
    }

    // MARK: AC4.4

    func testDeletingSendsToTheTrashRatherThanUnlinking() throws {
        let fixture = Fixture()
        fixture.skill("descartavel")
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "descartavel", in: fixture)

        try mutations.delete(skill)

        XCTAssertFalse(fixture.exists(skill.directory!))
        // The backup is what guarantees nothing is lost for good.
        XCTAssertTrue(backupContents(fixture).contains { $0.contains("descartavel") })
    }

    // MARK: AC5.1 / AC5.2

    func testEveryWriteLeavesASnapshotBehind() throws {
        let fixture = Fixture()
        fixture.skill("with-a-copy", extraFile: "echo x")
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "with-a-copy", in: fixture)

        try mutations.save(skill, contents: "---\nname: with-a-copy\ndescription: new.\n---\n")
        try mutations.disableSkill(item(named: "with-a-copy", in: fixture))

        let backups = backupContents(fixture)
        XCTAssertTrue(backups.contains { $0.hasSuffix("skills/with-a-copy/SKILL.md") })
        // The folder's snapshot lands beside the file's rather than on top of it: two writes in the
        // same second used to share one destination, and the second deleted the first — throwing
        // away the copy of the state before any of it began.
        XCTAssertTrue(
            backups.contains { $0.contains("skills/with-a-copy") && $0.hasSuffix("scripts/run.sh") },
            "the whole tree, not just SKILL.md"
        )
    }

    func testSnapshotOfAMissingSourceIsANoOpNotACrash() throws {
        let fixture = Fixture()
        let backups = Backups(paths: fixture.paths)
        XCTAssertNil(try backups.snapshot(fixture.paths.skills.appendingPathComponent("nao-existe")))
    }

    // MARK: - Snapshot enumeration (Settings › Backups)

    func testListSnapshotsFindsOnlyStampNamedFolders() throws {
        let fixture = Fixture()
        let backups = Backups(paths: fixture.paths)
        fixture.skill("one")
        try backups.snapshot(fixture.paths.skills.appendingPathComponent("one"))

        // Something that isn't a stamp folder must never be mistaken for one.
        try FileManager.default.createDirectory(
            at: fixture.paths.backups.appendingPathComponent("not-a-stamp"),
            withIntermediateDirectories: true
        )
        try "loose file".write(
            to: fixture.paths.backups.appendingPathComponent("stray.txt"),
            atomically: true, encoding: .utf8
        )

        let snapshots = backups.listSnapshots()
        XCTAssertEqual(snapshots.count, 1, "only the folder named after a stamp counts")
        XCTAssertTrue(Backups.stampFormatter.date(from: snapshots[0].name) != nil)
    }

    func testTotalSizeSumsEveryFileAcrossEverySnapshot() throws {
        let fixture = Fixture()
        let backups = Backups(paths: fixture.paths)
        fixture.skill("one", extraFile: "some contents")
        try backups.snapshot(fixture.paths.skills.appendingPathComponent("one"))

        XCTAssertGreaterThan(backups.totalSize(), 0)
    }

    func testDeleteSnapshotsOnlyRemovesOldStampFoldersDirectlyInsideBackups() throws {
        let fixture = Fixture()
        let backups = Backups(paths: fixture.paths)
        fixture.skill("velha")
        fixture.skill("nova")

        let old = Backups.stampFormatter.date(from: "2020-01-01T00-00-00")!
        let recent = Date()
        try backups.snapshot(fixture.paths.skills.appendingPathComponent("velha"), stamp: old)
        try backups.snapshot(fixture.paths.skills.appendingPathComponent("nova"), stamp: recent)

        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let removed = try backups.deleteSnapshots(olderThan: cutoff)

        XCTAssertEqual(removed, 1, "only the old folder goes")
        let remaining = backups.listSnapshots()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNotEqual(remaining.first?.date, old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.backups.path),
                       "the backups folder itself is never deleted")
    }

    // MARK: AC5.4

    func testWriteIsAbortedWhenTheSnapshotCannotBeMade() {
        let fixture = Fixture()
        fixture.skill("bloqueada")
        // A file where the backups directory should be: creating the tree underneath must fail.
        // The app's own folder has to exist first, now that it lives outside `~/.claude` and a
        // fresh fixture home has no `Library/Application Support` in it.
        try! FileManager.default.createDirectory(
            at: fixture.paths.support, withIntermediateDirectories: true
        )
        try! "I am not a folder".write(
            to: fixture.paths.backups, atomically: true, encoding: .utf8
        )
        let mutations = Mutations(paths: fixture.paths)
        let skill = item(named: "bloqueada", in: fixture)
        let original = fixture.read(skill.path!)

        XCTAssertThrowsError(try mutations.save(skill, contents: "---\nname: bloqueada\ndescription: y\n---\n")) {
            guard case LoadoutError.backupFailed = $0 as! LoadoutError else {
                return XCTFail("it should fail at the copy; it failed with \($0)")
            }
        }
        XCTAssertEqual(fixture.read(skill.path!), original, "it did not write without a copy")
    }

    private func backupContents(_ fixture: Fixture) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: fixture.paths.backups, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { ($0 as? URL)?.path }
    }
}
