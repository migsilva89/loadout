import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Counts how often each skill, command, agent and MCP server actually fired, by reading the session
/// histories of every assistant on the machine.
///
/// It knows nothing about any particular format: each one arrives as a `UsageSource`, and this class
/// orchestrates, stores and answers questions. There is over a gigabyte of history out there, so the
/// index is incremental: a file whose size and modification date are unchanged since the last pass,
/// under the same parser, is never reopened (AC6.2).
public final class UsageIndex: @unchecked Sendable {
    public struct Progress: Sendable {
        public var scanned: Int
        public var total: Int
        public var done: Bool
    }

    public let paths: Paths
    public let sources: [any UsageSource]

    /// The connection every read goes through.
    private var db: OpaquePointer?
    /// False when the file on disk predates the multi-assistant schema, or comes from a newer build
    /// than this one. Either way it is readable but never written: the next refresh rebuilds beside
    /// it and swaps only on success, so a half-migrated index is never something the UI can see.
    private var isCurrentSchema = false
    private var paseo: PaseoSurface
    private let lock = NSLock()

    /// Ninety days is the default window: the question worth answering is "do I still use this?"
    public static let defaultWindow: TimeInterval = 90 * 24 * 3600

    static let schemaVersion: Int32 = 2

    public convenience init(paths: Paths) throws {
        try self.init(paths: paths, sources: UsageIndex.liveSources(paths: paths))
    }

    /// Every source Loadout knows how to ask about, supported or not. The unsupported ones are here
    /// on purpose: a source nobody lists contributes a silent zero, and a silent zero reads exactly
    /// like "never used".
    public static func liveSources(paths: Paths) -> [any UsageSource] {
        [
            ClaudeUsageSource(paths: paths),
            CodexUsageSource(paths: paths),
            OpenCodeUsageSource(paths: paths),
            CursorUsageSource(paths: paths),
            PiUsageSource(paths: paths),
        ]
    }

    public init(paths: Paths, sources: [any UsageSource]) throws {
        self.paths = paths
        self.sources = sources
        self.paseo = PaseoSurface(paths: paths)

        try FileManager.default.createDirectory(
            at: paths.index.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // A build interrupted last time leaves this behind; it is derived data, so it goes.
        try? FileManager.default.removeItem(at: Self.asidePath(paths.index))

        guard sqlite3_open(paths.index.path, &db) == SQLITE_OK else {
            throw LoadoutError.io("Couldn't open the index at \(paths.index.path).")
        }
        try exec(db, "PRAGMA journal_mode=WAL;")

        switch Self.userVersion(db) {
        case Self.schemaVersion:
            isCurrentSchema = true
        case 0 where !Self.hasTable("events", db):
            // Nothing there yet, so there is nothing to protect: build the current schema in place.
            try Self.createSchema(db)
            isCurrentSchema = true
        default:
            // Either the old single-source schema or a file from a newer build. Read it, leave it be.
            isCurrentSchema = false
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Indexing

    /// Walks every source's history and brings the index up to date.
    ///
    /// - Parameter since: only events at or after this date are stored. Pass `.distantPast` for the
    ///   full history (AC6.3).
    @discardableResult
    public func refresh(
        since: Date = Date().addingTimeInterval(-UsageIndex.defaultWindow),
        cancelled: (() -> Bool)? = nil,
        progress: ((Progress) -> Void)? = nil
    ) -> Int {
        // Read fresh each pass: an agent Paseo started a minute ago should be attributed to it.
        paseo = PaseoSurface(paths: paths)

        let work = sources.filter(\.isSupported).flatMap { source in
            source.historyFiles().map { (source, $0) }
        }
        var scanned = 0
        progress?(Progress(scanned: 0, total: work.count, done: false))

        // The schema on disk is not this build's. Everything goes into a new file beside it, and the
        // old one keeps answering questions until the new one is complete.
        var aside: OpaquePointer?
        if !isCurrentSchema {
            aside = try? openAside()
            if aside == nil {
                progress?(Progress(scanned: 0, total: work.count, done: true))
                return 0
            }
        }
        let target = aside ?? db

        var interrupted = false
        for (source, file) in work {
            if cancelled?() == true { interrupted = true; break }
            scanned += 1
            // A single unreadable file must not stop the pass (AC6.6).
            indexFile(file, source: source, since: since, into: target)
            if scanned % 25 == 0 {
                progress?(Progress(scanned: scanned, total: work.count, done: false))
            }
        }

        if !interrupted { prune(before: since, in: target) }

        if let aside {
            if interrupted {
                discardAside(aside)
            } else {
                adoptAside(aside)
            }
        }
        progress?(Progress(scanned: scanned, total: work.count, done: true))
        return scanned
    }

    /// Returns the number of events stored, or -1 when the file was skipped as unchanged.
    @discardableResult
    func indexFile(
        _ url: URL, source: any UsageSource, since: Date, into target: OpaquePointer?
    ) -> Int {
        // `URL.resourceValues` caches, and a cached size would make a rewritten file look untouched
        // forever. `FileManager` reads the inode every time.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        if let previous = fileRecord(url.path, in: target),
           previous.size == size,
           abs(previous.mtime - mtime) < 0.001,
           previous.since <= since.timeIntervalSince1970,
           previous.source == source.id,
           previous.parserVersion == source.parserVersion {
            return -1
        }

        let events = source.events(in: url, since: since)

        lock.lock()
        defer { lock.unlock() }
        try? exec(target, "BEGIN IMMEDIATE;")
        deleteEvents(file: url.path, in: target)
        for event in events {
            insert(event, source: source.id, in: target)
        }
        upsertFile(
            path: url.path, source: source.id, parserVersion: source.parserVersion,
            size: size, mtime: mtime, since: since.timeIntervalSince1970, in: target
        )
        try? exec(target, "COMMIT;")
        return events.count
    }

    /// Narrowing the window has to actually narrow the counts.
    ///
    /// Widening re-reads, because a file's stored `since` no longer covers what was asked for. Going
    /// the other way reads nothing — every file is already indexed — so without this the index keeps
    /// events the window has just excluded, and "Last 30 days" quietly reports a year. The files'
    /// `since` moves with the events, so widening still re-reads afterwards.
    private func prune(before since: Date, in target: OpaquePointer?) {
        let cutoff = since.timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }

        for sql in [
            "DELETE FROM events WHERE ts < \(cutoff);",
            "UPDATE files SET since = \(cutoff) WHERE since < \(cutoff);",
        ] {
            try? exec(target, sql)
        }
    }

    // MARK: - Migration, built aside and swapped whole

    private static func asidePath(_ index: URL) -> URL {
        index.appendingPathExtension("migrating")
    }

    private func openAside() throws -> OpaquePointer? {
        let url = Self.asidePath(paths.index)
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { return nil }
        do {
            try exec(handle, "PRAGMA journal_mode=WAL;")
            try Self.createSchema(handle)
        } catch {
            sqlite3_close(handle)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return handle
    }

    /// Cancelled or failed: the previous index is still the good one.
    private func discardAside(_ handle: OpaquePointer?) {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: Self.asidePath(paths.index))
    }

    /// Complete: fold the WAL in, put the new file in place of the old one in a single filesystem
    /// operation, and only then start reading from it.
    private func adoptAside(_ handle: OpaquePointer?) {
        lock.lock()
        defer { lock.unlock() }

        try? exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);")
        sqlite3_close(handle)
        sqlite3_close(db)
        db = nil

        let aside = Self.asidePath(paths.index)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: paths.index.path + suffix)
            )
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: aside.path + suffix))
        }
        do {
            _ = try FileManager.default.replaceItemAt(paths.index, withItemAt: aside)
        } catch {
            // The old file is untouched, so reopening it below simply keeps the old counts.
            try? FileManager.default.removeItem(at: aside)
        }

        if sqlite3_open(paths.index.path, &db) == SQLITE_OK {
            try? exec(db, "PRAGMA journal_mode=WAL;")
            isCurrentSchema = Self.userVersion(db) == Self.schemaVersion
        }
    }

    // MARK: - Reading

    /// Usage for every key of a kind, ready to be joined onto the inventory.
    ///
    /// - Parameter assistants: which assistants count. `nil` means all of them. Filtering happens
    ///   here rather than at index time on purpose: unchecking an assistant in Settings must be
    ///   instant and perfectly reversible, and it must never destroy history (UIX-005).
    ///
    /// Takes the same lock the reindex writes under. Without it the lock bought nothing: a pass
    /// rewriting a file deletes that file's events and reinserts them inside one transaction, and a
    /// read landing in between saw the gap — an item that is used reporting itself unused, from a
    /// query that was working perfectly.
    public func usage(kind: ItemKind, assistants: Set<String>? = nil) -> [String: Usage] {
        lock.lock()
        defer { lock.unlock() }

        guard let clause = filter(assistants) else { return [:] }
        let sql = """
            SELECT key, COUNT(*), MAX(ts), COUNT(DISTINCT project)
            FROM events WHERE kind = ?\(clause.sql) GROUP BY key;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        bind(statement, [kind.rawValue] + clause.values)

        var result: [String: Usage] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            result[String(cString: raw)] = Usage(
                count: Int(sqlite3_column_int64(statement, 1)),
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                projectCount: Int(sqlite3_column_int64(statement, 3))
            )
        }
        return result
    }

    /// Which projects one item actually fired in, busiest first. `Usage.projectCount` can only say
    /// how many; the detail pane's rail asks which, and answers with names.
    public func projects(
        kind: ItemKind, key: String, assistants: Set<String>? = nil, limit: Int = 8
    ) -> [ProjectUsage] {
        lock.lock()
        defer { lock.unlock() }

        guard let clause = filter(assistants) else { return [] }
        let sql = """
            SELECT project, COUNT(*) FROM events
            WHERE kind = ? AND key = ?\(clause.sql)
            GROUP BY project ORDER BY COUNT(*) DESC, project ASC LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, [kind.rawValue, key] + clause.values)
        sqlite3_bind_int(statement, Int32(3 + clause.values.count), Int32(limit))

        var result: [ProjectUsage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            result.append(ProjectUsage(
                project: String(cString: raw), count: Int(sqlite3_column_int64(statement, 1))
            ))
        }
        return result
    }

    /// How many times one item fired, per assistant. The total says how much something is used;
    /// this says by whom, which is what turns a number into something a person can check.
    public func usageByAssistant(
        kind: ItemKind, key: String, assistants: Set<String>? = nil
    ) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }

        guard let clause = filter(assistants) else { return [:] }
        guard isCurrentSchema else {
            // The old schema knows no assistants, and everything in it came from Claude.
            return [:]
        }
        let sql = """
            SELECT assistant, COUNT(*) FROM events
            WHERE kind = ? AND key = ?\(clause.sql) GROUP BY assistant;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        bind(statement, [kind.rawValue, key] + clause.values)

        var result: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            result[String(cString: raw)] = Int(sqlite3_column_int64(statement, 1))
        }
        return result
    }

    /// Every recorded use of one item, newest first — what makes a count explainable instead of
    /// something the app merely asserts.
    public func occurrences(
        kind: ItemKind, key: String, assistants: Set<String>? = nil, limit: Int = 200
    ) -> [UsageOccurrence] {
        lock.lock()
        defer { lock.unlock() }

        guard isCurrentSchema, let clause = filter(assistants) else { return [] }
        let sql = """
            SELECT assistant, surface, ts, project, session_id, file, evidence FROM events
            WHERE kind = ? AND key = ?\(clause.sql)
            ORDER BY ts DESC LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, [kind.rawValue, key] + clause.values)
        sqlite3_bind_int(statement, Int32(3 + clause.values.count), Int32(limit))

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        var result: [UsageOccurrence] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(UsageOccurrence(
                assistant: text(0) ?? "?",
                surface: text(1),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                project: text(3) ?? "?",
                sessionID: text(4),
                sourceFile: text(5) ?? "",
                evidence: UsageEvidence(rawValue: text(6) ?? "") ?? .explicit
            ))
        }
        return result
    }

    /// One row per source for Settings › Usage, so an unchanged count is always explainable: either
    /// the assistant is not counted, or its history is missing, or its format cannot prove a use.
    public func sourceStatuses(includedAssistants: Set<String>? = nil) -> [UsageSourceStatus] {
        let counts = eventCountsByAssistant()
        return sources.map { source in
            var state = source.state()
            if case .included = state, let includedAssistants,
               !includedAssistants.contains(source.assistant) {
                state = .excluded
            }
            return UsageSourceStatus(
                sourceID: source.id, assistant: source.assistant, label: source.label, state: state,
                sessionCount: source.historyFiles().count,
                eventCount: counts[source.assistant] ?? 0
            )
        }
    }

    /// Attaches usage to a scanned inventory. Items never seen keep `Usage.none`, which is what
    /// makes "nunca usada" visible in the list.
    public func annotate(_ items: [Item], assistants: Set<String>? = nil) -> [Item] {
        var byKind: [ItemKind: [String: Usage]] = [:]
        for kind in ItemKind.allCases { byKind[kind] = usage(kind: kind, assistants: assistants) }
        return items.map { item in
            var copy = item
            copy.usage = byKind[item.kind]?[item.name] ?? .none
            return copy
        }
    }

    public var eventCount: Int { count("SELECT COUNT(*) FROM events;") }
    public var indexedFileCount: Int { count("SELECT COUNT(*) FROM files;") }

    private func eventCountsByAssistant() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        // The old schema has no assistant column, and everything in it came from Claude.
        let sql = isCurrentSchema
            ? "SELECT assistant, COUNT(*) FROM events GROUP BY assistant;"
            : "SELECT 'claude', COUNT(*) FROM events;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var result: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            result[String(cString: raw)] = Int(sqlite3_column_int64(statement, 1))
        }
        return result
    }

    /// The `AND assistant IN (…)` half of a query, or nil when the caller asked for nothing.
    ///
    /// On a pre-migration file there is no column to filter by, and everything in it is Claude's, so
    /// the whole file counts or none of it does.
    private func filter(_ assistants: Set<String>?) -> (sql: String, values: [String])? {
        guard let assistants else { return ("", []) }
        guard isCurrentSchema else {
            return assistants.contains("claude") ? ("", []) : nil
        }
        guard !assistants.isEmpty else { return nil }
        let names = assistants.sorted()
        let holes = Array(repeating: "?", count: names.count).joined(separator: ", ")
        return (" AND assistant IN (\(holes))", names)
    }

    // MARK: - Claude-only helpers kept for the existing tests and callers

    func transcriptFiles() -> [URL] { ClaudeUsageSource(paths: paths).historyFiles() }

    @discardableResult
    func indexFile(_ url: URL, since: Date) -> Int {
        indexFile(url, source: ClaudeUsageSource(paths: paths), since: since)
    }

    @discardableResult
    func indexFile(_ url: URL, source: any UsageSource, since: Date) -> Int {
        indexFile(url, source: source, since: since, into: db)
    }

    static func isoDate(_ string: String) -> Date? { Timestamp.iso(string) }

    // MARK: - SQLite plumbing

    private static func createSchema(_ handle: OpaquePointer?) throws {
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                parser_version INTEGER NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                since REAL NOT NULL
            );
            """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS events (
                event_id TEXT NOT NULL UNIQUE,
                file TEXT NOT NULL,
                source TEXT NOT NULL,
                assistant TEXT NOT NULL,
                surface TEXT,
                kind TEXT NOT NULL,
                key TEXT NOT NULL,
                ts REAL NOT NULL,
                project TEXT NOT NULL,
                session_id TEXT,
                evidence TEXT NOT NULL DEFAULT 'explicit'
            );
            """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS events_lookup ON events (kind, key);")
        try exec(handle, "CREATE INDEX IF NOT EXISTS events_file ON events (file);")
        try exec(handle, "CREATE INDEX IF NOT EXISTS events_assistant ON events (assistant);")
        try exec(handle, "PRAGMA user_version = \(schemaVersion);")
    }

    private static func userVersion(_ handle: OpaquePointer?) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    private static func hasTable(_ name: String, _ handle: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func exec(_ handle: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw LoadoutError.io("SQLite: \(message)")
        }
    }

    private func exec(_ handle: OpaquePointer?, _ sql: String) throws {
        try Self.exec(handle, sql)
    }

    private func bind(_ statement: OpaquePointer?, _ values: [String]) {
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, SQLITE_TRANSIENT)
        }
    }

    private func count(_ sql: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func fileRecord(
        _ path: String, in handle: OpaquePointer?
    ) -> (source: String, parserVersion: Int, size: Int64, mtime: Double, since: Double)? {
        var statement: OpaquePointer?
        let sql = "SELECT source, parser_version, size, mtime, since FROM files WHERE path = ?;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let source = sqlite3_column_text(statement, 0)
        else { return nil }
        return (
            String(cString: source),
            Int(sqlite3_column_int64(statement, 1)),
            sqlite3_column_int64(statement, 2),
            sqlite3_column_double(statement, 3),
            sqlite3_column_double(statement, 4)
        )
    }

    private func upsertFile(
        path: String, source: String, parserVersion: Int, size: Int64, mtime: Double, since: Double,
        in handle: OpaquePointer?
    ) {
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO files (path, source, parser_version, size, mtime, since)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET source = excluded.source,
                parser_version = excluded.parser_version, size = excluded.size,
                mtime = excluded.mtime, since = excluded.since;
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, Int64(parserVersion))
        sqlite3_bind_int64(statement, 4, size)
        sqlite3_bind_double(statement, 5, mtime)
        sqlite3_bind_double(statement, 6, since)
        sqlite3_step(statement)
    }

    private func deleteEvents(file: String, in handle: OpaquePointer?) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM events WHERE file = ?;", -1, &statement, nil)
            == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, file, -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
    }

    private func insert(_ event: UsageEvent, source: String, in handle: OpaquePointer?) {
        var statement: OpaquePointer?
        // OR IGNORE, not plain INSERT: identical input yields identical event ids, so a second pass
        // over the same session cannot inflate a count (REQ-007).
        let sql = """
            INSERT OR IGNORE INTO events
                (event_id, file, source, assistant, surface, kind, key, ts, project, session_id,
                 evidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        func text(_ column: Int32, _ value: String?) {
            if let value {
                sqlite3_bind_text(statement, column, value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, column)
            }
        }
        text(1, event.id)
        text(2, event.sourceFile)
        text(3, source)
        text(4, event.assistant)
        text(5, paseo.surface(for: event))
        text(6, event.kind.rawValue)
        text(7, event.key)
        sqlite3_bind_double(statement, 8, event.timestamp.timeIntervalSince1970)
        text(9, event.project)
        text(10, event.sessionID)
        text(11, event.evidence.rawValue)
        sqlite3_step(statement)
    }
}

/// One recorded use, with everything needed to prove it happened.
public struct UsageOccurrence: Sendable, Equatable {
    public var assistant: String
    public var surface: String?
    public var timestamp: Date
    public var project: String
    public var sessionID: String?
    public var sourceFile: String
    public var evidence: UsageEvidence

    public init(
        assistant: String, surface: String?, timestamp: Date, project: String, sessionID: String?,
        sourceFile: String, evidence: UsageEvidence
    ) {
        self.assistant = assistant
        self.surface = surface
        self.timestamp = timestamp
        self.project = project
        self.sessionID = sessionID
        self.sourceFile = sourceFile
        self.evidence = evidence
    }
}
