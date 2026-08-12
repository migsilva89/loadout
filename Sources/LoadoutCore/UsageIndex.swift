import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Counts how often each skill, command, agent and MCP server actually fired, by reading the
/// session transcripts under `~/.claude/projects`.
///
/// There is over a gigabyte of JSONL there, so the index is incremental: a transcript whose
/// size and modification date are unchanged since the last pass is never reopened (AC6.2).
public final class UsageIndex: @unchecked Sendable {
    public struct Progress: Sendable {
        public var scanned: Int
        public var total: Int
        public var done: Bool
    }

    public let paths: Paths
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// Ninety days is the default window: the question worth answering is "do I still use this?"
    public static let defaultWindow: TimeInterval = 90 * 24 * 3600

    public init(paths: Paths) throws {
        self.paths = paths
        try FileManager.default.createDirectory(
            at: paths.index.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard sqlite3_open(paths.index.path, &db) == SQLITE_OK else {
            throw LoadoutError.io("Não consegui abrir o índice em \(paths.index.path).")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                since REAL NOT NULL
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS events (
                file TEXT NOT NULL,
                kind TEXT NOT NULL,
                key TEXT NOT NULL,
                ts REAL NOT NULL,
                project TEXT NOT NULL
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS events_lookup ON events (kind, key);")
        try exec("CREATE INDEX IF NOT EXISTS events_file ON events (file);")
    }

    deinit { sqlite3_close(db) }

    // MARK: - Indexing

    /// Walks the transcripts and brings the index up to date.
    /// - Parameter since: only events at or after this date are stored. Pass `.distantPast`
    ///   for the full history (AC6.3).
    @discardableResult
    public func refresh(
        since: Date = Date().addingTimeInterval(-UsageIndex.defaultWindow),
        cancelled: (() -> Bool)? = nil,
        progress: ((Progress) -> Void)? = nil
    ) -> Int {
        let files = transcriptFiles()
        var scanned = 0
        progress?(Progress(scanned: 0, total: files.count, done: false))

        for file in files {
            if cancelled?() == true { break }
            scanned += 1
            // A single unreadable transcript must not stop the pass (AC6.6).
            indexFile(file, since: since)
            if scanned % 25 == 0 {
                progress?(Progress(scanned: scanned, total: files.count, done: false))
            }
        }
        progress?(Progress(scanned: scanned, total: files.count, done: true))
        return scanned
    }

    func transcriptFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: paths.transcripts,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    /// Returns the number of events stored, or -1 when the file was skipped as unchanged.
    @discardableResult
    func indexFile(_ url: URL, since: Date) -> Int {
        // `URL.resourceValues` caches, and a cached size would make a rewritten transcript
        // look untouched forever. `FileManager` reads the inode every time.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        if let previous = fileRecord(url.path),
           previous.size == size,
           abs(previous.mtime - mtime) < 0.001,
           previous.since <= since.timeIntervalSince1970 {
            return -1
        }

        let events = Self.events(inTranscriptAt: url, since: since)

        lock.lock()
        defer { lock.unlock() }
        try? exec("BEGIN IMMEDIATE;")
        deleteEvents(file: url.path)
        for event in events {
            insert(event, file: url.path)
        }
        upsertFile(path: url.path, size: size, mtime: mtime, since: since.timeIntervalSince1970)
        try? exec("COMMIT;")
        return events.count
    }

    // MARK: - Reading

    /// Usage for every key of a kind, ready to be joined onto the inventory.
    public func usage(kind: ItemKind) -> [String: Usage] {
        let sql = """
            SELECT key, COUNT(*), MAX(ts), COUNT(DISTINCT project)
            FROM events WHERE kind = ? GROUP BY key;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, SQLITE_TRANSIENT)

        var result: [String: Usage] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: raw)
            result[key] = Usage(
                count: Int(sqlite3_column_int64(statement, 1)),
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                projectCount: Int(sqlite3_column_int64(statement, 3))
            )
        }
        return result
    }

    /// Attaches usage to a scanned inventory. Items never seen keep `Usage.none`, which is
    /// what makes "nunca usada" visible in the list.
    public func annotate(_ items: [Item]) -> [Item] {
        var byKind: [ItemKind: [String: Usage]] = [:]
        for kind in ItemKind.allCases { byKind[kind] = usage(kind: kind) }
        return items.map { item in
            var copy = item
            copy.usage = byKind[item.kind]?[item.name] ?? .none
            return copy
        }
    }

    public var eventCount: Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events;", -1, &statement, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    public var indexedFileCount: Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM files;", -1, &statement, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    // MARK: - Transcript parsing

    struct Event: Equatable {
        var kind: ItemKind
        var key: String
        var timestamp: Date
        var project: String
    }

    /// Pulls usage events out of one transcript. A malformed line is skipped, never fatal (AC6.6).
    static func events(inTranscriptAt url: URL, since: Date) -> [Event] {
        guard let handle = try? FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? handle.close() }

        var events: [Event] = []
        var pending = Data()
        let newline = UInt8(ascii: "\n")

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            while let index = pending.firstIndex(of: newline) {
                let line = pending[pending.startIndex..<index]
                pending = pending[pending.index(after: index)...]
                events += Self.events(inLine: line, since: since)
            }
        }
        if !pending.isEmpty {
            events += Self.events(inLine: pending, since: since)
        }
        return events
    }

    static func events(inLine line: Data, since: Date) -> [Event] {
        guard !line.isEmpty else { return [] }
        // Cheap prefilter: parsing every line as JSON would dominate the run.
        guard let hint = String(data: line.prefix(1 << 16), encoding: .utf8),
              hint.contains("Skill") || hint.contains("subagent_type")
                || hint.contains("mcp__") || hint.contains("<command-name>")
        else { return [] }

        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return []
        }
        guard let stamp = object["timestamp"] as? String,
              let date = isoDate(stamp), date >= since
        else { return [] }

        let project = (object["cwd"] as? String).map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "?"

        guard let message = object["message"] as? [String: Any] else { return [] }
        var events: [Event] = []

        // Slash commands arrive as plain text inside a user message.
        if let text = message["content"] as? String {
            events += commandEvents(in: text, date: date, project: project)
        }

        guard let content = message["content"] as? [[String: Any]] else { return events }
        for block in content {
            if let text = block["text"] as? String {
                events += commandEvents(in: text, date: date, project: project)
            }
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String
            else { continue }
            let input = block["input"] as? [String: Any] ?? [:]

            if name == "Skill", let skill = input["skill"] as? String {
                // Plugin skills are invoked as "plugin:skill"; count them under the bare name.
                events.append(Event(
                    kind: .skill, key: skill.components(separatedBy: ":").last ?? skill,
                    timestamp: date, project: project
                ))
            }
            if let agent = input["subagent_type"] as? String {
                events.append(Event(kind: .agent, key: agent, timestamp: date, project: project))
            }
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                if let server = parts.first, !server.isEmpty {
                    events.append(Event(kind: .mcp, key: server, timestamp: date, project: project))
                }
            }
        }
        return events
    }

    static func commandEvents(in text: String, date: Date, project: String) -> [Event] {
        guard text.contains("<command-name>") else { return [] }
        var events: [Event] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<command-name>"),
              let close = rest.range(of: "</command-name>", range: open.upperBound..<rest.endIndex) {
            let raw = rest[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            if !name.isEmpty {
                events.append(Event(
                    kind: .command,
                    key: name.components(separatedBy: ":").last ?? name,
                    timestamp: date,
                    project: project
                ))
            }
            rest = rest[close.upperBound...]
        }
        return events
    }

    /// Hand-rolled UTC ISO-8601 reader.
    ///
    /// `ISO8601DateFormatter` is neither `Sendable` nor cheap, and this runs once per candidate
    /// line across a gigabyte of transcripts — the arithmetic below is both safe to share and
    /// an order of magnitude faster.
    static func isoDate(_ string: String) -> Date? {
        let digits = Array(string.utf8)
        guard digits.count >= 19 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = digits[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }

        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              month >= 1, month <= 12, day >= 1, day <= 31
        else { return nil }

        var fraction = 0.0
        if digits.count > 20, digits[19] == UInt8(ascii: ".") {
            var index = 20
            var scale = 0.1
            while index < digits.count, digits[index] >= 48, digits[index] <= 57 {
                fraction += Double(digits[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }

        // Days from the civil calendar to the Unix epoch (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468

        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "erro desconhecido"
            sqlite3_free(error)
            throw LoadoutError.io("SQLite: \(message)")
        }
    }

    private func fileRecord(_ path: String) -> (size: Int64, mtime: Double, since: Double)? {
        var statement: OpaquePointer?
        let sql = "SELECT size, mtime, since FROM files WHERE path = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (
            sqlite3_column_int64(statement, 0),
            sqlite3_column_double(statement, 1),
            sqlite3_column_double(statement, 2)
        )
    }

    private func upsertFile(path: String, size: Int64, mtime: Double, since: Double) {
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO files (path, size, mtime, since) VALUES (?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET size = excluded.size,
                mtime = excluded.mtime, since = excluded.since;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, size)
        sqlite3_bind_double(statement, 3, mtime)
        sqlite3_bind_double(statement, 4, since)
        sqlite3_step(statement)
    }

    private func deleteEvents(file: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM events WHERE file = ?;", -1, &statement, nil)
            == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, file, -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
    }

    private func insert(_ event: Event, file: String) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO events (file, kind, key, ts, project) VALUES (?, ?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, file, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, event.kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, event.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 4, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 5, event.project, -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
    }
}
