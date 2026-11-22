import Foundation
import SQLite3

// Cursor IDE session token from VS Code state store (state.vscdb ItemTable only).
// No logging of token values. WorkosCursorSessionToken / dashboard wiring lives elsewhere — parent integrates.

public enum CursorStateAuth {
    private static let accessTokenItemKey = "cursorAuth/accessToken"
    private static let maxTokenLength = 8192

    /// Reads `cursorAuth/accessToken` from Cursor's `state.vscdb` (read-only; authorizer deny-by-default).
    public static func loadAccessToken() -> String? {
        let source = stateDbURL()
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }

        if let token = readAccessToken(atDbPath: source.path) { return token }
        guard let copied = copyStateStoreToTemp(source: source) else { return nil }
        defer { try? FileManager.default.removeItem(at: copied.directory) }
        return readAccessToken(atDbPath: copied.dbPath)
    }

    private static func readAccessToken(atDbPath path: String) -> String? {
        switch queryAccessToken(dbPath: path) {
        case .token(let raw):
            return resolveStoredAccessToken(raw)
        case .busy, .failed:
            return nil
        }
    }

    /// Keychain-free: plaintext JWT only. Modern Cursor encrypts at rest (`cursor-safe-storage:v1:`) — not read here.
    private static let sealedAtRestPrefix = "cursor-safe-storage:v1:"

    private static func resolveStoredAccessToken(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix(sealedAtRestPrefix) { return nil }
        return validateToken(raw)
    }

    private static func stateDbURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CURSOR_STATE_DB"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private enum QueryOutcome {
        case token(String?)
        case busy
        case failed
    }

    private static func queryAccessToken(dbPath: String) -> QueryOutcome {
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openRC == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            return isBusy(openRC) ? .busy : .failed
        }
        defer { sqlite3_close_v2(db) }

        sqlite3_busy_timeout(db, 250)
        guard sqlite3_set_authorizer(db, cursorStateAuthorizerCallback, nil) == SQLITE_OK else {
            return .failed
        }

        let sql = "SELECT value FROM ItemTable WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failed
        }
        defer { sqlite3_finalize(stmt) }

        return accessTokenItemKey.withCString { keyPtr in
            guard sqlite3_bind_text(stmt, 1, keyPtr, -1, nil) == SQLITE_OK else { return .failed }
            let stepRC = sqlite3_step(stmt)
            switch stepRC {
            case SQLITE_ROW:
                let colType = sqlite3_column_type(stmt, 0)
                switch colType {
                case SQLITE_TEXT:
                    guard let valueC = sqlite3_column_text(stmt, 0) else { return .token(nil) }
                    return .token(String(cString: valueC))
                case SQLITE_BLOB:
                    guard let bytes = sqlite3_column_blob(stmt, 0) else { return .token(nil) }
                    let len = Int(sqlite3_column_bytes(stmt, 0))
                    guard len > 0 else { return .token(nil) }
                    return .token(String(data: Data(bytes: bytes, count: len), encoding: .utf8))
                default:
                    return .token(nil)
                }
            case SQLITE_DONE:
                return .token(nil)
            default:
                return isBusy(stepRC) ? .busy : .failed
            }
        }
    }

    private static func validateToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTokenLength else { return nil }
        return trimmed
    }

    private struct TempDbCopy {
        let directory: URL
        let dbPath: String
    }

    private static func copyStateStoreToTemp(source: URL) -> TempDbCopy? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cursor-state-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let baseName = source.lastPathComponent
            let destDb = dir.appendingPathComponent(baseName)
            try fm.copyItem(at: source, to: destDb)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                guard fm.fileExists(atPath: side.path) else { continue }
                try fm.copyItem(at: side, to: dir.appendingPathComponent(baseName + suffix))
            }
            return TempDbCopy(directory: dir, dbPath: destDb.path)
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    private static func isBusy(_ code: Int32) -> Bool {
        code == SQLITE_BUSY || code == SQLITE_LOCKED
    }
}

private let cursorStateAllowedItemColumns: Set<String> = ["key", "value"]

private let cursorStateAuthorizerCallback: @convention(c) (
    UnsafeMutableRawPointer?, Int32,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Int32 = { _, action, p1, p2, _, _ in
    switch action {
    case SQLITE_SELECT:
        return SQLITE_OK
    case SQLITE_READ:
        guard let tableC = p1 else { return SQLITE_DENY }
        let table = String(cString: tableC)
        if table == "ItemTable", let colC = p2, cursorStateAllowedItemColumns.contains(String(cString: colC)) {
            return SQLITE_OK
        }
        return SQLITE_DENY
    default:
        return SQLITE_DENY
    }
}