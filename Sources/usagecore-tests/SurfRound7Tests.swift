import Foundation
@testable import UsageCore

/// Bug-surf round 7 — Grok weekly estimated flag in widget payload (sol F1).
final class SurfRound7Tests: XCTestCase {

    /// Sticky `01777` root must be root-owned or owned by the current user (multi-user ACL hardening).
    func testMirrorRootStickyOwnedBySelf() throws {
        let root = makeTempDir()
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o1777)], ofItemAtPath: root.path)
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        XCTAssertNotNil(SharedMirrorGate.prepareWriteContext())
    }

    func testWidgetRowEncodesWeeklyEstimatedForGrok() throws {
        let row = WidgetSnapshotRow(
            providerId: "grok-code",
            shortName: "Grok",
            code: "Gk",
            dotColor: 0,
            fiveHourPercent: nil,
            weeklyPercent: 42,
            idle: false,
            weeklyEstimated: true
        )
        let data = try JSONEncoder().encode(row)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["weeklyEstimated"] as? Bool, true)
        let decoded = try JSONDecoder().decode(WidgetSnapshotRow.self, from: Data(#"{"providerId":"grok-code","shortName":"Grok","code":"Gk","dotColor":0,"idle":false,"weeklyPercent":42}"#.utf8))
        XCTAssertEqual(decoded.weeklyEstimated, false)
    }
}