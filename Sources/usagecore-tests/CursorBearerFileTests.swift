import Foundation
import UsageCore

final class CursorBearerFileTests: XCTestCase {

    func testReadsBearerFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-bearer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("token.txt").path
        try Data(" eyJ-test-bearer  ".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertEqual(CursorBearerFile.loadAccessToken(explicitPath: path), "eyJ-test-bearer")
        XCTAssertEqual(CursorSessionToken.loadAccessToken(bearerFilePath: path), "eyJ-test-bearer")
    }

    func testRejectsSealedCiphertextInFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-bearer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("token.txt").path
        try Data("cursor-safe-storage:v1:abc".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(CursorBearerFile.loadAccessToken(explicitPath: path))
    }
}