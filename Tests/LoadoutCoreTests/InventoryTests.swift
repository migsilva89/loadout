import XCTest
@testable import LoadoutCore

/// AC1 — the inventory, and AC2.4 — search.
final class InventoryTests: XCTestCase {

    // MARK: AC1.1

    func testFindsPersonalSkillsAndReadsFrontmatter() {
        let fixture = Fixture()
        fixture.skill("imark-review", description: "Abrir markdown no Imark.")
        fixture.skill("flow-map", description: "Mapa de fluxo.")

        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        let skills = items.filter { $0.kind == .skill }

        XCTAssertEqual(skills.count, 2)
        XCTAssertEqual(skills.map(\.name).sorted(), ["flow-map", "imark-review"])
        XCTAssertEqual(
            skills.first { $0.name == "imark-review" }?.description,
            "Abrir markdown no Imark."
        )
        XCTAssertTrue(skills.allSatisfy { $0.origin == .personal && $0.enabled })
    }

    func testIgnoresFoldersWithoutSkillFile() {
        let fixture = Fixture()
        fixture.skill("real-one")
        try! FileManager.default.createDirectory(
            at: fixture.paths.skills.appendingPathComponent("just-a-folder"),
            withIntermediateDirectories: true
        )

        let skills = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }
        XCTAssertEqual(skills.map(\.name), ["real-one"])
    }

    /// Six of the real skills are symlinks into a shared `.agents/skills` tree, and an
    /// `isDirectory` check that does not follow links loses every one of them.
    func testSymlinkedSkillsAreInventoried() throws {
        let fixture = Fixture()
        fixture.skill("normal")
        let elsewhere = fixture.root.appendingPathComponent("outra-arvore/emprestada")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "---\nname: emprestada\ndescription: Comes from elsewhere.\n---\n\nBody.".write(
            to: elsewhere.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.skills.appendingPathComponent("emprestada"), withDestinationURL: elsewhere
        )

        let skills = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }

        XCTAssertEqual(skills.map(\.name).sorted(), ["emprestada", "normal"])
        XCTAssertEqual(skills.first { $0.name == "emprestada" }?.description, "Comes from elsewhere.")
    }

    /// Real skills write `description: >` with the text folded underneath; showing the
    /// marker instead of the text made the whole list unreadable.
    func testBlockScalarDescriptionsAreFolded() {
        let fixture = Fixture()
        fixture.rawSkill("caveman", contents: """
        ---
        name: caveman
        description: >
          Ultra-compressed communication mode. Cuts token usage
          by speaking like caveman.
        ---

        Body.
        """)

        let item = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .skill }

        XCTAssertEqual(
            item?.description,
            "Ultra-compressed communication mode. Cuts token usage by speaking like caveman."
        )
    }

    func testPipeBlockScalarsFoldToo() {
        let fixture = Fixture()
        fixture.rawSkill("bloco", contents: "---\nname: bloco\ndescription: |-\n  Primeira linha.\n  Segunda.\n---\n\nX.")

        let item = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .skill }
        XCTAssertEqual(item?.description, "Primeira linha. Segunda.")
    }

    // MARK: AC1.2

    func testBrokenFrontmatterStillProducesAnItemWithAWarning() {
        let fixture = Fixture()
        fixture.rawSkill("no-frontmatter", contents: "# Just markdown\n\nNo yaml at all.")

        let item = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .skill }
        XCTAssertEqual(item?.name, "no-frontmatter", "it falls back to the folder's name")
        XCTAssertNotNil(item?.warning)
    }

    func testUnclosedFrontmatterIsReportedNotSwallowed() {
        let fixture = Fixture()
        fixture.rawSkill("aberto", contents: "---\nname: aberto\ndescription: x\n\nNo closing fence.")

        let item = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .skill }
        XCTAssertEqual(item?.warning, "The frontmatter opens but never closes with ---.")
    }

    func testMismatchBetweenFolderAndDeclaredNameIsFlagged() {
        let fixture = Fixture()
        fixture.rawSkill("pasta-a", contents: "---\nname: outro-nome\ndescription: x\n---\n\nBody.")

        let item = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .skill }
        XCTAssertNotNil(item?.warning)
        XCTAssertTrue(item?.warning?.contains("doesn't match") == true)
    }

    // MARK: AC1.3

    func testDisabledSkillsAreListedAsDisabled() {
        let fixture = Fixture()
        fixture.skill("ativa")
        fixture.skill("parada", disabled: true)

        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        XCTAssertEqual(items.first { $0.name == "parada" }?.enabled, false)
        XCTAssertEqual(items.first { $0.name == "ativa" }?.enabled, true)
    }

    /// A skill can be readable in both places at once: disabling copies the folder into
    /// `skills-off`, and a re-enable that leaves the copy behind makes the same skill turn up
    /// twice. Both readings carry the same id, so the list held two rows with one identity —
    /// which the list draws as one row followed by an empty slot the size of the other, and
    /// counts as two skills.
    func testSkillPresentInBothPlacesIsListedOnceAsEnabled() {
        let fixture = Fixture()
        fixture.skill("alone")
        fixture.skill("in-both")
        fixture.skill("in-both", disabled: true)
        fixture.skill("parked", disabled: true)

        let skills = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }

        XCTAssertEqual(skills.map(\.id).count, Set(skills.map(\.id)).count, "the list holds one row per skill")
        XCTAssertEqual(skills.map(\.name).sorted(), ["alone", "in-both", "parked"])

        // The live folder is what decides whether anything loads it, so that is the reading kept:
        // enabled, and pointing at the file the detail pane opens and the switch acts on.
        let both = skills.first { $0.name == "in-both" }
        XCTAssertEqual(both?.enabled, true)
        XCTAssertEqual(
            both?.directory?.resolvingSymlinksInPath(),
            fixture.paths.skills.appendingPathComponent("in-both").resolvingSymlinksInPath()
        )
        XCTAssertEqual(skills.first { $0.name == "parked" }?.enabled, false)
    }

    // MARK: AC1.4

    func testPluginSkillsAreAttributedToTheirPlugin() {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["deploy", "nextjs"], commands: ["env"])

        let inventory = InventoryScanner(paths: fixture.paths).scanAll()
        let fromPlugin = inventory.items.filter { $0.origin == .plugin("vercel") }

        XCTAssertEqual(fromPlugin.count, 3, "two skills and one command")
        XCTAssertEqual(inventory.plugins.map(\.id), ["vercel@official"])
        XCTAssertFalse(fromPlugin.allSatisfy(\.isEditable), "plugin files are not edited")
    }

    /// Changed 2026-08-15, after an audit drove the interface: a plugin being off is the plugin's
    /// state, not its items'. Folding the two together made every row of a disabled plugin claim to
    /// be switched off, and flipping one of those switches then tried to bring back something that
    /// had never been parked — it failed with "already exists". The app now says the two things
    /// separately, and the row is dimmed by the plugin's state without lying about its own.
    func testADisabledPluginDoesNotRewriteItsItemsOwnState() {
        let fixture = Fixture()
        fixture.plugin("velho", skills: ["algo"], enabled: false)

        let inventory = InventoryScanner(paths: fixture.paths).scanAll()
        XCTAssertEqual(inventory.plugins.first?.enabled, false, "the plugin is switched off")
        XCTAssertEqual(
            inventory.items.first { $0.name == "algo" }?.enabled, true,
            "and the skill still says what it itself is: on, inside a plugin that is out"
        )
    }

    func testPluginAbsentFromEnabledPluginsCountsAsEnabled() {
        let fixture = Fixture()
        fixture.plugin("novo", skills: ["algo"])

        XCTAssertEqual(InventoryScanner(paths: fixture.paths).installedPlugins().first?.enabled, true)
    }

    // MARK: AC1.5

    func testCommandsAgentsAndServersAreInventoried() {
        let fixture = Fixture()
        fixture.command("imark-notes")
        fixture.agent("revisor")
        fixture.mcpServer("notebooklm", command: "npx notebooklm-mcp")

        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        XCTAssertEqual(items.filter { $0.kind == .command }.map(\.name), ["imark-notes"])
        XCTAssertEqual(items.filter { $0.kind == .agent }.map(\.name), ["revisor"])
        let server = items.first { $0.kind == .mcp }
        XCTAssertEqual(server?.name, "notebooklm")
        XCTAssertEqual(server?.description, "npx notebooklm-mcp")
    }

    /// A repository can turn a plugin off for whoever works in it, in its own `.claude/settings.json`.
    /// Claude Code reads that after `~/.claude`, so showing the reader's own choice there was the app
    /// claiming a plugin was on while the assistant had it off.
    func testARepositoryOverrulesYourOwnPluginChoice() {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "mkt", skills: ["deploy"], enabled: true)
        let repo = fixture.projectRepo("TGC/open-mercato")
        fixture.repositorySettings(repo, enabledPlugins: ["vercel@mkt": false])
        let project = Project(name: "open-mercato", relativePath: "TGC/open-mercato", path: repo)
        let scanner = InventoryScanner(paths: fixture.paths)

        let mine = scanner.installedPlugins().first
        XCTAssertEqual(mine?.enabled, true, "yours says on")
        XCTAssertNil(mine?.repositoryChoice, "and no repository is in the question")

        let scoped = scanner.scanAll(project: project).plugins.first
        XCTAssertEqual(scoped?.enabled, false, "the repository's answer is the one in effect")
        XCTAssertEqual(scoped?.repositoryChoice, false, "and the row can say who decided")
    }

    /// A repository that ships servers in its own `.mcp.json` must show them. Reading only
    /// `~/.claude.json` left a team's servers invisible, which is the app's one promise broken.
    func testServersARepositoryShipsAreListedUnderThatProject() {
        let fixture = Fixture()
        let repo = fixture.projectRepo("TGC/open-mercato")
        fixture.repositoryMCP(repo, servers: ["linear": "npx linear-mcp", "sentry": "npx sentry-mcp"])
        let project = Project(name: "open-mercato", relativePath: "TGC/open-mercato", path: repo)

        let items = InventoryScanner(paths: fixture.paths).scanAll(project: project)
            .items(kind: .mcp)

        XCTAssertEqual(items.map(\.name), ["linear", "sentry"])
        XCTAssertEqual(items.first?.description, "npx linear-mcp")
        XCTAssertEqual(items.first?.origin, .project("open-mercato"))
        XCTAssertTrue(items.allSatisfy(\.declaredByRepository))
        // Neither approved nor refused yet: Claude Code asks before it loads what a repository
        // ships, and until that is answered it loads none of them. Off, with the reason on the item.
        XCTAssertFalse(items.contains(where: \.enabled))
        XCTAssertEqual(
            items.first?.warning,
            "Not approved yet, so Claude is not loading it. Turning it on here is the answer it is waiting for."
        )
        // Points at the repository's own file, not at the reader's config.
        XCTAssertEqual(items.first?.path, fixture.paths.projectMCPJSON(repo))
        XCTAssertFalse(items.contains { $0.isEditable }, "the team's file is never ours to delete")
    }

    /// The two answers a person can have given: approved reads as on, refused reads as off, and
    /// both live in the reader's own config so the repository's file is the same for everybody.
    func testAnApprovedRepositoryServerIsOnAndARefusedOneIsOff() {
        let fixture = Fixture()
        let repo = fixture.projectRepo("TGC/open-mercato")
        fixture.repositoryMCP(repo, servers: ["linear": "npx linear-mcp", "sentry": "npx sentry-mcp"])
        fixture.approveRepositoryMCP("linear", in: repo)
        fixture.declineRepositoryMCP("sentry", in: repo)
        let project = Project(name: "open-mercato", relativePath: "TGC/open-mercato", path: repo)

        let items = InventoryScanner(paths: fixture.paths).scanAll(project: project)
            .items(kind: .mcp)

        XCTAssertEqual(items.first { $0.name == "linear" }?.enabled, true)
        XCTAssertEqual(items.first { $0.name == "sentry" }?.enabled, false)
    }

    func testProjectItemsAppearOnlyWhenAProjectIsInContext() {
        let fixture = Fixture()
        let repo = fixture.projectRepo("PERSONAL/APPS/imark", skills: ["imark-dev"])
        let project = Project(name: "imark", relativePath: "PERSONAL/APPS/imark", path: repo)

        let global = InventoryScanner(paths: fixture.paths).scanAll()
        XCTAssertTrue(global.items.isEmpty)

        let scoped = InventoryScanner(paths: fixture.paths).scanAll(project: project)
        XCTAssertEqual(scoped.items.map(\.name), ["imark-dev"])
        XCTAssertEqual(scoped.items.first?.origin, .project("imark"))
    }

    /// The scope shows what belongs to the project and nothing else: a personal skill must
    /// NOT appear under a project scope, and a project with nothing of its own scopes to an
    /// empty list rather than echoing the global inventory.
    func testAProjectScopeExcludesTheGlobalInventory() {
        let fixture = Fixture()
        fixture.skill("global-skill")
        let repo = fixture.projectRepo("TGC/iota", skills: [])
        let iota = Project(name: "iota", relativePath: "TGC/iota", path: repo)

        XCTAssertEqual(InventoryScanner(paths: fixture.paths).scanAll().items.map(\.name), ["global-skill"])
        XCTAssertTrue(
            InventoryScanner(paths: fixture.paths).scanAll(project: iota).items.isEmpty,
            "a project with no skills of its own is empty, not a copy of Global"
        )
    }

    // MARK: AC1.6

    /// Projects come from looking, not from a listing. The nested layout matters: repositories
    /// live at all sorts of depths under the folder somebody points at.
    func testProjectsComeFromLookingInsideTheChosenFolder() {
        let fixture = Fixture()
        fixture.projectRepo("PERSONAL/imark")
        fixture.projectRepo("TGC/open-mercato")

        let projects = ProjectRoots(folders: [fixture.paths.projectsRoot])
            .discover(home: fixture.paths.home)

        XCTAssertEqual(projects.map(\.relativePath), ["PERSONAL/imark", "TGC/open-mercato"])
        XCTAssertEqual(projects.first?.name, "imark")
    }

    func testAFolderWithNoRepositoriesIsNotAnError() {
        let fixture = Fixture()
        XCTAssertTrue(
            ProjectRoots(folders: [fixture.paths.projectsRoot])
                .discover(home: fixture.paths.home).isEmpty
        )
    }

    // MARK: AC2.4

    func testSearchIgnoresCaseAndAccents() {
        // Accented on purpose: typing the plain letters has to find it, or a search box is
        // useless to anyone whose skills are named in their own language.
        let item = Item(
            id: "1", name: "Résumé-Review", kind: .skill, origin: .personal,
            description: "Naïve façade audit"
        )
        XCTAssertTrue(Filtering.matches(item, query: "resume"))
        XCTAssertTrue(Filtering.matches(item, query: "RÉSUMÉ"))
        XCTAssertTrue(Filtering.matches(item, query: "FACADE"))
        XCTAssertTrue(Filtering.matches(item, query: "   "), "an empty query shows everything")
        XCTAssertFalse(Filtering.matches(item, query: "vercel"))
    }

    func testSortingByUsagePutsTheMostUsedFirstAndBreaksTiesByName() {
        let make = { (name: String, count: Int) in
            Item(id: name, name: name, kind: .skill, origin: .personal,
                 usage: Usage(count: count, lastUsed: nil, projectCount: 1))
        }
        let items = [make("beta", 2), make("alfa", 9), make("gama", 2)]

        XCTAssertEqual(Filtering.sort(items, by: .usage).map(\.name), ["alfa", "beta", "gama"])
        XCTAssertEqual(Filtering.sort(items, by: .name).map(\.name), ["alfa", "beta", "gama"])
    }

    /// The "Disabled" chip is a flat state check now — !enabled, full stop — so a plugin
    /// switched off shows there too, next to skills the user parked by hand. That's the
    /// approved redesign: one axis (kind) in the sidebar, state as a chip on top of it,
    /// The Off filter is about what was switched off one by one. A plugin that is out of the house
    /// takes its items with it, and that is said by the plugin's own switch and by the dimming.
    func testDisabledChipCountsAnyDisabledItemOfTheSelectedKind() {
        let fixture = Fixture()
        fixture.skill("parqueada", disabled: true)
        fixture.plugin("vercel", skills: ["deploy", "nextjs"], enabled: false)

        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        let skills = Filtering.slice(items, for: .skills)

        XCTAssertEqual(
            Filtering.filter(skills, by: .disabled).map(\.name).sorted(),
            ["parqueada"],
            "Off is what was switched off item by item; a whole plugin out is the plugin's own switch"
        )
        XCTAssertEqual(
            Filtering.slice(items, for: .skills).filter { $0.origin == .plugin("vercel") }.map(\.name).sorted(),
            ["deploy", "nextjs"]
        )
        XCTAssertTrue(
            Filtering.slice(items, for: .skills)
                .filter { $0.origin == .plugin("vercel") }
                .allSatisfy { $0.enabled },
            "each says its own state; the plugin's is said separately"
        )
    }

    /// "Personal", not "Global": the redesign moves origin out of the sidebar entirely, so the
    /// old rationale for calling it "Global" (a sidebar label about where a skill applies)
    /// no longer applies to a filter chip, whose job is to say whose it is.
    func testTheMineChipIsLabelledByWhoseItIsNotByWhereItApplies() {
        XCTAssertEqual(ItemFilter.mine.title, "Personal")
    }

    /// `.fromPlugins` narrows to items whose origin is `.plugin` — a filter per origin, so
    /// "From plugins" and "12" mean what they say.
    func testFromPluginsChipIsolatesPluginOrigin() {
        let fixture = Fixture()
        fixture.skill("pessoal")
        fixture.plugin("vercel", skills: ["deploy"])

        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        let plugins = Filtering.filter(items, by: .fromPlugins)

        XCTAssertEqual(plugins.map(\.name), ["deploy"])
        XCTAssertTrue(plugins.allSatisfy {
            if case .plugin = $0.origin { return true }
            return false
        })
    }

    func testSidebarRowsSliceByKindOnlyAndChipsNarrowFromThere() {
        let fixture = Fixture()
        fixture.skill("ativa")
        fixture.skill("parada", disabled: true)
        fixture.command("um-comando")

        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        // The sidebar row alone: every skill, active or not.
        XCTAssertEqual(Filtering.slice(items, for: .skills).map(\.name).sorted(), ["ativa", "parada"])
        // The chip narrows it further.
        XCTAssertEqual(
            Filtering.filter(Filtering.slice(items, for: .skills), by: .disabled).map(\.name), ["parada"]
        )
        XCTAssertEqual(Filtering.slice(items, for: .commands).map(\.name), ["um-comando"])
    }

    func testMineChipIsPersonalOrigin() {
        let items = [
            Item(id: "1", name: "pessoal", kind: .skill, origin: .personal),
            Item(id: "2", name: "projeto", kind: .skill, origin: .project("repo")),
            Item(id: "3", name: "plugin", kind: .skill, origin: .plugin("vercel")),
        ]
        XCTAssertEqual(Filtering.filter(items, by: .mine).map(\.name), ["pessoal"])
    }

    /// What used to be the ".shared" chip is now the assistant menu's "In more than one" entry.
    func testAssistantFilterMultipleIsSkillsLoadedByMoreThanOneAssistant() {
        let items = [
            Item(id: "1", name: "so-claude", kind: .skill, origin: .personal, assistants: ["claude"]),
            Item(id: "2", name: "partilhada", kind: .skill, origin: .personal, assistants: ["claude", "codex"]),
        ]
        XCTAssertEqual(Filtering.filter(items, by: AssistantFilter.multiple).map(\.name), ["partilhada"])
    }

    /// Picking one assistant by name keeps only what that assistant actually loads.
    func testAssistantFilterOneIsSkillsThatAssistantLoads() {
        let items = [
            Item(id: "1", name: "so-claude", kind: .skill, origin: .personal, assistants: ["claude"]),
            Item(id: "2", name: "partilhada", kind: .skill, origin: .personal, assistants: ["claude", "codex"]),
            Item(id: "3", name: "so-codex", kind: .skill, origin: .personal, assistants: ["codex"]),
        ]
        XCTAssertEqual(
            Filtering.filter(items, by: AssistantFilter.one("codex")).map(\.name).sorted(),
            ["partilhada", "so-codex"]
        )
    }

    /// The chip and the assistant menu are independent choices that combine — "Personal" plus
    /// "Codex" means personal skills Codex loads, not a switch from one filter to the other.
    func testAssistantFilterComposesWithChipFilter() {
        let items = [
            Item(id: "1", name: "pessoal-codex", kind: .skill, origin: .personal, assistants: ["codex"]),
            Item(id: "2", name: "plugin-codex", kind: .skill, origin: .plugin("vercel"), assistants: ["codex"]),
            Item(id: "3", name: "pessoal-claude", kind: .skill, origin: .personal, assistants: ["claude"]),
        ]
        XCTAssertEqual(
            Filtering.apply(
                items, selection: .skills, filter: .mine, assistant: .one("codex"), query: "", order: .name
            ).map(\.name),
            ["pessoal-codex"]
        )
    }

    func testNeverUsedChipIsZeroUsageCount() {
        let items = [
            Item(id: "1", name: "usada", kind: .skill, origin: .personal, usage: Usage(count: 3, lastUsed: nil, projectCount: 1)),
            Item(id: "2", name: "nunca", kind: .skill, origin: .personal, usage: .none),
        ]
        XCTAssertEqual(Filtering.filter(items, by: .neverUsed).map(\.name), ["nunca"])
    }

    /// `.plugins` is a sidebar row with no items of its own — the plugin manager reads the
    /// plugin list directly instead of going through `Filtering`.
    func testPluginsSelectionHasNoItemSlice() {
        let items = [Item(id: "1", name: "algo", kind: .skill, origin: .personal)]
        XCTAssertEqual(Filtering.slice(items, for: .plugins), [])
    }
}

/// The third position of the scope button: yours, every project's and the plugins', at once.
extension InventoryTests {

    func testEverythingHoldsGlobalAndEveryProjectWithTheirOriginsIntact() {
        let fixture = Fixture()
        fixture.skill("mine")
        fixture.projectRepo("APPS/loadout", skills: ["from-loadout"])
        fixture.projectRepo("TGC/open-mercato", skills: ["from-mercato"])
        let projects = ProjectRoots(folders: [fixture.paths.projectsRoot])
            .discover(home: fixture.paths.home)

        let items = InventoryScanner(paths: fixture.paths).scanEverything(projects: projects).items
            .filter { $0.kind == .skill }

        XCTAssertEqual(items.map(\.name).sorted(), ["from-loadout", "from-mercato", "mine"])
        XCTAssertEqual(items.first { $0.name == "mine" }?.origin, .personal)
        XCTAssertEqual(items.first { $0.name == "from-loadout" }?.origin, .project("loadout"))
        XCTAssertEqual(
            items.first { $0.name == "from-mercato" }?.origin, .project("open-mercato"),
            "each row still knows where it comes from — that is what the tag shows"
        )
    }

    func testTwoProjectsMayHoldASkillOfTheSameNameWithoutOneHidingTheOther() {
        let fixture = Fixture()
        fixture.projectRepo("APPS/loadout", skills: ["deploy"])
        fixture.projectRepo("TGC/open-mercato", skills: ["deploy"])
        let projects = ProjectRoots(folders: [fixture.paths.projectsRoot])
            .discover(home: fixture.paths.home)

        let deploys = InventoryScanner(paths: fixture.paths).scanEverything(projects: projects).items
            .filter { $0.name == "deploy" }

        XCTAssertEqual(deploys.count, 2)
        XCTAssertEqual(Set(deploys.map(\.id)).count, 2, "distinct ids, or one hides the other in the list")
    }
}
