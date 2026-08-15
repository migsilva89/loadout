import Foundation
import SQLite3
@testable import LoadoutCore

/// Writes the index exactly as the single-source version of Loadout left it on disk: no
/// `user_version`, no `assistant`, no event identity. It exists so the migration can be tested
/// against the real thing rather than against an idea of it.
enum LegacyIndexWriter {
    static func write(at url: URL, key: String, kind: String = "skill") throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw LoadoutError.io("couldn't create the legacy index")
        }
        defer { sqlite3_close(db) }

        let statements = [
            """
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime REAL NOT NULL,
                since REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS events (
                file TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, ts REAL NOT NULL,
                project TEXT NOT NULL
            );
            """,
            """
            INSERT INTO events (file, kind, key, ts, project)
            VALUES ('/antigo.jsonl', '\(kind)', '\(key)', \(Date().timeIntervalSince1970), 'meu-repo');
            """,
            "INSERT INTO files (path, size, mtime, since) VALUES ('/antigo.jsonl', 1, 1, 0);",
        ]
        for sql in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw LoadoutError.io("legacy index: \(message)")
            }
        }
    }
}
