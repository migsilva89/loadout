import Foundation
import Darwin

/// A short-lived local protocol connection. Codex parses and edits its own TOML; Loadout
/// never starts a conversation, runs a model, or supplies authentication credentials.
final class CodexConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private let deadline: Date

    init(paths: Paths, timeout: TimeInterval = 15) throws {
        guard let executable = paths.codexExecutable else {
            throw LoadoutError.io("Install or update Codex to read and manage its plugins.")
        }
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = executable
        process.arguments = ["app-server"]
        let cli = AssistantCLI(id: "codex", label: "Codex", executable: executable,
                               argumentTemplate: "", isCustom: false)
        var environment = cli.environment(base: ProcessInfo.processInfo.environment, home: paths.home)
        environment["CODEX_HOME"] = paths.codexHome.path
        process.environment = environment
        // Global means global, even when Loadout was launched from a repository.
        process.currentDirectoryURL = paths.home
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            _ = try call("initialize", [
                "clientInfo": ["name": "loadout", "version": "1"],
                "capabilities": ["experimentalApi": true],
            ])
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // A hung provider must not keep the app waiting on shutdown.
            let end = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < end { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["id"] as? Int == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw LoadoutError.io("Codex couldn't complete \(method): \(error["message"] as? String ?? "update Codex and try again").")
                }
                guard let result = object["result"] as? [String: Any] else {
                    throw LoadoutError.io("Codex returned an unsupported response. Update Codex and try again.")
                }
                return result
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw LoadoutError.io("Couldn't read Codex's plugin response.") }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw LoadoutError.io("Codex closed its plugin connection. Update Codex and try again.") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 16 * 1024 * 1024 else { throw LoadoutError.io("Codex's plugin response was too large.") }
        }
        throw LoadoutError.io("Codex took too long to respond. Try reloading the inventory.")
    }
}
