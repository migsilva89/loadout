import XCTest
@testable import LoadoutCore

/// The "Ask" feature works with whatever assistant CLI is installed, built-in or hand-added.
final class AssistantCLITests: XCTestCase {

    // MARK: argv shapes

    func testArgvForEachOfTheFourBuiltInShapes() {
        let executable = URL(fileURLWithPath: "/usr/local/bin/thing")
        let claude = AssistantCLI(id: "claude", label: "Claude Code", executable: executable, argumentTemplate: "-p {prompt}", isCustom: false)
        let codex = AssistantCLI(id: "codex", label: "Codex", executable: executable, argumentTemplate: "exec {prompt}", isCustom: false)
        let cursor = AssistantCLI(id: "cursor-agent", label: "Cursor", executable: executable, argumentTemplate: "-p --output-format text {prompt}", isCustom: false)
        let opencode = AssistantCLI(id: "opencode", label: "opencode", executable: executable, argumentTemplate: "run {prompt}", isCustom: false)

        XCTAssertEqual(claude.arguments(for: "olá"), ["-p", "olá"])
        XCTAssertEqual(codex.arguments(for: "olá"), ["exec", "olá"])
        XCTAssertEqual(cursor.arguments(for: "olá"), ["-p", "--output-format", "text", "olá"])
        XCTAssertEqual(opencode.arguments(for: "olá"), ["run", "olá"])
    }

    func testThePromptBecomesExactlyOneArgumentEvenWithQuotesAndASemicolon() {
        let cli = AssistantCLI(
            id: "custom", label: "Custom", executable: URL(fileURLWithPath: "/bin/thing"),
            argumentTemplate: "run {prompt}", isCustom: true
        )
        let dangerous = #"say "hi"; rm -rf / && echo pwned"#

        let argv = cli.arguments(for: dangerous)

        XCTAssertEqual(argv, ["run", dangerous], "o prompt inteiro é um só argv, nunca reinterpretado")
        XCTAssertEqual(argv.count, 2)
    }

    // MARK: validation

    func testTemplateWithNoPlaceholderIsRejected() throws {
        let executable = makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }

        XCTAssertThrowsError(
            try AssistantCLIValidation.validate(name: "Thing", path: executable.path, template: "run")
        ) {
            guard case LoadoutError.invalidAssistantCLI = $0 else { return XCTFail("erro errado: \($0)") }
        }
    }

    func testTemplateWithTwoPlaceholdersIsRejected() throws {
        let executable = makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }

        XCTAssertThrowsError(
            try AssistantCLIValidation.validate(
                name: "Thing", path: executable.path, template: "{prompt} run {prompt}"
            )
        ) {
            guard case LoadoutError.invalidAssistantCLI = $0 else { return XCTFail("erro errado: \($0)") }
        }
    }

    func testAnEntryPointingAtANonExecutablePathIsRejected() {
        XCTAssertThrowsError(
            try AssistantCLIValidation.validate(name: "Thing", path: "/nao/existe/nada", template: "run {prompt}")
        ) {
            guard case LoadoutError.invalidAssistantCLI = $0 else { return XCTFail("erro errado: \($0)") }
        }
    }

    func testAnEmptyNameIsRejected() throws {
        let executable = makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }

        XCTAssertThrowsError(
            try AssistantCLIValidation.validate(name: "   ", path: executable.path, template: "run {prompt}")
        ) {
            guard case LoadoutError.invalidAssistantCLI = $0 else { return XCTFail("erro errado: \($0)") }
        }
    }

    func testAValidEntryPasses() throws {
        let executable = makeExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }

        XCTAssertNoThrow(
            try AssistantCLIValidation.validate(name: "Thing", path: executable.path, template: "run {prompt}")
        )
    }

    // MARK: round-trip

    func testCustomEntriesRoundTripThroughTheDefaultsEncoding() {
        let defaults = UserDefaults(suiteName: "loadout-tests-\(UUID().uuidString)")!
        let entries = [
            CustomAssistantCLI(id: "gemini", label: "Gemini", executablePath: "/usr/local/bin/gemini", argumentTemplate: "-p {prompt}"),
            CustomAssistantCLI(id: "aider", label: "Aider", executablePath: "/opt/homebrew/bin/aider", argumentTemplate: "--message {prompt}"),
        ]

        CustomAssistantCLIStore.save(entries, defaults: defaults)
        let loaded = CustomAssistantCLIStore.load(defaults: defaults)

        XCTAssertEqual(loaded, entries)
    }

    func testLoadingWithNothingSavedYieldsAnEmptyList() {
        let defaults = UserDefaults(suiteName: "loadout-tests-\(UUID().uuidString)")!
        XCTAssertEqual(CustomAssistantCLIStore.load(defaults: defaults), [])
    }

    // MARK: discovery

    func testDiscoveryReturnsOnlyBuiltInsThatAreActuallyFound() throws {
        let claudeScript = makeExecutable(name: "claude")
        defer { try? FileManager.default.removeItem(at: claudeScript) }

        let found = AssistantCLIRegistry.discover(customEntries: []) { name in
            name == "claude" ? claudeScript : nil
        }

        XCTAssertEqual(found.map(\.id), ["claude"], "só o que existe aparece")
    }

    func testDiscoveryIncludesCustomEntriesWhoseExecutableExists() throws {
        let script = makeExecutable(name: "mine")
        defer { try? FileManager.default.removeItem(at: script) }
        let custom = CustomAssistantCLI(id: "mine", label: "Mine", executablePath: script.path, argumentTemplate: "run {prompt}")

        let found = AssistantCLIRegistry.discover(customEntries: [custom]) { _ in nil }

        XCTAssertEqual(found.map(\.id), ["mine"])
    }

    func testDiscoverySkipsACustomEntryWhoseExecutableIsGone() {
        let custom = CustomAssistantCLI(id: "ghost", label: "Ghost", executablePath: "/nao/existe/nada", argumentTemplate: "run {prompt}")

        let found = AssistantCLIRegistry.discover(customEntries: [custom]) { _ in nil }

        XCTAssertTrue(found.isEmpty)
    }

    func testACustomEntrySharingABuiltInsIDWinsOverTheBuiltIn() throws {
        let builtinScript = makeExecutable(name: "claude-builtin")
        let customScript = makeExecutable(name: "claude-custom")
        defer {
            try? FileManager.default.removeItem(at: builtinScript)
            try? FileManager.default.removeItem(at: customScript)
        }
        let custom = CustomAssistantCLI(
            id: "claude", label: "My Claude", executablePath: customScript.path, argumentTemplate: "chat {prompt}"
        )

        let found = AssistantCLIRegistry.discover(customEntries: [custom]) { name in
            name == "claude" ? builtinScript : nil
        }

        XCTAssertEqual(found.count, 1, "não aparece duplicado")
        let winner = try XCTUnwrap(found.first)
        XCTAssertTrue(winner.isCustom, "o custom ganha ao built-in com o mesmo id")
        XCTAssertEqual(winner.executable, customScript)
        XCTAssertEqual(winner.label, "My Claude")
    }

    // MARK: helpers

    @discardableResult
    private func makeExecutable(name: String = "fake") -> URL {
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loadout-cli-\(name)-\(UUID().uuidString).sh")
        try! "#!/bin/sh\necho ok\n".write(to: script, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
