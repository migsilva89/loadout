import XCTest
@testable import LoadoutCore

/// `~/.agents/skills` as a place to read from, rather than only somewhere assistants link into.
///
/// The bug these start from: someone keeping every skill there, and using them from something that
/// reads the folder directly, saw an empty list, because the inventory only walked assistants.
final class SharedStoreTests: XCTestCase {
    private let fm = FileManager.default

    // MARK: - Fixtures

    @discardableResult
    private func stored(_ name: String, description: String = "From the store.", in fixture: Fixture) -> URL {
        write(name, description: description, into: fixture.paths.sharedSkills)
    }

    @discardableResult
    private func parkedInStore(_ name: String, description: String = "Parked.", in fixture: Fixture) -> URL {
        write(name, description: description, into: storeOff(fixture))
    }

    @discardableResult
    private func own(_ name: String, description: String = "Private.", assistant id: String, in fixture: Fixture) -> URL {
        write(name, description: description, into: fixture.paths.skillsRoot(forAssistant: id))
    }

    private func write(_ name: String, description: String, into root: URL) -> URL {
        let folder = root.appendingPathComponent(name)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! "---\nname: \(name)\ndescription: \(description)\n---\n\nBody.".write(
            to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        return folder
    }

    private func link(_ name: String, assistant id: String, to target: URL, in fixture: Fixture) {
        let root = fixture.paths.skillsRoot(forAssistant: id)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        try! fm.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: target)
    }

    private func storeOff(_ fixture: Fixture) -> URL {
        fixture.paths.sharedSkills.deletingLastPathComponent().appendingPathComponent("skills-off")
    }

    private func skills(_ name: String, in fixture: Fixture) -> [Item] {
        InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill && $0.name == name }
    }

    private func onlySkill(_ name: String, in fixture: Fixture) -> Item {
        let found = skills(name, in: fixture)
        XCTAssertEqual(found.count, 1, "\(name) is one row")
        return found[0]
    }

    /// The row for the store's copy of a name, and the row for the private one.
    private func pair(_ name: String, in fixture: Fixture) -> (shared: Item, own: Item) {
        let found = skills(name, in: fixture)
        return (found.first { $0.inSharedStore }!, found.first { !$0.inSharedStore }!)
    }

    private func assistants(_ fixture: Fixture) -> [Assistant] {
        AssistantRegistry.discover(paths: fixture.paths)
    }

    private func assistant(_ id: String, in fixture: Fixture) -> Assistant {
        assistants(fixture).first { $0.id == id }!
    }

    private func codexInstalled(_ fixture: Fixture) {
        try! fm.createDirectory(
            at: fixture.paths.skillsRoot(forAssistant: "codex"), withIntermediateDirectories: true
        )
    }

    /// Every entry under the fixture as `lstat` sees it, links as links, with contents and dates:
    /// anything a pass creates, removes, repoints or rewrites changes this.
    private func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as! FileAttributeType
            let modified = (attributes[.modificationDate] as! Date).timeIntervalSince1970
            var detail = "\(type.rawValue) \(modified)"
            if type == .typeSymbolicLink {
                detail += " -> " + (try fm.destinationOfSymbolicLink(atPath: url.path))
            } else if type == .typeRegular {
                detail += " " + (try Data(contentsOf: url)).base64EncodedString()
            }
            result[String(url.path.dropFirst(root.path.count))] = detail
        }
        return result
    }

    // MARK: - Listing

    func testASkillOnlyTheStoreHoldsIsListedOnceWithNoAssistant() {
        let fixture = Fixture()
        stored("from-store", in: fixture)
        codexInstalled(fixture)

        let item = onlySkill("from-store", in: fixture)

        XCTAssertTrue(item.isSharedOnly)
        XCTAssertTrue(item.enabled)
        XCTAssertEqual(item.assistants, [], "no assistant is named on its behalf")
        XCTAssertEqual(item.description, "From the store.")
        XCTAssertEqual(
            item.directory?.resolvingSymlinksInPath(),
            fixture.paths.sharedSkills.appendingPathComponent("from-store").resolvingSymlinksInPath()
        )
    }

    func testTheStoreIsListedWhenNoAssistantExistsAtAll() throws {
        let fixture = Fixture()
        try fm.removeItem(at: fixture.paths.claude)
        stored("alone", in: fixture)

        XCTAssertEqual(assistants(fixture), [])
        XCTAssertTrue(onlySkill("alone", in: fixture).isSharedOnly)
    }

    func testAStoredSkillIsInNoAssistantsFilterAndAtNoProject() {
        let fixture = Fixture()
        stored("from-store", in: fixture)
        fixture.projectRepo("APPS/app", skills: ["in-repo"])
        let project = ProjectRoots(folders: [fixture.paths.projectsRoot])
            .discover(home: fixture.paths.home).first!

        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        XCTAssertEqual(Filtering.filter(items, by: AssistantFilter.one("claude")).map(\.name), [])

        let scoped = InventoryScanner(paths: fixture.paths).scanAll(project: project).items
        XCTAssertEqual(scoped.filter { $0.kind == .skill }.map(\.name), ["in-repo"])
    }

    func testLinksIntoTheStoreAreOneRowNamingOnlyWhoReallyLinksIt() {
        let fixture = Fixture()
        let folder = stored("linked", in: fixture)
        link("linked", assistant: "claude", to: folder, in: fixture)
        codexInstalled(fixture)

        let item = onlySkill("linked", in: fixture)

        XCTAssertEqual(item.assistants, ["claude"], "Codex is installed, and does not link it")
        XCTAssertTrue(item.inSharedStore)
        XCTAssertFalse(item.isSharedOnly)
    }

    func testARelativeLinkLeadsToTheSameRow() throws {
        let fixture = Fixture()
        stored("relative", in: fixture)
        let root = fixture.paths.skillsRoot(forAssistant: "claude")
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent("relative").path,
            withDestinationPath: "../../.agents/skills/relative"
        )

        XCTAssertEqual(onlySkill("relative", in: fixture).assistants, ["claude"])
    }

    /// `skillFolders` does not list a root that is itself a link, so Codex gets no mark here. What
    /// matters to this suite is that the skill is not listed twice.
    func testAnAssistantWhoseWholeFolderIsALinkToTheStoreDoesNotDuplicateTheRow() throws {
        let fixture = Fixture()
        stored("through-folder", in: fixture)
        let root = fixture.paths.skillsRoot(forAssistant: "codex")
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root, withDestinationURL: fixture.paths.sharedSkills)

        let item = onlySkill("through-folder", in: fixture)
        XCTAssertTrue(item.inSharedStore)
        XCTAssertEqual(item.assistants, [])
    }

    func testAStoreEntryThatIsItselfALinkMatchesAnAssistantLinkingTheSameFolder() throws {
        let fixture = Fixture()
        let library = write("borrowed", description: "From a library.", into: fixture.root.appendingPathComponent("library"))
        try fm.createDirectory(at: fixture.paths.sharedSkills, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: fixture.paths.sharedSkills.appendingPathComponent("borrowed"), withDestinationURL: library
        )
        link("borrowed", assistant: "claude", to: library, in: fixture)

        let item = onlySkill("borrowed", in: fixture)
        XCTAssertEqual(item.assistants, ["claude"])
        XCTAssertTrue(item.inSharedStore)
    }

    // MARK: - One name, two skills

    func testAPrivateCopyWithTheStoresNameIsItsOwnRow() {
        let fixture = Fixture()
        stored("same-name", description: "The store's.", in: fixture)
        own("same-name", description: "Claude's own.", assistant: "claude", in: fixture)

        let rows = pair("same-name", in: fixture)

        XCTAssertEqual(skills("same-name", in: fixture).count, 2)
        XCTAssertNotEqual(rows.shared.id, rows.own.id, "two ids, or the list draws a blank row")
        XCTAssertEqual(rows.shared.description, "The store's.")
        XCTAssertEqual(rows.shared.assistants, [])
        XCTAssertEqual(rows.own.description, "Claude's own.")
        XCTAssertEqual(rows.own.assistants, ["claude"])
        XCTAssertEqual(rows.own.id, "skill:personal:same-name", "the one creating a skill selects")
    }

    /// An id passing to the other row carries the selection, and an unsaved draft, across with it.
    func testNeitherRowTakesTheOthersIdWhenOneComesOrGoes() throws {
        let fixture = Fixture()
        stored("same-name", in: fixture)
        let alone = onlySkill("same-name", in: fixture).id
        let ownFolder = own("same-name", assistant: "claude", in: fixture)
        let rows = pair("same-name", in: fixture)
        XCTAssertEqual(rows.shared.id, alone, "a private copy arriving leaves the store's id alone")

        try Mutations(paths: fixture.paths).disableSkill(rows.own, assistants: assistants(fixture))
        XCTAssertEqual(pair("same-name", in: fixture).shared.id, alone)
        XCTAssertNotEqual(alone, rows.own.id)
        try fm.removeItem(at: fixture.paths.skillsOff.appendingPathComponent("same-name"))
        XCTAssertFalse(fixture.exists(ownFolder))
        XCTAssertEqual(onlySkill("same-name", in: fixture).id, alone, "nor does it going")
    }

    func testAStoredSkillKeepsItsIdAcrossOffAndOn() throws {
        let fixture = Fixture()
        stored("from-store", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let id = onlySkill("from-store", in: fixture).id

        try mutations.disableSkill(onlySkill("from-store", in: fixture), assistants: assistants(fixture))
        XCTAssertEqual(onlySkill("from-store", in: fixture).id, id, "so the selection survives the switch")
        try mutations.enableSkill(onlySkill("from-store", in: fixture), assistants: assistants(fixture))
        XCTAssertEqual(onlySkill("from-store", in: fixture).id, id)
    }

    func testIdenticalContentAtTwoPathsIsStillTwoSkills() {
        let fixture = Fixture()
        stored("twin", description: "Same words.", in: fixture)
        own("twin", description: "Same words.", assistant: "claude", in: fixture)

        XCTAssertEqual(skills("twin", in: fixture).count, 2, "identity is the folder, not its text")
    }

    func testAnAssistantLinkingTheStoreAndAnotherWithAPrivateCopyAreTwoRows() {
        let fixture = Fixture()
        let folder = stored("split", in: fixture)
        link("split", assistant: "codex", to: folder, in: fixture)
        own("split", assistant: "claude", in: fixture)

        let rows = pair("split", in: fixture)

        XCTAssertEqual(rows.shared.assistants, ["codex"])
        XCTAssertEqual(rows.own.assistants, ["claude"])
    }

    func testEachRowOfOneNameReadsAndEditsItsOwnFile() throws {
        let fixture = Fixture()
        let storedFolder = stored("same-name", in: fixture)
        let ownFolder = own("same-name", assistant: "claude", in: fixture)
        let rows = pair("same-name", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.save(rows.own, contents: "---\nname: same-name\ndescription: Edited.\n---\n\nNew.")

        XCTAssertTrue(fixture.read(ownFolder.appendingPathComponent("SKILL.md")).contains("Edited."))
        XCTAssertFalse(fixture.read(storedFolder.appendingPathComponent("SKILL.md")).contains("Edited."))
    }

    // MARK: - Switching off, with two of a name

    func testSwitchingOffThePrivateCopyLeavesTheStoreAndItsLinksAlone() throws {
        let fixture = Fixture()
        let folder = stored("split", in: fixture)
        link("split", assistant: "codex", to: folder, in: fixture)
        let ownFolder = own("split", assistant: "claude", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(pair("split", in: fixture).own, assistants: assistants(fixture))

        XCTAssertFalse(fixture.exists(ownFolder))
        XCTAssertTrue(fixture.exists(fixture.paths.skillsOff.appendingPathComponent("split/SKILL.md")))
        XCTAssertTrue(fixture.exists(folder.appendingPathComponent("SKILL.md")), "the store's copy stays")
        XCTAssertTrue(mutations.isSymlink(
            fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("split")
        ), "and Codex goes on loading it")
        XCTAssertEqual(mutations.records.entry(named: "split")?.assistants, ["claude"])
    }

    func testSwitchingOffALinkedStoreSkillLeavesAPrivateCopyAlone() throws {
        let fixture = Fixture()
        let folder = stored("split", in: fixture)
        link("split", assistant: "codex", to: folder, in: fixture)
        let ownFolder = own("split", assistant: "claude", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(pair("split", in: fixture).shared, assistants: assistants(fixture))

        XCTAssertTrue(fixture.exists(storeOff(fixture).appendingPathComponent("split/SKILL.md")))
        XCTAssertTrue(fixture.exists(ownFolder.appendingPathComponent("SKILL.md")))
        XCTAssertEqual(mutations.records.entry(named: "split")?.assistants, ["codex"])
    }

    func testTwoSkillsOfOneNameParkedAtOnceKeepSeparateRecords() throws {
        let fixture = Fixture()
        let folder = stored("split", in: fixture)
        link("split", assistant: "codex", to: folder, in: fixture)
        own("split", assistant: "claude", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(pair("split", in: fixture).own, assistants: assistants(fixture))
        try mutations.disableSkill(pair("split", in: fixture).shared, assistants: assistants(fixture))

        let rows = pair("split", in: fixture)
        XCTAssertFalse(rows.shared.enabled)
        XCTAssertFalse(rows.own.enabled)
        XCTAssertNotEqual(rows.shared.id, rows.own.id)
        XCTAssertEqual(mutations.restoreProposal(for: rows.own, assistants: assistants(fixture)).assistants, ["claude"])
        XCTAssertEqual(mutations.restoreProposal(for: rows.shared, assistants: assistants(fixture)).assistants, ["codex"])

        try mutations.enableSkill(rows.own, into: [assistant("claude", in: fixture)], assistants: assistants(fixture))

        XCTAssertNil(mutations.records.entry(named: "split", owner: "claude"))
        XCTAssertEqual(
            mutations.records.entry(named: "split", owner: OffRecords.sharedOwner)?.assistants, ["codex"],
            "bringing one back says nothing about the other"
        )
    }

    // MARK: - Parked

    func testAParkedStoreSkillIsOneOffRowWithNoAssistant() {
        let fixture = Fixture()
        parkedInStore("resting", in: fixture)
        codexInstalled(fixture)

        let item = onlySkill("resting", in: fixture)

        XCTAssertFalse(item.enabled)
        XCTAssertTrue(item.inSharedStore)
        XCTAssertEqual(item.assistants, [])
        XCTAssertEqual(Filtering.filter([item], by: ItemFilter.disabled).count, 1)
    }

    func testAPrivateCopyParkedWhileTheStoreHoldsTheNameLiveStaysDistinct() {
        let fixture = Fixture()
        stored("back-and-forth", in: fixture)
        write("back-and-forth", description: "Parked private.", into: fixture.paths.skillsOff)

        let rows = pair("back-and-forth", in: fixture)

        XCTAssertTrue(rows.shared.enabled)
        XCTAssertFalse(rows.own.enabled)
        XCTAssertNotEqual(rows.shared.id, rows.own.id)
    }

    func testALinkParkedInAnAssistantGivesWayToTheRealFolderItLeadsTo() throws {
        let fixture = Fixture()
        let parked = parkedInStore("resting", in: fixture)
        try fm.createDirectory(at: fixture.paths.skillsOff, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: fixture.paths.skillsOff.appendingPathComponent("resting"), withDestinationURL: parked
        )

        XCTAssertTrue(onlySkill("resting", in: fixture).inSharedStore)
    }

    func testALinkParkedInAnAssistantLeadingToALiveStoreSkillIsNotAnOffRow() throws {
        let fixture = Fixture()
        let live = stored("awake", in: fixture)
        try fm.createDirectory(at: fixture.paths.skillsOff, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: fixture.paths.skillsOff.appendingPathComponent("awake"), withDestinationURL: live
        )

        XCTAssertTrue(onlySkill("awake", in: fixture).enabled)
    }

    // MARK: - Switching a stored skill off and on

    /// Every entry under the skill roots, by name and link target, without dates or backups: what
    /// a round trip has to leave exactly as it found it.
    private func layout(_ fixture: Fixture) throws -> [String: String] {
        try snapshot(fixture.root)
            .filter { $0.key.contains("/.agents/") || $0.key.contains("/.claude/skills") || $0.key.contains("/.codex/") }
            .mapValues { detail in
                let parts = detail.split(separator: " ", maxSplits: 2).map(String.init)
                return [parts[0], parts.count > 2 ? parts[2] : ""].joined(separator: " ")
            }
            .filter { !$0.key.hasSuffix("/skills-off") }
    }

    func testASharedOnlySkillRoundTripsWithoutLinksAndWithItsContent() throws {
        let fixture = Fixture()
        let folder = stored("from-store", in: fixture)
        try "echo hi".write(to: folder.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        codexInstalled(fixture)
        let mutations = Mutations(paths: fixture.paths)
        let before = try layout(fixture)

        try mutations.disableSkill(onlySkill("from-store", in: fixture), assistants: assistants(fixture))

        let parked = storeOff(fixture).appendingPathComponent("from-store")
        XCTAssertFalse(fixture.exists(folder))
        XCTAssertEqual(fixture.read(parked.appendingPathComponent("run.sh")), "echo hi")
        let record = mutations.records.entry(named: "from-store")
        XCTAssertEqual(record?.owner, OffRecords.sharedOwner)
        XCTAssertEqual(record?.assistants, [])
        let off = onlySkill("from-store", in: fixture)
        XCTAssertFalse(off.enabled)
        XCTAssertTrue(off.inSharedStore)
        XCTAssertEqual(mutations.restoreProposal(for: off, assistants: assistants(fixture)).assistants, [], "nothing to ask")

        try mutations.enableSkill(off, assistants: assistants(fixture))

        XCTAssertEqual(try layout(fixture), before, "where it was, and no link anywhere")
        XCTAssertNil(mutations.records.entry(named: "from-store"))
        XCTAssertTrue(onlySkill("from-store", in: fixture).isSharedOnly)
        XCTAssertFalse(fixture.exists(fixture.paths.skills.appendingPathComponent("from-store")), "not moved to Claude as a last resort")
    }

    func testASkillLinkedFromOneAssistantComesBackInTheStoreWithThatLink() throws {
        let fixture = Fixture()
        let folder = stored("one-link", in: fixture)
        link("one-link", assistant: "claude", to: folder, in: fixture)
        codexInstalled(fixture)
        let mutations = Mutations(paths: fixture.paths)
        let before = try layout(fixture)

        try mutations.disableSkill(onlySkill("one-link", in: fixture), assistants: assistants(fixture))

        let claudeEntry = fixture.paths.skills.appendingPathComponent("one-link")
        XCTAssertFalse(mutations.isSymlink(claudeEntry))
        let off = onlySkill("one-link", in: fixture)
        let proposal = mutations.restoreProposal(for: off, assistants: assistants(fixture))
        XCTAssertEqual(proposal.assistants, ["claude"])
        XCTAssertTrue(proposal.remembered)

        try mutations.enableSkill(
            off, into: assistants(fixture).filter { proposal.assistants.contains($0.id) }, assistants: assistants(fixture)
        )

        XCTAssertEqual(try layout(fixture), before, "the store's folder and the same link")
        XCTAssertTrue(mutations.isSymlink(claudeEntry), "not a private copy inside the assistant")
        XCTAssertFalse(mutations.isSymlink(folder))
        let back = onlySkill("one-link", in: fixture)
        XCTAssertEqual(back.assistants, ["claude"])
        XCTAssertTrue(back.inSharedStore)
    }

    func testASkillLinkedFromSeveralAssistantsRoundTripsTheSameWay() throws {
        let fixture = Fixture()
        let folder = stored("two-links", in: fixture)
        link("two-links", assistant: "claude", to: folder, in: fixture)
        link("two-links", assistant: "codex", to: folder, in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let before = try layout(fixture)

        try mutations.disableSkill(onlySkill("two-links", in: fixture), assistants: assistants(fixture))
        let off = onlySkill("two-links", in: fixture)
        let proposal = mutations.restoreProposal(for: off, assistants: assistants(fixture))
        XCTAssertEqual(proposal.assistants.sorted(), ["claude", "codex"])
        try mutations.enableSkill(
            off, into: assistants(fixture).filter { proposal.assistants.contains($0.id) }, assistants: assistants(fixture)
        )

        XCTAssertEqual(try layout(fixture), before)
        XCTAssertEqual(onlySkill("two-links", in: fixture).assistants, ["claude", "codex"])
    }

    func testAPrivateSkillStillGoesStraightIntoItsOneAssistant() throws {
        let fixture = Fixture()
        let folder = own("private-one", assistant: "codex", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(onlySkill("private-one", in: fixture), assistants: assistants(fixture))
        try mutations.enableSkill(
            onlySkill("private-one", in: fixture), into: [assistant("codex", in: fixture)], assistants: assistants(fixture)
        )

        XCTAssertFalse(mutations.isSymlink(folder), "this one was never the store's")
        XCTAssertFalse(fixture.exists(fixture.paths.sharedSkills.appendingPathComponent("private-one")))
    }

    // MARK: - Assistants hidden in Settings

    /// The sheet only lists what Settings shows, so a hidden assistant left in the proposal stayed
    /// ticked where nobody could untick it, and got a link on confirm.
    func testAHiddenAssistantIsNotProposedAlongsideAVisibleOne() throws {
        let fixture = Fixture()
        let folder = stored("two-links", in: fixture)
        link("two-links", assistant: "claude", to: folder, in: fixture)
        link("two-links", assistant: "codex", to: folder, in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(onlySkill("two-links", in: fixture), assistants: assistants(fixture))
        let off = onlySkill("two-links", in: fixture)

        let proposal = mutations.restoreProposal(for: off, assistants: assistants(fixture), hidden: ["codex"])
        XCTAssertEqual(proposal.assistants, ["claude"])
        XCTAssertTrue(proposal.remembered)
        XCTAssertEqual(
            mutations.restoreProposal(for: off, assistants: assistants(fixture)).assistants.sorted(),
            ["claude", "codex"], "the record itself still says what it said"
        )

        try mutations.enableSkill(
            off, into: assistants(fixture).filter { proposal.assistants.contains($0.id) },
            assistants: assistants(fixture), hidden: ["codex"]
        )

        XCTAssertEqual(onlySkill("two-links", in: fixture).assistants, ["claude"])
        XCTAssertFalse(fixture.exists(
            fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("two-links")
        ))
    }

    func testASkillLinkedOnlyFromAHiddenAssistantGoesHomeUnlinked() throws {
        let fixture = Fixture()
        let folder = stored("hidden-link", in: fixture)
        link("hidden-link", assistant: "codex", to: folder, in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(onlySkill("hidden-link", in: fixture), assistants: assistants(fixture))
        let off = onlySkill("hidden-link", in: fixture)

        XCTAssertEqual(
            mutations.restoreProposal(for: off, assistants: assistants(fixture), hidden: ["codex"]).assistants, []
        )
        try mutations.enableSkill(off, assistants: assistants(fixture), hidden: ["codex"])

        XCTAssertTrue(onlySkill("hidden-link", in: fixture).isSharedOnly)
        XCTAssertFalse(mutations.isSymlink(folder))
        XCTAssertNil(mutations.records.entry(named: "hidden-link"))
    }

    func testAPrivateSkillParkedWithAHiddenAssistantIsNotProposedToIt() throws {
        let fixture = Fixture()
        own("private-hidden", assistant: "codex", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(onlySkill("private-hidden", in: fixture), assistants: assistants(fixture))
        let off = onlySkill("private-hidden", in: fixture)

        XCTAssertEqual(
            mutations.restoreProposal(for: off, assistants: assistants(fixture), hidden: ["codex"]).assistants, []
        )
        try mutations.records.forget("private-hidden")
        XCTAssertEqual(
            mutations.restoreProposal(for: off, assistants: assistants(fixture), hidden: ["codex"]).assistants, [],
            "nor from where it is parked, with the record gone"
        )
    }

    // MARK: - Records written by earlier versions

    /// Exactly what `main` writes, by hand, so a change to the encoder can't hide a broken read.
    private func writeRecords(_ entries: String, in fixture: Fixture) throws {
        try fm.createDirectory(at: fixture.paths.support, withIntermediateDirectories: true)
        try """
        {
          "entries" : [\(entries)],
          "version" : 1
        }
        """.write(
            to: fixture.paths.support.appendingPathComponent("skills-off.json"), atomically: true, encoding: .utf8
        )
    }

    private func oldEntry(_ name: String, owner: String, assistants: [String]) -> String {
        let ids = assistants.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        { "assistants" : [\(ids)], "disabledAt" : "2026-10-01T10:00:00Z", "name" : "\(name)", "owner" : "\(owner)" }
        """
    }

    func testAnOldSharedRecordWithOneAssistantRestoresToTheStoreWithThatLink() throws {
        let fixture = Fixture()
        parkedInStore("old-one", in: fixture)
        codexInstalled(fixture)
        try writeRecords(oldEntry("old-one", owner: "shared", assistants: ["codex"]), in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let off = onlySkill("old-one", in: fixture)

        let proposal = mutations.restoreProposal(for: off, assistants: assistants(fixture))
        XCTAssertEqual(proposal.assistants, ["codex"])
        XCTAssertTrue(proposal.remembered)
        try mutations.enableSkill(off, into: [assistant("codex", in: fixture)], assistants: assistants(fixture))

        XCTAssertTrue(fixture.exists(fixture.paths.sharedSkills.appendingPathComponent("old-one/SKILL.md")))
        XCTAssertTrue(mutations.isSymlink(
            fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("old-one")
        ))
        XCTAssertNil(mutations.records.entry(named: "old-one"))
    }

    func testAnOldSharedRecordWithNoAssistantRestoresToTheStoreAlone() throws {
        let fixture = Fixture()
        parkedInStore("old-none", in: fixture)
        try writeRecords(oldEntry("old-none", owner: "shared", assistants: []), in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.enableSkill(onlySkill("old-none", in: fixture), assistants: assistants(fixture))

        XCTAssertTrue(onlySkill("old-none", in: fixture).isSharedOnly)
    }

    func testAnOldRecordNamingAnAssistantThatHasGoneRestoresToTheStoreAlone() throws {
        let fixture = Fixture()
        parkedInStore("old-gone", in: fixture)
        try writeRecords(oldEntry("old-gone", owner: "shared", assistants: ["no-such-assistant"]), in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let off = onlySkill("old-gone", in: fixture)

        XCTAssertEqual(mutations.restoreProposal(for: off, assistants: assistants(fixture)).assistants, [])
        try mutations.enableSkill(off, assistants: assistants(fixture))

        XCTAssertTrue(onlySkill("old-gone", in: fixture).isSharedOnly)
    }

    func testAnOldPrivateRecordBehavesAsItAlwaysDid() throws {
        let fixture = Fixture()
        write("old-private", description: "Parked private.", into: fixture.paths.skillsOff)
        try writeRecords(oldEntry("old-private", owner: "claude", assistants: ["claude"]), in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let off = onlySkill("old-private", in: fixture)

        XCTAssertEqual(mutations.restoreProposal(for: off, assistants: assistants(fixture)).assistants, ["claude"])
        try mutations.enableSkill(off, into: [assistant("claude", in: fixture)], assistants: assistants(fixture))

        XCTAssertFalse(mutations.isSymlink(fixture.paths.skills.appendingPathComponent("old-private")))
        XCTAssertFalse(fixture.exists(fixture.paths.sharedSkills.appendingPathComponent("old-private")))
    }

    func testAParkedStoreSkillWithNoReadableRecordStillGoesHomeUnlinked() throws {
        let fixture = Fixture()
        parkedInStore("no-record", in: fixture)
        try fm.createDirectory(at: fixture.paths.support, withIntermediateDirectories: true)
        try "not json".write(
            to: fixture.paths.support.appendingPathComponent("skills-off.json"), atomically: true, encoding: .utf8
        )
        let mutations = Mutations(paths: fixture.paths)

        try mutations.enableSkill(onlySkill("no-record", in: fixture), assistants: assistants(fixture))

        XCTAssertTrue(onlySkill("no-record", in: fixture).isSharedOnly)
    }

    // MARK: - Acting on the right folder

    func testAStoreEntryThatIsALinkRefusesToSwitchOffAndLeavesAPrivateCopyAlone() throws {
        let fixture = Fixture()
        let library = write("borrowed", description: "From a library.", into: fixture.root.appendingPathComponent("library"))
        try fm.createDirectory(at: fixture.paths.sharedSkills, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: fixture.paths.sharedSkills.appendingPathComponent("borrowed"), withDestinationURL: library
        )
        own("borrowed", description: "Private.", assistant: "claude", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let before = try snapshot(fixture.root)

        XCTAssertThrowsError(
            try mutations.disableSkill(pair("borrowed", in: fixture).shared, assistants: assistants(fixture))
        )

        XCTAssertEqual(try snapshot(fixture.root), before, "Claude's copy was not parked in its place")
    }

    func testSwitchingOffActsOnTheFolderWhenTheFrontmatterNamesAnother() throws {
        let fixture = Fixture()
        let misnamed = fixture.paths.sharedSkills.appendingPathComponent("folder-a")
        try fm.createDirectory(at: misnamed, withIntermediateDirectories: true)
        try "---\nname: folder-b\ndescription: Misnamed.\n---\n\nBody.".write(
            to: misnamed.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let other = stored("folder-b", description: "The real b.", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let row = skills("folder-b", in: fixture).first { $0.description == "Misnamed." }!

        try mutations.disableSkill(row, assistants: assistants(fixture))

        XCTAssertTrue(fixture.exists(storeOff(fixture).appendingPathComponent("folder-a/SKILL.md")))
        XCTAssertTrue(fixture.exists(other.appendingPathComponent("SKILL.md")), "the other skill did not move")
    }

    func testLinkingIsRefusedOverALiveLinkToADifferentSkill() throws {
        let fixture = Fixture()
        let folder = stored("same-name", in: fixture)
        link("same-name", assistant: "claude", to: folder, in: fixture)
        let library = write("same-name", description: "From a library.", into: fixture.root.appendingPathComponent("library"))
        link("same-name", assistant: "codex", to: library, in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let before = try snapshot(fixture.root)

        assertAlreadyExists(
            { try mutations.share(pair("same-name", in: fixture).shared, with: assistant("codex", in: fixture)) },
            fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("same-name")
        )

        XCTAssertEqual(try snapshot(fixture.root), before, "Codex still loads the library's")
    }

    func testAFailedMoveStillLeavesTheRecordOfWhereItBelongs() throws {
        let fixture = Fixture()
        let folder = stored("guarded", in: fixture)
        link("guarded", assistant: "claude", to: folder, in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let item = onlySkill("guarded", in: fixture)
        // A plain file where `skills-off` should be: the move cannot create its folder.
        try "in the way".write(to: storeOff(fixture), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try mutations.disableSkill(item, assistants: assistants(fixture)))

        XCTAssertTrue(fixture.exists(folder.appendingPathComponent("SKILL.md")))
        XCTAssertEqual(mutations.records.entry(named: "guarded", owner: OffRecords.sharedOwner)?.assistants, ["claude"])
    }

    // MARK: - Collisions

    private func assertAlreadyExists(_ body: () throws -> Void, _ path: URL, line: UInt = #line) {
        XCTAssertThrowsError(try body(), line: line) { error in
            guard case LoadoutError.alreadyExists(let named)? = error as? LoadoutError else {
                return XCTFail("wrong error: \(error)", line: line)
            }
            XCTAssertEqual(named.resolvingSymlinksInPath().path, path.resolvingSymlinksInPath().path, line: line)
        }
    }

    func testSwitchingOffIsRefusedWhenSkillsOffHoldsTheNameAndKeepsTheLinks() throws {
        let fixture = Fixture()
        let folder = stored("crowded", description: "Live.", in: fixture)
        link("crowded", assistant: "claude", to: folder, in: fixture)
        let live = skills("crowded", in: fixture).first { $0.enabled }!
        parkedInStore("crowded", description: "Older.", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let before = try snapshot(fixture.root)

        assertAlreadyExists(
            { try mutations.disableSkill(live, assistants: assistants(fixture)) },
            storeOff(fixture).appendingPathComponent("crowded")
        )

        XCTAssertEqual(try snapshot(fixture.root), before, "nothing moved, and the link is still there")
    }

    func testSwitchingOnIsRefusedWhenTheStoreHoldsTheName() throws {
        let fixture = Fixture()
        parkedInStore("crowded", description: "Parked.", in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let off = onlySkill("crowded", in: fixture)
        let destination = stored("crowded", description: "Arrived meanwhile.", in: fixture)
        let before = try snapshot(fixture.root)

        assertAlreadyExists({ try mutations.enableSkill(off, assistants: assistants(fixture)) }, destination)

        XCTAssertEqual(try snapshot(fixture.root), before, "neither folder changed")
    }

    func testSwitchingOnIsRefusedWhenAnAssistantHoldsTheNameAndKeepsTheRecord() throws {
        let fixture = Fixture()
        let folder = stored("crowded", in: fixture)
        link("crowded", assistant: "claude", to: folder, in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        try mutations.disableSkill(onlySkill("crowded", in: fixture), assistants: assistants(fixture))
        let off = onlySkill("crowded", in: fixture)
        let inTheWay = own("crowded", description: "Arrived meanwhile.", assistant: "claude", in: fixture)
        let before = try snapshot(fixture.root)

        assertAlreadyExists(
            { try mutations.enableSkill(off, into: [assistant("claude", in: fixture)], assistants: assistants(fixture)) },
            inTheWay
        )

        XCTAssertEqual(try snapshot(fixture.root), before)
        XCTAssertEqual(mutations.records.entry(named: "crowded")?.assistants, ["claude"], "still known where it belongs")
    }

    func testSwitchingOnIsRefusedOverALinkPointingAtNothing() throws {
        let fixture = Fixture()
        parkedInStore("crowded", in: fixture)
        codexInstalled(fixture)
        link("crowded", assistant: "codex", to: fixture.root.appendingPathComponent("gone"), in: fixture)
        let mutations = Mutations(paths: fixture.paths)
        let off = onlySkill("crowded", in: fixture)

        assertAlreadyExists(
            { try mutations.enableSkill(off, into: [assistant("codex", in: fixture)], assistants: assistants(fixture)) },
            fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("crowded")
        )
        XCTAssertTrue(fixture.exists(storeOff(fixture).appendingPathComponent("crowded/SKILL.md")))
    }

    func testSwitchingOffAndOnBothTakeABackup() throws {
        let fixture = Fixture()
        stored("backed-up", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.disableSkill(onlySkill("backed-up", in: fixture), assistants: assistants(fixture))
        try mutations.enableSkill(onlySkill("backed-up", in: fixture), assistants: assistants(fixture))

        let copies = fm.enumerator(at: fixture.paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.path }.filter { $0.hasSuffix("backed-up/SKILL.md") } ?? []
        XCTAssertEqual(copies.count, 2)
    }

    // MARK: - Scanning writes nothing

    func testScanningChangesNothingOnDisk() throws {
        let fixture = Fixture()
        let folder = stored("linked", in: fixture)
        link("linked", assistant: "claude", to: folder, in: fixture)
        stored("alone", in: fixture)
        stored("same-name", in: fixture)
        own("same-name", assistant: "claude", in: fixture)
        parkedInStore("resting", in: fixture)
        codexInstalled(fixture)
        fixture.skill("private-one")
        let before = try snapshot(fixture.root)
        XCTAssertFalse(before.isEmpty)

        let scanner = InventoryScanner(paths: fixture.paths)
        _ = scanner.scanAll()
        _ = scanner.scanEverything(projects: [])

        XCTAssertEqual(try snapshot(fixture.root), before)
        XCTAssertFalse(fixture.exists(
            fixture.paths.skillsRoot(forAssistant: "claude").appendingPathComponent("alone")
        ), "a stored skill does not get linked by being seen")
    }

    // MARK: - Existing flows on a stored skill

    func testEditingAStoredSkillSavesInTheStoreWithABackupAndLinksNothing() throws {
        let fixture = Fixture()
        let folder = stored("from-store", in: fixture)
        codexInstalled(fixture)
        let mutations = Mutations(paths: fixture.paths)
        let item = onlySkill("from-store", in: fixture)
        XCTAssertTrue(item.isEditable)

        try mutations.save(item, contents: "---\nname: from-store\ndescription: Edited.\n---\n\nNew.")

        XCTAssertTrue(fixture.read(folder.appendingPathComponent("SKILL.md")).contains("Edited."))
        let backups = fm.enumerator(at: fixture.paths.backups, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertTrue(backups.contains("SKILL.md"))
        let after = onlySkill("from-store", in: fixture)
        XCTAssertEqual(after.description, "Edited.")
        XCTAssertEqual(after.assistants, [], "editing assigns it to nobody")
    }

    func testLinkingToAnAssistantHappensOnlyWhenAskedAndLeavesTheFolderInTheStore() throws {
        let fixture = Fixture()
        let folder = stored("from-store", in: fixture)
        codexInstalled(fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.share(onlySkill("from-store", in: fixture), with: assistant("codex", in: fixture))

        XCTAssertEqual(onlySkill("from-store", in: fixture).assistants, ["codex"])
        XCTAssertFalse(mutations.isSymlink(folder), "the real folder did not move")
        XCTAssertTrue(mutations.isSymlink(
            fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent("from-store")
        ))
    }

    func testTheLastLinkToAStoredSkillCanBeRemovedAndTheSkillStaysListed() throws {
        let fixture = Fixture()
        let folder = stored("from-store", in: fixture)
        link("from-store", assistant: "claude", to: folder, in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        try mutations.unshare(onlySkill("from-store", in: fixture), from: assistant("claude", in: fixture))

        XCTAssertTrue(fixture.exists(folder.appendingPathComponent("SKILL.md")))
        XCTAssertTrue(onlySkill("from-store", in: fixture).isSharedOnly)
    }

    func testSharingAPrivateCopyIsRefusedWhileTheStoreHoldsADifferentSkillOfThatName() throws {
        let fixture = Fixture()
        stored("same-name", description: "The store's.", in: fixture)
        let ownFolder = own("same-name", assistant: "claude", in: fixture)
        codexInstalled(fixture)
        let mutations = Mutations(paths: fixture.paths)
        let before = try snapshot(fixture.root)

        XCTAssertThrowsError(
            try mutations.share(pair("same-name", in: fixture).own, with: assistant("codex", in: fixture))
        ) { error in
            guard case LoadoutError.alreadyExists = error as! LoadoutError else {
                return XCTFail("wrong error: \(error)")
            }
        }

        XCTAssertEqual(try snapshot(fixture.root), before, "Codex was not handed the other skill")
        XCTAssertFalse(mutations.isSymlink(ownFolder))
    }

    func testLinkingTheStoresCopyOverAPrivateCopyIsRefused() throws {
        let fixture = Fixture()
        stored("same-name", in: fixture)
        let ownFolder = own("same-name", assistant: "claude", in: fixture)
        let mutations = Mutations(paths: fixture.paths)

        XCTAssertThrowsError(
            try mutations.share(pair("same-name", in: fixture).shared, with: assistant("claude", in: fixture))
        )
        XCTAssertFalse(mutations.isSymlink(ownFolder), "the private copy is still there, untouched")
    }
}
