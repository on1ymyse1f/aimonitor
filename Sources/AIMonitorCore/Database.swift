import Foundation
import SQLite3

/// Minimal SQLite wrapper. No ORM, no dependencies beyond the system library.
/// WAL mode so the menu bar can read while a sync writes.
final class Database {
    enum DBError: Error, CustomStringConvertible {
        case open(String), exec(String), prepare(String), bind(String)
        var description: String {
            switch self {
            case .open(let m): return "sqlite open: \(m)"
            case .exec(let m): return "sqlite exec: \(m)"
            case .prepare(let m): return "sqlite prepare: \(m)"
            case .bind(let m): return "sqlite bind: \(m)"
            }
        }
    }

    private var db: OpaquePointer?

    init(path: String) throws {
        if !path.hasPrefix("file:") {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            throw DBError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA busy_timeout=3000")
    }

    /// In-memory, for tests.
    static func inMemory() throws -> Database { try Database(path: "file::memory:?cache=shared") }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw DBError.exec(String(cString: sqlite3_errmsg(db)) + " — " + sql)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.prepare(String(cString: sqlite3_errmsg(db)) + " — " + sql)
        }
        return Statement(stmt: stmt!, db: db!)
    }

    /// Multiple statements with rollback on any failure.
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var schemaVersion: Int {
        get {
            guard let stmt = try? prepare("PRAGMA user_version"),
                  let row = try? stmt.step(), row else { return 0 }
            return stmt.int(0)
        }
        set { try? exec("PRAGMA user_version=\(newValue)") }
    }

    final class Statement {
        private var stmt: OpaquePointer?
        private let db: OpaquePointer
        fileprivate init(stmt: OpaquePointer, db: OpaquePointer) { self.stmt = stmt; self.db = db }
        deinit { sqlite3_finalize(stmt) }

        @discardableResult
        func bind(_ v: String?, _ i: Int32) -> Bool {
            guard let stmt else { return false }
            if let v {
                return sqlite3_bind_text(stmt, i, (v as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
            }
            return sqlite3_bind_null(stmt, i) == SQLITE_OK
        }
        @discardableResult
        func bind(_ v: Int, _ i: Int32) -> Bool {
            guard let stmt else { return false }
            return sqlite3_bind_int64(stmt, i, sqlite3_int64(v)) == SQLITE_OK
        }
        @discardableResult
        func bind(_ v: Double?, _ i: Int32) -> Bool {
            guard let stmt else { return false }
            if let v { return sqlite3_bind_double(stmt, i, v) == SQLITE_OK }
            return sqlite3_bind_null(stmt, i) == SQLITE_OK
        }

        /// Steps. Returns true when a row is available.
        func step() throws -> Bool {
            guard let stmt else { return false }
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { return true }
            if rc == SQLITE_DONE { return false }
            throw DBError.exec(String(cString: sqlite3_errmsg(db)))
        }

        func reset() { sqlite3_reset(stmt) }

        func str(_ i: Int32) -> String? {
            guard let stmt, sqlite3_column_type(stmt, i) != SQLITE_NULL,
                  let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    }
}
