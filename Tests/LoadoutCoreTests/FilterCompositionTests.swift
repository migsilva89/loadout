import XCTest
@testable import LoadoutCore

/// The chip counts and the list must always agree: whatever combination of sidebar kind,
/// chip, assistant menu and search the person has active, the number on a chip is exactly
/// what clicking it would show. The bug this file pins down: "All 56" staying on screen
/// while an assistant with nothing loaded showed an empty list.
final class FilterCompositionTests: XCTestCase {
    private let fm = FileManager.default

    private func codexSkill(_ name: String, in fixture: Fixture) {
        let folder = fixture.paths.skillsRoot(forAssistant: "codex").appendingPathComponent(name)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! "---\nname: \(name)\ndescription: From Codex.\n---\n\nBody.".write(
            to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
    }

    private func count(
        _ fixture: Fixture,
        selection: Selection = .skills,
        filter: ItemFilter = .all,
        assistant: AssistantFilter = .any,
        query: String = ""
    ) -> Int {
        let items = InventoryScanner(paths: fixture.paths).scanAll().items
        return Filtering.apply(
            items, selection: selection, filter: filter,
            assistant: assistant, query: query, order: .name
        ).count
    }

    private func item(
        _ name: String, kind: ItemKind, enabled: Bool = true,
        origin: Origin = .personal, pluginID: String? = nil,
        frontmatter: [String: String] = [:]
    ) -> Item {
        Item(
            id: "\(kind.rawValue):\(origin.label):\(name)", name: name, kind: kind,
            origin: origin, frontmatter: frontmatter, enabled: enabled, pluginID: pluginID
        )
    }

    // MARK: Assistant menu × chips

    func testAnAssistantWithNothingLoadedCountsZeroOnEveryChip() {
        let fixture = Fixture()
        fixture.skill("one")
        fixture.skill("outra")

        for chip in ItemFilter.allCases {
            XCTAssertEqual(
                count(fixture, filter: chip, assistant: .one("windsurf")), 0,
                "the \(chip) chip has to say 0 when the assistant loads nothing"
            )
        }
    }

    func testTheAllChipCountsOnlyWhatTheChosenAssistantLoads() {
        let fixture = Fixture()
        fixture.skill("so-claude")
        codexSkill("so-codex", in: fixture)

        XCTAssertEqual(count(fixture, assistant: .any), 2)
        XCTAssertEqual(count(fixture, assistant: .one("claude")), 1)
        XCTAssertEqual(count(fixture, assistant: .one("codex")), 1)
    }

    func testTheMultipleAssistantsFilterCountsOnlySharedSkills() {
        let fixture = Fixture()
        fixture.skill("partilhada")
        codexSkill("partilhada", in: fixture)
        fixture.skill("so-claude")

        XCTAssertEqual(count(fixture, assistant: .multiple), 1)
    }

    // MARK: Search × chips

    func testSearchNarrowsTheChipCounts() {
        let fixture = Fixture()
        fixture.skill("mapa-mental", description: "Diagramas.")
        fixture.skill("relatorio", description: "Prosa.")

        XCTAssertEqual(count(fixture, query: "mapa"), 1)
        XCTAssertEqual(count(fixture, query: "nada disto existe"), 0)
    }

    func testSearchAndAssistantNarrowTogether() {
        let fixture = Fixture()
        fixture.skill("mapa-mental")
        codexSkill("mapa-no-codex", in: fixture)

        // Both match "mapa", but only one belongs to Codex.
        XCTAssertEqual(count(fixture, query: "mapa"), 2)
        XCTAssertEqual(count(fixture, assistant: .one("codex"), query: "mapa"), 1)
    }

    // MARK: Chips × state

    func testTheOffChipCountsFollowTheAssistantFilterToo() {
        let fixture = Fixture()
        fixture.skill("ligada")
        fixture.skill("desligada", disabled: true)

        XCTAssertEqual(count(fixture, filter: .disabled), 1)
        // A parked skill belongs to nobody, so any named assistant counts it out.
        XCTAssertEqual(count(fixture, filter: .disabled, assistant: .one("codex")), 0)
    }

    func testTheKindSliceStillBoundsEverything() {
        let fixture = Fixture()
        fixture.skill("a-skill")
        fixture.command("um-comando")

        XCTAssertEqual(count(fixture, selection: .skills), 1)
        XCTAssertEqual(count(fixture, selection: .commands), 1)
        XCTAssertEqual(count(fixture, selection: .commands, query: "skill"), 0)
    }


    // MARK: Every kind × effective state

    func testOnAndOffFiltersWorkForEveryInventoryKind() {
        let kinds: [(Selection, ItemKind)] = [
            (.skills, .skill), (.commands, .command), (.agents, .agent), (.mcp, .mcp),
        ]
        for (selection, kind) in kinds {
            let items = [item("on", kind: kind), item("off", kind: kind, enabled: false)]
            let on = Filtering.apply(
                items, selection: selection, filter: .enabled, query: "", order: .name
            )
            let off = Filtering.apply(
                items, selection: selection, filter: .disabled, query: "", order: .name
            )
            XCTAssertEqual(on.map(\.name), ["on"], "\(kind) has an On filter")
            XCTAssertEqual(off.map(\.name), ["off"], "\(kind) has an Off filter")
        }
    }

    func testTurningOffAPluginMakesEveryKindItShipsEffectivelyOff() {
        let pluginID = "toolkit@mkt"
        let items = [
            item("skill", kind: .skill, origin: .plugin("toolkit"), pluginID: pluginID),
            item("command", kind: .command, origin: .plugin("toolkit"), pluginID: pluginID),
            item("agent", kind: .agent, origin: .plugin("toolkit"), pluginID: pluginID),
        ]
        for (selection, name) in [(Selection.skills, "skill"), (.commands, "command"), (.agents, "agent")] {
            XCTAssertEqual(
                Filtering.apply(
                    items, selection: selection, filter: .disabled, query: "", order: .name,
                    disabledPluginIDs: [pluginID]
                ).map(\.name),
                [name]
            )
            XCTAssertTrue(Filtering.apply(
                items, selection: selection, filter: .enabled, query: "", order: .name,
                disabledPluginIDs: [pluginID]
            ).isEmpty)
        }
        XCTAssertTrue(items.allSatisfy(\.enabled), "their own choices remain on for the next plugin enable")
    }

    func testPluginOriginFilterCoversSkillsCommandsAndAgents() {
        let plugin = Origin.plugin("toolkit")
        let items = [
            item("skill", kind: .skill, origin: plugin),
            item("command", kind: .command, origin: plugin),
            item("agent", kind: .agent, origin: plugin),
            item("personal", kind: .skill),
        ]
        for selection in [Selection.skills, .commands, .agents] {
            XCTAssertEqual(
                Filtering.apply(
                    items, selection: selection, filter: .fromPlugins, query: "", order: .name
                ).count,
                1
            )
        }
    }

    // MARK: Generic frontmatter

    func testFrontmatterFilterAcceptsAnyKeyAndComposesWithKind() {
        let items = [
            item("forked", kind: .skill, frontmatter: ["context": "fork"]),
            item("plain", kind: .skill, frontmatter: ["name": "plain"]),
            item("command", kind: .command, frontmatter: ["context": "fork"]),
        ]

        let filtered = Filtering.apply(
            items, selection: .skills, filter: .frontmatter, query: "", order: .name,
            frontmatterFilterKey: "context"
        )

        XCTAssertEqual(filtered.map(\.name), ["forked"])
    }

    func testFrontmatterSortUsesValuesAndPutsMissingKeysLast() {
        let items = [
            item("missing", kind: .skill),
            item("second", kind: .skill, frontmatter: ["priority": "20"]),
            item("first", kind: .skill, frontmatter: ["priority": "3"]),
        ]

        let sorted = Filtering.apply(
            items, selection: .skills, filter: .all, query: "", order: .frontmatter,
            frontmatterSortKey: "priority"
        )

        XCTAssertEqual(sorted.map(\.name), ["first", "second", "missing"])
    }
}
