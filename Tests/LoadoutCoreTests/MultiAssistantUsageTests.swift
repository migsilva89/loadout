import XCTest
@testable import LoadoutCore

/// The multi-assistant usage index: one adapter per format, Paseo as attribution rather than a
/// second count, a schema that migrates without ever showing half of itself, and a filter that
/// hides without destroying.
final class MultiAssistantUsageTests: XCTestCase {

    private func iso(daysAgo: Int) -> String {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func index(_ fixture: Fixture) throws -> UsageIndex {
        try UsageIndex(paths: fixture.paths, sources: UsageIndex.liveSources(paths: fixture.paths))
    }

    // MARK: - Codex: what counts and what does not

    func testACanonicalReadOfASkillCountsAsAnInferredUse() throws {
        let fixture = Fixture()
        fixture.codexSession("s", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall(
                "sed -n '1,240p' /Users/me/.agents/skills/human-copywrite/SKILL.md",
                at: iso(daysAgo: 2)
            ),
        ])
        let index = try index(fixture)

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill)["human-copywrite"]?.count, 1)
        let occurrence = try XCTUnwrap(index.occurrences(kind: .skill, key: "human-copywrite").first)
        XCTAssertEqual(occurrence.assistant, "codex")
        XCTAssertEqual(occurrence.evidence, .inferred, "o Codex não prova, infere — e diz que infere")
    }

    func testMerelyNamingASkillNeverCounts() throws {
        // The catalogue sits in every Codex prompt: 78 skills are named this way on the real
        // machine, against 30 ever actually read.
        let fixture = Fixture()
        fixture.codexSession("s", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.agentMessage(
                "Vou usar a skill seo-audit e ler /Users/me/.agents/skills/seo-audit/SKILL.md",
                at: iso(daysAgo: 1)
            ),
        ])
        let index = try index(fixture)

        index.refresh()

        XCTAssertNil(index.usage(kind: .skill)["seo-audit"], "uma menção não é um uso")
    }

    func testSearchingOrEditingASkillIsNotUsingIt() throws {
        let fixture = Fixture()
        fixture.codexSession("s", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall(
                "rg -n 'browser' /Users/me/.agents/skills/design-research/SKILL.md",
                at: iso(daysAgo: 1)
            ),
            CodexLine.toolCall(
                "ls /Users/me/.agents/skills/forge-kit/SKILL.md", at: iso(daysAgo: 1)
            ),
            CodexLine.toolCall(
                "apply_patch /Users/me/.agents/skills/skill-creator/SKILL.md", at: iso(daysAgo: 1)
            ),
        ])
        let index = try index(fixture)

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill), [:], "procurar e editar não é usar")
    }

    func testASingleCommandReadingTwoSkillsCountsBoth() throws {
        let fixture = Fixture()
        fixture.codexSession("s", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall(
                "sed -n '1,240p' /Users/me/.agents/skills/uma/SKILL.md && "
                    + "sed -n '1,240p' /Users/me/.agents/skills/outra/SKILL.md",
                at: iso(daysAgo: 1)
            ),
        ])
        let index = try index(fixture)

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill)["uma"]?.count, 1)
        XCTAssertEqual(index.usage(kind: .skill)["outra"]?.count, 1)
    }

    func testArchivedCodexSessionsCountToo() throws {
        let fixture = Fixture()
        fixture.codexSession("a", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall("cat /Users/me/.agents/skills/x/SKILL.md", at: iso(daysAgo: 1)),
        ])
        fixture.codexSession("b", archived: true, lines: [
            CodexLine.meta(session: "S-2"),
            CodexLine.toolCall("cat /Users/me/.agents/skills/x/SKILL.md", at: iso(daysAgo: 1)),
        ])
        let index = try index(fixture)

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill)["x"]?.count, 2)
    }

    func testTheSameSessionInBothFoldersIsCountedOnce() throws {
        // Archiving copies the session; identical input yields an identical event id, so the
        // duplicate collides instead of accumulating.
        let fixture = Fixture()
        let lines = [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall(
                "cat /Users/me/.agents/skills/x/SKILL.md", at: "2026-08-13T10:00:00.000Z"
            ),
        ]
        fixture.codexSession("same", lines: lines)
        fixture.codexSession("same", archived: true, lines: lines)
        let index = try index(fixture)

        index.refresh(since: .distantPast)

        XCTAssertEqual(index.usage(kind: .skill)["x"]?.count, 1, "a mesma sessão não conta duas vezes")
    }

    func testCodexSurfaceComesFromTheOriginator() throws {
        let fixture = Fixture()
        fixture.codexSession("s", lines: [
            CodexLine.meta(session: "S-1", originator: "Codex Desktop"),
            CodexLine.toolCall("cat /Users/me/.agents/skills/x/SKILL.md", at: iso(daysAgo: 1)),
        ])
        let index = try index(fixture)

        index.refresh()

        XCTAssertEqual(index.occurrences(kind: .skill, key: "x").first?.surface, "codex-app")
    }

    // MARK: - Paseo: attribution, never a second count

    func testPaseoAttributesASessionWithoutCountingItTwice() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [
            Line.skill("imark-review", at: iso(daysAgo: 1), session: "S-CLAUDE"),
        ])
        fixture.paseoAgent(provider: "claude", sessionID: "S-CLAUDE")
        let index = try index(fixture)

        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill)["imark-review"]?.count, 1, "um uso, não dois")
        XCTAssertEqual(
            index.occurrences(kind: .skill, key: "imark-review").first?.surface, "paseo",
            "o Paseo hospeda Claude também, e isso é uma etiqueta, não um evento novo"
        )
    }

    func testASessionPaseoNeverRanIsNotAttributedToIt() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [
            Line.skill("imark-review", at: iso(daysAgo: 1), session: "S-SOZINHA"),
        ])
        fixture.paseoAgent(provider: "claude", sessionID: "S-OUTRA")
        let index = try index(fixture)

        index.refresh()

        XCTAssertNil(index.occurrences(kind: .skill, key: "imark-review").first?.surface)
    }

    // MARK: - Which assistants count

    func testUncheckingAnAssistantStopsCountingItAndCheckingItBringsTheCountBack() throws {
        let fixture = Fixture()
        fixture.transcript("c", lines: [Line.skill("partilhada", at: iso(daysAgo: 1))])
        fixture.codexSession("x", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall(
                "cat /Users/me/.agents/skills/partilhada/SKILL.md", at: iso(daysAgo: 1)
            ),
        ])
        let index = try index(fixture)
        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill, assistants: ["claude", "codex"])["partilhada"]?.count, 2)
        XCTAssertEqual(index.usage(kind: .skill, assistants: ["claude"])["partilhada"]?.count, 1)
        XCTAssertEqual(index.usage(kind: .skill, assistants: ["codex"])["partilhada"]?.count, 1)
        // Nothing was reindexed and nothing was lost: the same query returns the same number again.
        XCTAssertEqual(index.usage(kind: .skill, assistants: ["claude", "codex"])["partilhada"]?.count, 2)
    }

    func testTheTotalCanBeBrokenDownByAssistant() throws {
        let fixture = Fixture()
        fixture.transcript("c", lines: [Line.skill("partilhada", at: iso(daysAgo: 1))])
        fixture.codexSession("x", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall(
                "cat /Users/me/.agents/skills/partilhada/SKILL.md", at: iso(daysAgo: 1)
            ),
            CodexLine.toolCall(
                "cat /Users/me/.agents/skills/partilhada/SKILL.md", at: iso(daysAgo: 2)
            ),
        ])
        let index = try index(fixture)
        index.refresh()

        let byAssistant = index.usageByAssistant(kind: .skill, key: "partilhada")

        XCTAssertEqual(byAssistant, ["claude": 1, "codex": 2], "as partes explicam o total")
        XCTAssertEqual(
            byAssistant.values.reduce(0, +), index.usage(kind: .skill)["partilhada"]?.count,
            "e somam exatamente o total"
        )
        XCTAssertEqual(
            index.usageByAssistant(kind: .skill, key: "partilhada", assistants: ["claude"]),
            ["claude": 1], "o detalhe respeita o mesmo filtro que o total"
        )
    }

    func testExcludingEverybodyCountsNothing() throws {
        let fixture = Fixture()
        fixture.transcript("c", lines: [Line.skill("uma", at: iso(daysAgo: 1))])
        let index = try index(fixture)
        index.refresh()

        XCTAssertEqual(index.usage(kind: .skill, assistants: []), [:])
    }

    func testProjectsAndOccurrencesHonourTheSameFilter() throws {
        let fixture = Fixture()
        fixture.transcript("c", lines: [Line.skill("uma", at: iso(daysAgo: 1))])
        let index = try index(fixture)
        index.refresh()

        XCTAssertEqual(index.projects(kind: .skill, key: "uma", assistants: ["claude"]).count, 1)
        XCTAssertEqual(index.projects(kind: .skill, key: "uma", assistants: ["codex"]), [])
        XCTAssertEqual(index.occurrences(kind: .skill, key: "uma", assistants: ["codex"]), [])
    }

    // MARK: - Sources that cannot prove anything say so

    func testAnUnsupportedSourceIsListedRatherThanSilentlyZero() throws {
        let fixture = Fixture()
        // Cursor's transcripts exist and are readable, but carry no timestamp and no skill signal.
        let folder = fixture.paths.cursorProjects
            .appendingPathComponent("Users-me-repo/agent-transcripts/abc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"role":"assistant","message":{"content":[]}}"#
            .write(to: folder.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)
        let index = try index(fixture)

        let cursor = try XCTUnwrap(index.sourceStatuses().first { $0.sourceID == "cursor" })
        XCTAssertEqual(cursor.state, .unsupported)
        XCTAssertEqual(cursor.sessionCount, 1, "há histórico; o que falta é prova")

        let pi = try XCTUnwrap(index.sourceStatuses().first { $0.sourceID == "pi" })
        XCTAssertEqual(pi.state, .noHistory, "sem histórico é diferente de sem parser")
    }

    func testAnUncheckedAssistantReadsAsNotCountedRatherThanMissing() throws {
        let fixture = Fixture()
        fixture.transcript("c", lines: [Line.skill("uma", at: iso(daysAgo: 1))])
        let index = try index(fixture)
        index.refresh()

        let claude = try XCTUnwrap(
            index.sourceStatuses(includedAssistants: ["codex"]).first { $0.sourceID == "claude" }
        )
        XCTAssertEqual(claude.state, .excluded)
        XCTAssertEqual(claude.eventCount, 1, "continua indexado — só não conta")
    }

    // MARK: - Incremental passes

    /// A source that is Claude's parser wearing a different version number, which is how a parser
    /// change is meant to invalidate its own cached files and nobody else's.
    private struct Reparsed: UsageSource {
        let id = "claude"
        let assistant = "claude"
        let label = "Claude Code"
        let parserVersion: Int
        let isSupported = true
        let inner: ClaudeUsageSource

        func historyFiles() -> [URL] { inner.historyFiles() }
        func events(in file: URL, since: Date) -> [UsageEvent] {
            inner.events(in: file, since: since)
        }
    }

    func testAFileIsRereadWhenItsParserChangesAndSkippedWhenItDoesNot() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [Line.skill("uma", at: iso(daysAgo: 1))])
        let inner = ClaudeUsageSource(paths: fixture.paths)
        let index = try index(fixture)
        let file = inner.historyFiles()[0]

        let first = Reparsed(parserVersion: 1, inner: inner)
        XCTAssertEqual(index.indexFile(file, source: first, since: .distantPast), 1, "primeira leitura")
        XCTAssertEqual(index.indexFile(file, source: first, since: .distantPast), -1, "inalterado, salta")

        let bumped = Reparsed(parserVersion: 2, inner: inner)
        XCTAssertEqual(
            index.indexFile(file, source: bumped, since: .distantPast), 1,
            "o parser mudou, o ficheiro volta a ser lido"
        )
        XCTAssertEqual(index.usage(kind: .skill)["uma"]?.count, 1, "e sem duplicar")
    }

    func testACodexFileIsNotRereadWhenOnlyClaudesParserChanged() throws {
        let fixture = Fixture()
        fixture.codexSession("s", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall("cat /Users/me/.agents/skills/x/SKILL.md", at: iso(daysAgo: 1)),
        ])
        let codex = CodexUsageSource(paths: fixture.paths)
        let index = try index(fixture)
        let file = codex.historyFiles()[0]

        XCTAssertEqual(index.indexFile(file, source: codex, since: .distantPast), 1)
        XCTAssertEqual(index.indexFile(file, source: codex, since: .distantPast), -1, "salta")
    }

    func testReindexingTheSameHistoryDoesNotInflateCounts() throws {
        let fixture = Fixture()
        fixture.codexSession("s", lines: [
            CodexLine.meta(session: "S-1"),
            CodexLine.toolCall("cat /Users/me/.agents/skills/x/SKILL.md", at: iso(daysAgo: 1)),
        ])
        let index = try index(fixture)

        index.refresh(since: .distantPast)
        index.refresh(since: .distantPast)

        XCTAssertEqual(index.usage(kind: .skill)["x"]?.count, 1)
    }

    func testNarrowingTheWindowDropsWhatItExcludesAndWideningBringsItBack() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [
            Line.skill("recente", at: iso(daysAgo: 5)),
            Line.skill("antiga", at: iso(daysAgo: 200)),
        ])
        let index = try index(fixture)

        index.refresh(since: .distantPast)
        XCTAssertEqual(index.usage(kind: .skill).count, 2)

        index.refresh(since: Date().addingTimeInterval(-30 * 86_400))
        XCTAssertNil(index.usage(kind: .skill)["antiga"], "fora da janela, fora da contagem")
        XCTAssertEqual(index.usage(kind: .skill)["recente"]?.count, 1)

        index.refresh(since: .distantPast)
        XCTAssertEqual(index.usage(kind: .skill)["antiga"]?.count, 1, "alargar volta a lê-la")
    }

    // MARK: - Migration

    func testAnIndexFromTheOldSchemaIsRebuiltAsideAndSwappedWhole() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [Line.skill("antiga", at: iso(daysAgo: 1))])

        // Exactly what the previous version of Loadout left on disk.
        try FileManager.default.createDirectory(
            at: fixture.paths.index.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try LegacyIndexWriter.write(at: fixture.paths.index, key: "antiga")

        let index = try index(fixture)
        // Before the rebuild, the old file still answers: nobody loses their counts mid-migration.
        XCTAssertEqual(index.usage(kind: .skill)["antiga"]?.count, 1)
        XCTAssertEqual(index.occurrences(kind: .skill, key: "antiga"), [], "o schema antigo não sabe explicar")

        index.refresh(since: .distantPast)

        XCTAssertEqual(index.usage(kind: .skill)["antiga"]?.count, 1, "reconstruído, mesmo número")
        XCTAssertEqual(
            index.occurrences(kind: .skill, key: "antiga").first?.assistant, "claude",
            "e agora sabe de quem foi"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.index.appendingPathExtension("migrating").path
            ),
            "a base temporária não fica para trás"
        )
    }

    func testACancelledMigrationLeavesThePreviousIndexUsable() throws {
        let fixture = Fixture()
        fixture.transcript("s", lines: [Line.skill("antiga", at: iso(daysAgo: 1))])
        try FileManager.default.createDirectory(
            at: fixture.paths.index.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try LegacyIndexWriter.write(at: fixture.paths.index, key: "antiga")
        let index = try index(fixture)

        index.refresh(since: .distantPast, cancelled: { true })

        XCTAssertEqual(
            index.usage(kind: .skill)["antiga"]?.count, 1,
            "interrompida a meio, as contagens antigas continuam a servir"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.index.appendingPathExtension("migrating").path
            )
        )
    }
}
