import XCTest
@testable import LoadoutCore

/// AC11.1–AC11.5 — frontmatter that is more than `key: value`.
///
/// The Vercel plugin's skills carry nested maps and a list of validate rules. Read flat, the inner
/// keys arrived on screen as fields of the skill, and each rule's `severity` overwrote the one
/// before it: wrong while looking right.
final class FrontmatterTreeTests: XCTestCase {

    private let vercelish = """
    ---
    name: vercel-functions
    description: Vercel Functions expert guidance.
    metadata:
      priority: 8
      docs:
        - "https://vercel.com/docs/functions"
        - "https://vercel.com/docs/functions/runtimes"
      pathPatterns: ['api/**/*.*', 'app/**/route.*']
      promptSignals:
        phrases:
          - "websocket"
          - "long polling"
        allOf: []
        minScore: 6
    validate:
      -
        pattern: export\\s+default\\s+function
        message: 'Use named exports instead'
        severity: error
      -
        pattern: maxRetries
        message: 'Manual retry logic'
        severity: recommended
    ---

    Corpo.
    """

    private func value(_ pairs: [(String, Frontmatter.Value)], _ key: String) -> Frontmatter.Value? {
        pairs.first { $0.0 == key }?.1
    }

    private func map(_ value: Frontmatter.Value?) -> [(String, Frontmatter.Value)] {
        guard case .map(let pairs)? = value else { return [] }
        return pairs
    }

    private func list(_ value: Frontmatter.Value?) -> [Frontmatter.Value] {
        guard case .list(let items)? = value else { return [] }
        return items
    }

    private func scalar(_ value: Frontmatter.Value?) -> String? {
        guard case .scalar(let text)? = value else { return nil }
        return text
    }

    // MARK: - AC11.1 nesting is kept

    func testANestedMapStaysNested() {
        let tree = Frontmatter.tree(vercelish)

        XCTAssertEqual(scalar(value(tree, "name")), "vercel-functions")
        XCTAssertNil(value(tree, "minScore"), "não sobe ao topo")

        let metadata = map(value(tree, "metadata"))
        XCTAssertEqual(scalar(value(metadata, "priority")), "8")
        let signals = map(value(metadata, "promptSignals"))
        XCTAssertEqual(scalar(value(signals, "minScore")), "6")
        XCTAssertEqual(list(value(signals, "phrases")).count, 2)
        XCTAssertEqual(list(value(signals, "allOf")), [], "uma lista vazia é uma lista vazia")
    }

    // MARK: - AC11.2 every entry of a list survives

    func testAListOfMapsKeepsEveryRule() {
        let rules = list(value(Frontmatter.tree(vercelish), "validate"))

        XCTAssertEqual(rules.count, 2, "duas regras, não uma a apagar a outra")
        XCTAssertEqual(scalar(value(map(rules.first), "severity")), "error")
        XCTAssertEqual(scalar(value(map(rules.last), "severity")), "recommended")
        XCTAssertEqual(scalar(value(map(rules.last), "message")), "Manual retry logic")
    }

    // MARK: - AC11.3 both ways of writing a list

    func testInlineAndDashedListsReadTheSame() {
        let metadata = map(value(Frontmatter.tree(vercelish), "metadata"))

        XCTAssertEqual(
            list(value(metadata, "pathPatterns")).compactMap { scalar($0) },
            ["api/**/*.*", "app/**/route.*"]
        )
        XCTAssertEqual(list(value(metadata, "docs")).count, 2)
    }

    func testAListEntryWithItsFirstPairOnTheDashLine() {
        let text = """
        ---
        name: x
        description: y
        validate:
          - pattern: abc
            severity: error
        ---
        """
        let rules = list(value(Frontmatter.tree(text), "validate"))

        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(scalar(value(map(rules.first), "pattern")), "abc")
        XCTAssertEqual(scalar(value(map(rules.first), "severity")), "error")
    }

    // MARK: - AC11.4 nothing that worked before changes

    func testTheFlatReadingIsUntouched() {
        let front = Frontmatter.parse(vercelish)

        XCTAssertEqual(front.name, "vercel-functions")
        XCTAssertEqual(front.description, "Vercel Functions expert guidance.")
        XCTAssertNil(front.warning)
    }

    func testAFoldedDescriptionStillReadsAsOneLine() {
        let text = """
        ---
        name: dobrada
        description: >
          Primeira linha
          segunda linha
        ---

        Corpo.
        """
        let tree = Frontmatter.tree(text)

        XCTAssertEqual(scalar(value(tree, "description")), "Primeira linha segunda linha")
        XCTAssertEqual(Frontmatter.parse(text).description, "Primeira linha segunda linha")
    }

    func testAFlatFrontmatterProducesAFlatTree() {
        let text = "---\nname: simples\ndescription: Uma linha.\n---\n\nCorpo."

        let tree = Frontmatter.tree(text)

        XCTAssertEqual(tree.map(\.0), ["name", "description"])
        XCTAssertEqual(scalar(value(tree, "description")), "Uma linha.")
    }
}

/// The six things a code review found in the first cut of the tree reader and the MCP switch.
/// Each one is here so it cannot come back quietly.
extension FrontmatterTreeTests {

    func testAWrappedValueIsOneValueNotAStrayField() {
        let text = """
        ---
        name: dobrada
        description: Uma frase que continua
          na linha seguinte, com dois pontos: aqui
        ---

        Corpo.
        """
        let tree = Frontmatter.tree(text)

        XCTAssertEqual(tree.map(\.0), ["name", "description"], "sem campos inventados")
        XCTAssertEqual(
            scalar(value(tree, "description")),
            "Uma frase que continua na linha seguinte, com dois pontos: aqui"
        )
    }

    func testAnUnquotedURLInAListIsAURL() {
        let text = """
        ---
        name: x
        description: y
        docs:
          - https://vercel.com/docs/functions
          - https://vercel.com/docs
        ---
        """
        let docs = list(value(Frontmatter.tree(text), "docs"))

        XCTAssertEqual(docs.compactMap { scalar($0) },
                       ["https://vercel.com/docs/functions", "https://vercel.com/docs"])
    }

    func testACommentInsideABlockValueSurvives() {
        let text = """
        ---
        name: x
        description: |
          primeira linha
          # isto faz parte do texto
        ---
        """
        XCTAssertEqual(
            scalar(value(Frontmatter.tree(text), "description")),
            "primeira linha # isto faz parte do texto"
        )
    }

    func testACommentBetweenFieldsIsNotAField() {
        let text = """
        ---
        name: x
        # uma nota para quem lê o ficheiro
        description: y
        ---
        """
        XCTAssertEqual(Frontmatter.tree(text).map(\.0), ["name", "description"])
    }
}

extension FrontmatterTreeTests {

    func testACommentInsideAListDoesNotEndTheBlock() {
        let text = """
        ---
        name: x
        description: y
        metadata:
          promptSignals:
            phrases:
              - "websocket"
              # uma nota a explicar o que fica de fora, de propósito
              - "long polling"
            minScore: 6
          priority: 8
        ---
        """
        let metadata = map(value(Frontmatter.tree(text), "metadata"))
        let signals = map(value(metadata, "promptSignals"))

        XCTAssertEqual(list(value(signals, "phrases")).compactMap { scalar($0) },
                       ["websocket", "long polling"])
        XCTAssertEqual(scalar(value(signals, "minScore")), "6", "o que vem a seguir não se perde")
        XCTAssertEqual(scalar(value(metadata, "priority")), "8")
    }
}
