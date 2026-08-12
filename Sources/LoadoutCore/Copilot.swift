import Foundation

/// Runs `claude -p` for the "Pedir ao Claude" sheet.
///
/// It never writes anything: the answer comes back as text and the user decides what to do
/// with it (AC7.3). Uses the Claude Code subscription already on the machine, so there is no
/// API key to store.
public final class Copilot: @unchecked Sendable {
    public struct Result: Sendable {
        public var output: String
        public var exitCode: Int32
        public var timedOut: Bool
    }

    private var process: Process?
    private let lock = NSLock()
    public let executable: URL?

    /// Finds the CLI on the machine.
    public init() {
        self.executable = Copilot.findClaude()
    }

    /// Uses exactly this binary — including `nil`, which means "there is none".
    /// Kept separate from `init()` so a missing CLI can never be papered over by autodetection.
    public init(executable: URL?) {
        self.executable = executable
    }

    public var isAvailable: Bool { executable != nil }

    /// Looks for the CLI the way a login shell would, plus the usual install locations.
    public static func findClaude() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/claude" }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// - Parameters:
    ///   - prompt: what to ask.
    ///   - directory: the working directory, normally the skill's own folder.
    ///   - timeout: hard ceiling; the child is killed when it expires (AC7.4).
    public func run(
        prompt: String,
        in directory: URL,
        timeout: TimeInterval = 180
    ) throws -> Result {
        guard let executable else { throw LoadoutError.claudeNotFound }

        let task = Process()
        task.executableURL = executable
        task.arguments = ["-p", prompt]
        task.currentDirectoryURL = directory
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        lock.lock()
        process = task
        lock.unlock()

        do {
            try task.run()
        } catch {
            throw LoadoutError.io("Couldn't run claude: \(error.localizedDescription)")
        }

        // Read while it runs, otherwise a chatty answer fills the pipe and deadlocks.
        let sink = OutputSink()
        let queue = DispatchQueue(label: "loadout.copilot.read")
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            sink.set(pipe.fileHandleForReading.readDataToEndOfFile())
            finished.signal()
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            task.terminate()
            _ = finished.wait(timeout: .now() + 5)
        }
        task.waitUntilExit()

        lock.lock()
        process = nil
        lock.unlock()

        return Result(
            output: String(data: sink.get(), encoding: .utf8) ?? "",
            exitCode: task.terminationStatus,
            timedOut: timedOut
        )
    }

    /// Hands the child's output from the reader queue back to the caller without sharing a var.
    private final class OutputSink: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Kills the running child, if any.
    public func cancel() {
        lock.lock()
        let running = process
        lock.unlock()
        running?.terminate()
    }
}
