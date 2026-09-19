import Foundation
import SQLite3

/// Antigravity CLI's conversations, under `~/.gemini/antigravity-cli/conversations`.
///
/// One SQLite database per conversation, and inside it a `steps` table whose rows are protobuf
/// blobs — the wire format Google uses everywhere, with no schema published for this one. What was
/// mapped on agy 1.2.7 by running it against a throwaway skill: each row's `metadata` column opens
/// with a timestamp (field 1), and a tool call carries its name and JSON arguments in field 4. A
/// skill activates through `view_file` on `…/skills/<name>/SKILL.md`, and agy labels that read
/// itself — `"toolAction":"Reading skill file"` — which is as explicit as a signal gets without a
/// skill tool. A plain `view_file` of the same path without that label still counts, as inferred.
///
/// The step blob is scanned as bytes, not parsed as a message: only two fields matter, and a
/// parser that understood every field would break the day Google renumbers one it never needed.
public struct AntigravityUsageSource: UsageSource {
    public let id = "antigravity"
    public let assistant = "antigravity"
    public let label = "Antigravity"
    public let parserVersion = 1
    public let isSupported = true

    let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    /// Every conversation database. A conversation still open in agy keeps its newest steps in a
    /// write-ahead log the CLI folds back into the file on close, so it is indexed then.
    public func historyFiles() -> [URL] {
        let root = paths.antigravityConversations
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.pathExtension == "db" }
    }

    public func events(in file: URL, since: Date) -> [UsageEvent] {
        let conversation = file.deletingPathExtension().lastPathComponent
        let project = Self.workspace(of: conversation, summaries: paths.antigravitySummaries)
        var factory = UsageEventFactory()
        var events: [UsageEvent] = []

        SQLiteReader.rows(in: file, sql: "SELECT metadata FROM steps ORDER BY idx;") { blob in
            guard let step = Self.step(in: blob), let date = step.timestamp, date >= since,
                  let call = step.toolCall, call.name == "view_file"
            else { return }
            for key in Self.activatedSkills(in: call.arguments) {
                events.append(factory.make(
                    assistant: "antigravity", kind: .skill, key: key, timestamp: date,
                    project: project, sessionID: conversation, sourceFile: file.path,
                    evidence: call.arguments.contains("Reading skill file") ? .explicit : .inferred
                ))
            }
        }
        return events
    }

    /// The skill a `view_file` pulled in, when its path is a skill's own `SKILL.md`. Built-in skills
    /// count too: they sit under `builtin/skills/<name>/SKILL.md`, the same shape.
    static func activatedSkills(in arguments: String) -> [String] {
        guard arguments.contains("SKILL.md") else { return [] }
        let range = NSRange(arguments.startIndex..., in: arguments)
        var seen = Set<String>()
        return skillPath.matches(in: arguments, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: arguments) else { return nil }
            let name = String(arguments[range])
            return seen.insert(name).inserted ? name : nil
        }
    }

    private static let skillPath = try! NSRegularExpression(
        pattern: "/skills/([A-Za-z0-9._-]+)/SKILL\\.md"
    )

    // MARK: The two fields of a step worth reading

    struct Step {
        var timestamp: Date?
        var toolCall: (name: String, arguments: String)?
    }

    /// `metadata`: field 1 is a `google.protobuf.Timestamp` of the step's creation; field 4, on a
    /// tool step, holds the call — its id (1), tool name (2) and JSON arguments (3).
    static func step(in blob: Data) -> Step? {
        var step = Step()
        for field in Protobuf.fields(in: blob) {
            switch (field.number, field.value) {
            case (1, .message(let stamp)):
                if case .varint(let seconds)? = Protobuf.fields(in: stamp).first(where: { $0.number == 1 })?.value {
                    step.timestamp = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
            case (4, .message(let call)):
                var name = ""
                var arguments = ""
                for inner in Protobuf.fields(in: call) {
                    guard case .message(let bytes) = inner.value,
                          let text = String(data: bytes, encoding: .utf8) else { continue }
                    if inner.number == 2 { name = text }
                    if inner.number == 3 { arguments = text }
                }
                step.toolCall = (name, arguments)
            default:
                break
            }
        }
        return step.timestamp == nil && step.toolCall == nil ? nil : step
    }

    /// The leaf of the conversation's workspace, from the summaries index; `?` when the
    /// conversation ran with no workspace at all, which is how agy records a bare `-p` run.
    static func workspace(of conversation: String, summaries: URL) -> String {
        var uri: String?
        SQLiteReader.rows(
            in: summaries,
            sql: "SELECT workspace_uris FROM conversation_summaries WHERE conversation_id = ?;",
            binding: conversation
        ) { data in
            guard let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return }
            uri = list.first
        }
        guard let uri, let url = URL(string: uri) else { return "?" }
        return projectName(fromCWD: url.path)
    }
}

/// Just enough of the protobuf wire format to walk one level of a message: field numbers, varints,
/// and length-delimited payloads. Fixed-width fields are skipped, never decoded.
enum Protobuf {
    enum Value {
        case varint(UInt64)
        case message(Data)
        case skipped
    }

    struct Field {
        let number: Int
        let value: Value
    }

    static func fields(in data: Data) -> [Field] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Field] = []

        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while index < bytes.count {
            guard let tag = varint() else { break }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = varint() else { return fields }
                fields.append(Field(number: number, value: .varint(value)))
            case 1:
                index += 8
                fields.append(Field(number: number, value: .skipped))
            case 2:
                guard let length = varint(), index + Int(length) <= bytes.count else { return fields }
                let payload = Data(bytes[index..<index + Int(length)])
                index += Int(length)
                fields.append(Field(number: number, value: .message(payload)))
            case 5:
                index += 4
                fields.append(Field(number: number, value: .skipped))
            default:
                // Groups and anything newer: the rest of the message can't be walked safely.
                return fields
            }
        }
        return fields
    }
}

/// Reads one column of blobs out of somebody else's SQLite file, read-only, and swallows every
/// failure: a database that is missing, locked or mid-write yields nothing rather than an error.
enum SQLiteReader {
    static func rows(in file: URL, sql: String, binding: String? = nil, _ body: (Data) -> Void) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        if let binding {
            sqlite3_bind_text(statement, 1, binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_blob(statement, 0) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 0))
            body(Data(bytes: pointer, count: length))
        }
    }
}
