import Foundation
import SQLite3

enum MBTilesError: LocalizedError {
    case open(String)
    case sql(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "Could not open map file: \(m)"
        case .sql(let m): return "Map file error: \(m)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal reader/writer for the MBTiles format (a SQLite file of map tiles).
/// https://github.com/mapbox/mbtiles-spec — rows are stored in TMS order (y flipped).
final class MBTiles: @unchecked Sendable {
    let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()

    init(url: URL, create: Bool = false) throws {
        self.url = url
        let flags = (create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw MBTilesError.open(message)
        }
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        if create {
            try exec("""
                CREATE TABLE IF NOT EXISTS metadata (name TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE IF NOT EXISTS tiles (
                    zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB,
                    PRIMARY KEY (zoom_level, tile_column, tile_row));
                """)
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw MBTilesError.sql(message)
        }
    }

    func setMetadata(_ values: [String: String]) throws {
        lock.lock(); defer { lock.unlock() }
        for (name, value) in values {
            let stmt = try prepare("INSERT OR REPLACE INTO metadata (name, value) VALUES (?, ?)")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
        }
    }

    func tile(_ key: TileKey) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? prepare("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(key, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    func contains(_ key: TileKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? prepare("SELECT 1 FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?") else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(key, to: stmt)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func insert(_ key: TileKey, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("INSERT OR REPLACE INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(key, to: stmt)
        let rc = data.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 4, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
        }
        guard rc == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    func tileCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = try? prepare("SELECT COUNT(*) FROM tiles") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Folds the write-ahead log back into the main file (call when a download finishes).
    func checkpoint() {
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Private (caller holds `lock`)

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        return stmt
    }

    private func bind(_ key: TileKey, to stmt: OpaquePointer?) {
        let tmsRow = (1 << key.z) - 1 - key.y
        sqlite3_bind_int(stmt, 1, Int32(key.z))
        sqlite3_bind_int(stmt, 2, Int32(key.x))
        sqlite3_bind_int(stmt, 3, Int32(tmsRow))
    }

    private func lastError() -> MBTilesError {
        .sql(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }
}
