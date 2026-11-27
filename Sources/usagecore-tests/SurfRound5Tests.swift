import Foundation
@testable import UsageCore

/// Regressions for the low-severity items deferred in bug-surf round 4, fixed in round 5.
final class SurfRound5Tests: XCTestCase {

    // MARK: - Shared widget mirror read path

    /// Writes a snapshot into `<root>/<uid>/` under a valid (sticky, world-writable) root.
    private func seededMirrorRoot() throws -> URL {
        let root = makeTempDir()
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o1777)], ofItemAtPath: root.path)
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        WidgetSnapshotPaths.writeSharedMirror(WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 50), todayTokens: 7,
                                                             todayCostUSD: nil, todayCostIsEstimated: false, rows: []))
        XCTAssertNotNil(SharedMirrorGate.readSnapshotJSON(), "fixture: valid root reads back")
        return root
    }

    /// A symlink standing in for the shared root must not redirect the reader.
    func testMirrorReadRejectsSymlinkedRoot() throws {
        let real = try seededMirrorRoot()
        let link = makeTempDir().appendingPathComponent("mirror-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        setenv("AIPET_SHARED_MIRROR_ROOT", link.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        XCTAssertNil(SharedMirrorGate.readSnapshotJSON())
    }

    /// A root that fails the sticky / world-writable policy is not trusted for reads either.
    func testMirrorReadRejectsRootFailingPolicy() throws {
        let root = try seededMirrorRoot()
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: root.path)
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        XCTAssertNil(SharedMirrorGate.readSnapshotJSON())
    }

    // MARK: - agy /usage window labels

    func testAgyUnknownWindowIsSkippedNotWeekly() {
        let json = Data(#"""
        {"command":{"data":{"groups":[{"name":"Gemini Models","buckets":[
          {"id":"g-daily","name":"Daily","window":"24h","remaining_fraction":0.1},
          {"id":"g-none","name":"Unlabelled","remaining_fraction":0.2},
          {"id":"g-week","name":"Weekly","window":"weekly","remaining_fraction":0.9}]}]}}}
        """#.utf8)
        let snap = AntigravityQuotaFetcher.fetch(now: date("2026-11-16T12:00:00Z"),
                                                 executableURL: URL(fileURLWithPath: "/fake/agy")) { _ in json }
        XCTAssertEqual(snap?.groups.first?.buckets.map(\.id), ["g-week"])
        let used = snap.flatMap { AntigravityQuotaFetcher.geminiModelsRateLimit(from: $0)?.secondary?.usedPercent } ?? -1
        XCTAssertEqual(used, 10, accuracy: 0.01)
    }

    // MARK: - Cursor response without planUsage

    func testCursorNullBillingEndIsSchemaBreaking() {
        let now = date("2026-11-16T12:00:00Z")
        func outcome(_ body: String) -> CursorQuotaOutcome {
            CursorQuotaEngine.parseResponse(statusCode: 200, data: Data(body.utf8), now: now)
        }
        XCTAssertEqual(outcome(#"{"billingCycleEnd":null}"#), .schemaBreaking)
        XCTAssertEqual(outcome(#"{"billing_cycle_end":"1796478977012"}"#), .noUsageData)
        XCTAssertEqual(outcome(#"{"billingCycleEnd":"1796478977012"}"#), .noUsageData)
        XCTAssertEqual(outcome(#"{}"#), .schemaBreaking)
    }
}
