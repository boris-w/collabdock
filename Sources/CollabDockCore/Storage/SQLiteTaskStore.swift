import Foundation
import SQLite3

public enum SQLiteStoreError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return CoreL10n.format("SQLite open failed: %@", msg)
        case .prepareFailed(let msg): return CoreL10n.format("SQLite prepare failed: %@", msg)
        case .stepFailed(let msg): return CoreL10n.format("SQLite execution failed: %@", msg)
        }
    }
}

/// 基于 macOS 内置 SQLite3 的任务状态机、游标与幂等去重存储（零第三方依赖，关联 REQ-002, TASK-006）
public actor SQLiteTaskStore {
    private final class ConnectionBox: @unchecked Sendable {
        let pointer: OpaquePointer?
        init(_ pointer: OpaquePointer?) {
            self.pointer = pointer
        }
        deinit {
            if let pointer {
                sqlite3_close(pointer)
            }
        }
    }

    private let dbPath: String
    private let connection: ConnectionBox
    private var db: OpaquePointer? { connection.pointer }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databasePath: String? = nil) throws {
        if let databasePath {
            self.dbPath = databasePath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            let dir = appSupport.appendingPathComponent("CollabDock", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.dbPath = dir.appendingPathComponent("collabdock.sqlite").path
        }

        var handle: OpaquePointer?
        if sqlite3_open(self.dbPath, &handle) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteStoreError.openFailed(msg)
        }
        self.connection = ConnectionBox(handle)
        try Self.bootstrapSchema(db: handle)
    }

    private static func bootstrapSchema(db: OpaquePointer?) throws {
        let sql = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS collaboration_items (
            id TEXT PRIMARY KEY,
            platform TEXT NOT NULL,
            status TEXT NOT NULL,
            updated_at REAL NOT NULL,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_cursors (
            platform TEXT PRIMARY KEY,
            cursor_value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS seen_events (
            dedupe_key TEXT PRIMARY KEY,
            item_id TEXT NOT NULL,
            first_seen_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS review_usage_runs (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            payload_json TEXT NOT NULL
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "schema init failed"
            sqlite3_free(errMsg)
            throw SQLiteStoreError.stepFailed(msg)
        }
    }

    public func loadAllItems() throws -> [CollaborationItem] {
        let sql = "SELECT payload_json FROM collaboration_items ORDER BY updated_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        var items: [CollaborationItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let json = String(cString: cStr)
                if let data = json.data(using: .utf8),
                   let item = try? decoder.decode(CollaborationItem.self, from: data) {
                    items.append(item)
                }
            }
        }
        return items
    }

    public func upsertItem(_ item: CollaborationItem) throws {
        let data = try encoder.encode(item)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let sql = """
        INSERT INTO collaboration_items (id, platform, status, updated_at, payload_json)
        VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(id) DO UPDATE SET
            platform = excluded.platform,
            status = excluded.status,
            updated_at = excluded.updated_at,
            payload_json = excluded.payload_json;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: item.id)
        bindText(stmt, index: 2, value: item.platform.rawValue)
        bindText(stmt, index: 3, value: item.status.rawValue)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        bindText(stmt, index: 5, value: json)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(lastErrorMessage())
        }
    }

    public func deleteItem(id: String) throws {
        let sql = "DELETE FROM collaboration_items WHERE id = ?1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(lastErrorMessage())
        }
    }

    public func hasSeen(dedupeKey: String) throws -> Bool {
        let sql = "SELECT 1 FROM seen_events WHERE dedupe_key = ?1 LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: dedupeKey)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    public func markSeen(dedupeKey: String, itemID: String) throws {
        let sql = """
        INSERT OR IGNORE INTO seen_events (dedupe_key, item_id, first_seen_at)
        VALUES (?1, ?2, ?3);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: dedupeKey)
        bindText(stmt, index: 2, value: itemID)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(lastErrorMessage())
        }
    }

    public func loadCursor(for platform: PlatformKind) throws -> SyncCursor? {
        let sql = "SELECT cursor_value, updated_at FROM sync_cursors WHERE platform = ?1 LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: platform.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        let val = String(cString: cStr)
        let ts = sqlite3_column_double(stmt, 1)
        return SyncCursor(value: val, updatedAt: Date(timeIntervalSince1970: ts))
    }

    public func saveCursor(_ cursor: SyncCursor, for platform: PlatformKind) throws {
        let sql = """
        INSERT INTO sync_cursors (platform, cursor_value, updated_at)
        VALUES (?1, ?2, ?3)
        ON CONFLICT(platform) DO UPDATE SET
            cursor_value = excluded.cursor_value,
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: platform.rawValue)
        bindText(stmt, index: 2, value: cursor.value)
        sqlite3_bind_double(stmt, 3, cursor.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(lastErrorMessage())
        }
    }

    // MARK: - 用量统计记录（review_usage_runs，关联 ITER-014）

    public func loadAllUsageRuns() throws -> [ReviewUsageRun] {
        let sql = "SELECT payload_json FROM review_usage_runs ORDER BY created_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        var runs: [ReviewUsageRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let json = String(cString: cStr)
                if let data = json.data(using: .utf8),
                   let run = try? decoder.decode(ReviewUsageRun.self, from: data) {
                    runs.append(run)
                }
            }
        }
        return runs
    }

    public func upsertUsageRun(_ run: ReviewUsageRun) throws {
        let data = try encoder.encode(run)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let sql = """
        INSERT INTO review_usage_runs (id, created_at, payload_json)
        VALUES (?1, ?2, ?3)
        ON CONFLICT(id) DO UPDATE SET
            created_at = excluded.created_at,
            payload_json = excluded.payload_json;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: run.id)
        sqlite3_bind_double(stmt, 2, run.createdAt.timeIntervalSince1970)
        bindText(stmt, index: 3, value: json)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(lastErrorMessage())
        }
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func lastErrorMessage() -> String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
    }
}
