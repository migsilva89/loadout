import XCTest
@testable import LoadoutCore

/// Running an assistant CLI from a Mac app, not from a shell.
///
/// A Finder-launched app inherits launchd's `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin` — and
/// nothing else. `codex` is a `#!/usr/bin/env node` script installed under nvm, so with that
/// `PATH` it never starts: `env` cannot find `node` and the run dies with exit code 127.
/// These tests reproduce that with a script CLI of their own, so no real assistant is invoked.
final class CopilotEnvironmentTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    /// What a Finder-launched app actually gets, and what these tests use as the base.
    private let launchdPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loadout-copilot-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - The interpreter has to be reachable

    func testAScriptCLIRunsWhenItsInterpreterOnlySitsBesideIt() throws {
        let cli = makeInterpretedCLI()

        let result = try Copilot().run(
            cli: cli, prompt: "hello", in: root, timeout: 30,
            environment: cli.environment(base: ["PATH": launchdPath], home: root)
        )

        XCTAssertEqual(result.exitCode, 0, "the interpreter has to be found: \(result.output)")
        XCTAssertTrue(result.output.contains("ok run hello"), "unexpected output: \(result.output)")
    }

    /// The bug itself: hand the child the bare `PATH` and it dies before parsing an argument.
    func testTheSameCLIDiesWithTheBarePathAFinderLaunchedAppInherits() throws {
        let cli = makeInterpretedCLI()

        let result = try Copilot().run(
            cli: cli, prompt: "hello", in: root, timeout: 30, environment: ["PATH": launchdPath]
        )

        XCTAssertEqual(result.exitCode, 127, "this is the failure mode the fix avoids")
        XCTAssertTrue(
            result.output.contains("No such file or directory"),
            "expected env's complaint: \(result.output)"
        )
    }

    func testTheExecutablesOwnDirectoryLeadsThePath() {
        let cli = AssistantCLI(
            id: "thing", label: "Thing", executable: root.appendingPathComponent("bin/thing"),
            argumentTemplate: "{prompt}", isCustom: true
        )

        let path = cli.environment(base: ["PATH": launchdPath], home: root)["PATH"] ?? ""

        XCTAssertEqual(
            path.split(separator: ":").first.map(String.init),
            root.appendingPathComponent("bin").path
        )
        XCTAssertTrue(path.contains("/usr/bin"), "what was already there is not lost")
    }

    func testThePathKeepsEachDirectoryOnlyOnce() {
        let cli = AssistantCLI(
            id: "thing", label: "Thing", executable: URL(fileURLWithPath: "/usr/local/bin/thing"),
            argumentTemplate: "{prompt}", isCustom: true
        )

        let path = cli.environment(
            base: ["PATH": "/usr/local/bin:/usr/bin:/bin"], home: root
        )["PATH"] ?? ""

        let directories = path.split(separator: ":").map(String.init)
        XCTAssertEqual(Set(directories).count, directories.count, "no duplicates: \(path)")
        XCTAssertEqual(directories.first, "/usr/local/bin")
    }

    func testEverythingElseInTheEnvironmentSurvives() {
        let cli = AssistantCLI(
            id: "thing", label: "Thing", executable: root.appendingPathComponent("bin/thing"),
            argumentTemplate: "{prompt}", isCustom: true
        )

        let environment = cli.environment(base: ["PATH": launchdPath, "HOME": root.path], home: root)

        XCTAssertEqual(environment["HOME"], root.path, "only PATH is widened")
    }

    // MARK: - Nothing is fed on stdin

    /// `codex exec` reads stdin whenever it is not a terminal and waits for EOF. Inheriting the
    /// app's stdin would hang the run until the timeout killed it.
    func testTheChildGetsNoStdin() throws {
        let script = root.appendingPathComponent("bin/reader")
        try "#!/bin/sh\ninput=$(cat)\necho \"stdin=[$input]\"\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cli = AssistantCLI(
            id: "reader", label: "Reader", executable: script,
            argumentTemplate: "{prompt}", isCustom: true
        )

        let result = try Copilot().run(
            cli: cli, prompt: "hello", in: root, timeout: 20, environment: ["PATH": launchdPath]
        )

        XCTAssertFalse(result.timedOut, "it read stdin and waited for an EOF that never came")
        XCTAssertTrue(result.output.contains("stdin=[]"), "unexpected output: \(result.output)")
    }

    // MARK: - Codex's own invocation

    /// `codex exec` refuses to start in a folder that is neither a git repository nor trusted in
    /// `~/.codex/config.toml`, which is what a skill folder normally is.
    func testTheCodexBuiltInSkipsTheGitRepositoryCheck() throws {
        let fake = root.appendingPathComponent("bin/codex")
        try "#!/bin/sh\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let found = AssistantCLIRegistry.discover(customEntries: []) { $0 == "codex" ? fake : nil }
        let codex = try XCTUnwrap(found.first { $0.id == "codex" })

        XCTAssertEqual(
            codex.arguments(for: "hello"), ["exec", "--skip-git-repo-check", "hello"],
            "the flag comes before the prompt, which is always the last argument"
        )
    }

    // MARK: - Helpers

    /// A CLI shaped like the real `codex`: a script whose `#!/usr/bin/env <interpreter>` line can
    /// only be resolved if the interpreter's directory is on `PATH`.
    private func makeInterpretedCLI() -> AssistantCLI {
        let bin = root.appendingPathComponent("bin")
        let interpreter = bin.appendingPathComponent("loadout-fake-node")
        try! "#!/bin/sh\nshift\necho \"ok $*\"\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreter.path)

        let script = bin.appendingPathComponent("faux-codex")
        try! "#!/usr/bin/env loadout-fake-node\n// never read by the fake interpreter\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        return AssistantCLI(
            id: "faux-codex", label: "Faux Codex", executable: script,
            argumentTemplate: "run {prompt}", isCustom: false
        )
    }
}
