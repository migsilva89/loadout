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
        try "---\nname: emprestada\ndescription: Vem de fora.\n---\n\nCorpo.".write(
            to: elsewhere.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.skills.appendingPathComponent("emprestada"), withDestinationURL: elsewhere
        )

        let skills = InventoryScanner(paths: fixture.paths).scanAll().items.filter { $0.kind == .skill }

        XCTAssertEqual(skills.map(\.name).sorted(), ["emprestada", "normal"])
        XCTAssertEqual(skills.first { $0.name == "emprestada" }?.description, "Vem de fora.")
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

        Corpo.
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
        fixture.rawSkill("sem-frontmatter", contents: "# Só markdown\n\nNada de yaml.")

        let item = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .skill }
        XCTAssertEqual(item?.name, "sem-frontmatter", "cai para o nome da pasta")
        XCTAssertNotNil(item?.warning)
    }

    func testUnclosedFrontmatterIsReportedNotSwallowed() {
        let fixture = Fixture()
        fixture.rawSkill("aberto", contents: "---\nname: aberto\ndescription: x\n\nSem fecho.")

        let item = InventoryScanner(paths: fixture.paths).scanAll().items.first { $0.kind == .skill }
        XCTAssertEqual(item?.warning, "The frontmatter opens but never closes with ---.")
    }

    func testMismatchBetweenFolderAndDeclaredNameIsFlagged() {
        let fixture = Fixture()
        fixture.rawSkill("pasta-a", contents: "---\nname: outro-nome\ndescription: x\n---\n\nCorpo.")

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

    // MARK: AC1.4

    func testPluginSkillsAreAttributedToTheirPlugin() {
        let fixture = Fixture()
        fixture.plugin("vercel", marketplace: "official", skills: ["deploy", "nextjs"], commands: ["env"])

        let inventory = InventoryScanner(paths: fixture.paths).scanAll()
        let fromPlugin = inventory.items.filter { $0.origin == .plugin("vercel") }

        XCTAssertEqual(fromPlugin.count, 3, "duas skills e um comando")
        XCTAssertEqual(inventory.plugins.map(\.id), ["vercel@official"])
        XCTAssertFalse(fromPlugin.allSatisfy(\.isEditable), "ficheiros de plugin não se editam")
    }

    func testDisabledPluginMarksItsItemsDisabled() {
        let fixture = Fixture()
        fixture.plugin("velho", skills: ["algo"], enabled: false)

        let inventory = InventoryScanner(paths: fixture.paths).scanAll()
        XCTAssertEqual(inventory.plugins.first?.enabled, false)
        XCTAssertEqual(inventory.items.first { $0.name == "algo" }?.enabled, false)
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

    // MARK: AC1.6

    func testProjectsComeFromTheGeneratedIndex() {
        let fixture = Fixture()
        fixture.projectsIndex("""
        # Índice de Projetos

        | Caminho | Descrição |
        |---|---|
        | `PERSONAL/APPS/imark` | Revisão de markdown |
        | `TGC/open-mercato` | Plataforma |

        ## Outra secção

        | Caminho | Descrição |
        |---|---|
        | `PERSONAL/APPS/imark` | Duplicado, deve ser ignorado |
        """)

        let projects = ProjectsIndex(paths: fixture.paths).load()
        XCTAssertEqual(projects.map(\.relativePath), ["PERSONAL/APPS/imark", "TGC/open-mercato"])
        XCTAssertEqual(projects.first?.name, "imark")
        XCTAssertEqual(
            projects.first?.path.path,
            fixture.paths.projectsRoot.appendingPathComponent("PERSONAL/APPS/imark").path
        )
    }

    func testMissingProjectsIndexIsNotAnError() {
        let fixture = Fixture()
        XCTAssertEqual(ProjectsIndex(paths: fixture.paths).load(), [])
    }

    // MARK: AC2.4

    func testSearchIgnoresCaseAndAccents() {
        let item = Item(
            id: "1", name: "Revisão-SEO", kind: .skill, origin: .personal,
            description: "Auditoria de páginas"
        )
        XCTAssertTrue(Filtering.matches(item, query: "revisao"))
        XCTAssertTrue(Filtering.matches(item, query: "seo"))
        XCTAssertTrue(Filtering.matches(item, query: "PAGINAS"))
        XCTAssertTrue(Filtering.matches(item, query: "   "), "consulta vazia mostra tudo")
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
    /// no more special-casing plugin-disabled versus user-disabled in separate places.
    func testDisabledChipCountsAnyDisabledItemOfTheSelectedKind() {
        let fixture = Fixture()
        fixture.skill("parqueada", disabled: true)
        fixture.plugin("vercel", skills: ["deploy", "nextjs"], enabled: false)

        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        let skills = Filtering.slice(items, for: .skills)

        XCTAssertEqual(
            Filtering.filter(skills, by: .disabled).map(\.name).sorted(),
            ["deploy", "nextjs", "parqueada"]
        )
        XCTAssertEqual(
            Filtering.slice(items, for: .skills).filter { $0.origin == .plugin("vercel") }.map(\.name).sorted(),
            ["deploy", "nextjs"]
        )
        XCTAssertTrue(
            Filtering.slice(items, for: .skills)
                .filter { $0.origin == .plugin("vercel") }
                .allSatisfy { !$0.enabled },
            "continuam marcados como inativos, para aparecerem esbatidos"
        )
    }

    /// "Mine", not "Global": the redesign moves origin out of the sidebar entirely, so the
    /// old rationale for calling it "Global" (a sidebar label about where a skill applies)
    /// no longer applies to a filter chip, whose job is to say whose it is.
    func testTheMineChipIsLabelledByWhoseItIsNotByWhereItApplies() {
        XCTAssertEqual(ItemFilter.mine.title, "Mine")
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

    func testThisProjectChipIsProjectOrigin() {
        let items = [
            Item(id: "1", name: "pessoal", kind: .skill, origin: .personal),
            Item(id: "2", name: "projeto", kind: .skill, origin: .project("repo")),
        ]
        XCTAssertEqual(Filtering.filter(items, by: .thisProject).map(\.name), ["projeto"])
    }

    func testSharedChipIsSkillsLoadedByMoreThanOneAssistant() {
        let items = [
            Item(id: "1", name: "so-claude", kind: .skill, origin: .personal, assistants: ["claude"]),
            Item(id: "2", name: "partilhada", kind: .skill, origin: .personal, assistants: ["claude", "codex"]),
        ]
        XCTAssertEqual(Filtering.filter(items, by: .shared).map(\.name), ["partilhada"])
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
