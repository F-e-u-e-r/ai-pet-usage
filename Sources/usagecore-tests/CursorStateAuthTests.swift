import Foundation
import SQLite3
import UsageCore

/// Cursor quota: read session token from IDE state.vscdb without Keychain.
final class CursorStateAuthTests: XCTestCase {

    func testLoadAccessTokenFromItemTable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-state-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("state.vscdb").path
        try createStateDb(at: dbPath, token: "  eyJ-test-token  ")

        try withIsolatedQuotaAuth(dbPath: dbPath) {
            XCTAssertEqual(CursorStateAuth.loadAccessToken(), "eyJ-test-token")
            XCTAssertEqual(CursorSessionToken.loadAccessToken(bearerFilePath: nil), "eyJ-test-token")
        }
    }

    func testEncryptedAtRestTokenIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-state-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("state.vscdb").path
        try createStateDb(at: dbPath, token: "cursor-safe-storage:v1:YWJj")

        try withIsolatedQuotaAuth(dbPath: dbPath) {
            XCTAssertNil(CursorStateAuth.loadAccessToken())
            XCTAssertNil(CursorSessionToken.loadAccessToken())
        }
    }

    func testMissingKeyReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-state-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("state.vscdb").path
        try createStateDb(at: dbPath, token: nil)

        try withIsolatedQuotaAuth(dbPath: dbPath) {
            XCTAssertNil(CursorStateAuth.loadAccessToken())
        }
    }

    /// Avoid picking up the user's real bearer file / env while testing state.vscdb reads.
    private func withIsolatedQuotaAuth(dbPath: String, _ body: () -> Void) throws {
        let petDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aipet-auth-isolated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: petDir) }
        setenv("AIPET_DATA_DIR", petDir.path, 1)
        setenv("CURSOR_STATE_DB", dbPath, 1)
        unsetenv("CURSOR_ACCESS_TOKEN")
        unsetenv("CURSOR_DASHBOARD_BEARER_FILE")
        defer {
            unsetenv("AIPET_DATA_DIR")
            unsetenv("CURSOR_STATE_DB")
        }
        body()
    }

    private func createStateDb(at path: String, token: String?) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE, value TEXT)", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        guard let token else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "test", code: 3)
        }
        defer { sqlite3_finalize(stmt) }
        _ = token.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "test", code: 4) }
    }
}