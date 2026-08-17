import Foundation

/// Runs an assistant CLI and hands back what it says while it is still saying it.
///
/// The one-shot `Copilot` waits for the child to exit and then shows everything at once, which is
/// why the Ask panel used to sit blank for up to three minutes. This reads the pipe line by line
/// and reports each line as it lands, so the answer appears as it is written.
public final class ChatRunner: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()

    public init() {}

    /// True while a child is running, so the panel can show Stop instead of Send.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Starts the CLI and calls `onEvent` for everything it reports, ending with `.finished`.
    ///
    /// - Parameters:
    ///   - cli: which assistant to run.
    ///   - chat: that assistant's conversation flags and output dialect.
    ///   - prompt: the message to send.
    ///   - session: the conversation to pick up, or `nil` to start a new one.
    ///   - directory: the working copy — never the real skill folder.
    ///   - timeout: hard ceiling, as the one-shot Ask has. Streaming makes a long run bearable
    ///     rather than acceptable: a child that has gone quiet still gets killed.
    ///   - onEvent: called off the main thread, once per event, in order.
    public func send(
        cli: AssistantCLI,
        chat: AssistantChat,
        prompt: String,
        resuming session: String?,
        briefing: String? = nil,
        model: String? = nil,
        in directory: URL,
        timeout: TimeInterval = 600,
        onEvent: @escaping @Sendable (ChatEvent) -> Void
    ) {
        let task = Process()
        task.executableURL = cli.executable
        task.arguments = chat.arguments(prompt: prompt, resuming: session, briefing: briefing, model: model)
        task.currentDirectoryURL = directory
        task.environment = cli.environment
        // Assistants that expect a terminal try to read stdin and hang waiting for it; a closed
        // stdin is what makes them get on with the prompt they were given on the command line.
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        // Kept apart from the answer. The CLIs write progress chatter here — codex announces that
        // it is reading stdin every single run — and putting that in the conversation makes noise
        // look like something the assistant said. It is held back and only shown if the run fails,
        // which is when it is the one thing you need to see.
        let errors = Pipe()
        task.standardError = errors

        lock.lock()
        process = task
        lock.unlock()

        do {
            try task.run()
        } catch {
            onEvent(.finished(error: "Couldn't run \(cli.label): \(error.localizedDescription)"))
            return
        }

        // Drained on its own thread rather than left to fill: a full error pipe blocks the child,
        // which would look like an assistant that had gone quiet.
        let collected = ErrorSink()
        DispatchQueue(label: "loadout.chat.errors").async {
            while true {
                let chunk = errors.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
        }

        let dialect = chat.dialect
        let reader = DispatchQueue(label: "loadout.chat.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            var buffer = Data()
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                // A JSON object per line, so a line is the unit that can be parsed. Anything after
                // the last newline is an unfinished line and waits for the next chunk.
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(data: buffer[buffer.startIndex..<newline], encoding: .utf8) ?? ""
                    buffer.removeSubrange(buffer.startIndex...newline)
                    for event in ChatEventParser.events(from: line, dialect: dialect) { onEvent(event) }
                }
            }
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                for event in ChatEventParser.events(from: line, dialect: dialect) { onEvent(event) }
            }
            done.signal()
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            task.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        task.waitUntilExit()

        lock.lock()
        let cancelled = wasCancelled
        wasCancelled = false
        process = nil
        lock.unlock()

        if timedOut {
            onEvent(.finished(error: "The assistant was still working after \(Int(timeout / 60)) minutes and was stopped."))
        } else if cancelled {
            onEvent(.finished(error: "Stopped."))
        } else if task.terminationStatus != 0 {
            // Now the chatter matters: it is usually the only thing that says why it failed.
            let reason = collected.text()
            onEvent(.finished(
                error: reason.isEmpty
                    ? "\(cli.label) exited with code \(task.terminationStatus)."
                    : "\(cli.label) failed: \(reason)"
            ))
        } else {
            onEvent(.finished(error: nil))
        }
    }

    /// Holds what the child wrote to its error channel until it is known whether it mattered.
    private final class ErrorSink: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            // A bound, so a CLI stuck printing warnings can't grow this without end.
            if data.count < 64_000 { data.append(chunk) }
            lock.unlock()
        }

        /// The last few lines, which is where a reason for failing actually is.
        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            let whole = String(data: data, encoding: .utf8) ?? ""
            let lines = whole.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lines.suffix(3).joined(separator: " ")
        }
    }

    private var wasCancelled = false

    /// The kill switch behind the panel's Stop button.
    public func cancel() {
        lock.lock()
        let running = process
        wasCancelled = running != nil
        lock.unlock()
        running?.terminate()
    }
}
