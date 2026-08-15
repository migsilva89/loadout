import Foundation

/// Runs whichever assistant CLI the "Ask" sheet points it at.
///
/// It never writes anything: the answer comes back as text and the user decides what to do
/// with it (AC7.3). Uses whatever subscription or login the CLI already has on the machine, so
/// there is no API key to store here.
public final class Copilot: @unchecked Sendable {
    public struct Result: Sendable {
        public var output: String
        public var exitCode: Int32
        public var timedOut: Bool
    }

    private var process: Process?
    private let lock = NSLock()

    public init() {}

    /// - Parameters:
    ///   - cli: which assistant to run. `nil` means none was found or chosen, and is reported
    ///     rather than silently doing nothing.
    ///   - prompt: what to ask.
    ///   - directory: the working directory, normally the skill's own folder.
    ///   - timeout: hard ceiling; the child is killed when it expires (AC7.4).
    public func run(
        cli: AssistantCLI?,
        prompt: String,
        in directory: URL,
        timeout: TimeInterval = 180
    ) throws -> Result {
        guard let cli else { throw LoadoutError.claudeNotFound }

        let task = Process()
        task.executableURL = cli.executable
        task.arguments = cli.arguments(for: prompt)
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
            throw LoadoutError.io("Couldn't run \(cli.label): \(error.localizedDescription)")
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
