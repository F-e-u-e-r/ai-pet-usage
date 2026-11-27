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

    func testAgyEpochResetTimeTreatedAsAbsentSoThirdPartyBucketsShow() {
        let json = Data(#"""
        {"command":{"data":{"groups":[{"name":"Claude and GPT models","buckets":[
          {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.88,"reset_time":"1970-01-01T00:00:00Z"},
          {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.95,"reset_time":"1970-01-01T00:00:00Z"}]}]}}}
        """#.utf8)
        let now = date("2026-11-27T12:00:00Z")
        let snap = AntigravityQuotaFetcher.fetch(now: now,
                                                 executableURL: URL(fileURLWithPath: "/fake/agy")) { _ in json }
        let bucket = snap?.groups.first?.buckets.first
        XCTAssertNil(bucket?.resetsAt)
        XCTAssertEqual(bucket?.usedPercent ?? -1, 12, accuracy: 0.01)
        let base = ProviderLimitState(providerId: "antigravity",
                                      fiveHour: LimitWindowState(windowMinutes: 300, confidence: .high),
                                      weekly: LimitWindowState(windowMinutes: 10_080, confidence: .high))
        let st = AntigravityQuotaDisplay.expandLimitStates([base], quota: snap, now: now)
            .first { $0.providerId == AntigravityQuotaDisplay.claudeGptId }
        XCTAssertNotNil(st)
        XCTAssertEqual(st?.fiveHour.usedPercent, 12)
        XCTAssertEqual(st?.weekly.usedPercent, 5)
    }

    func testPersistedSnapshotStripsEpochResetSoThirdPartyBucketsShow() throws {
        let dir = makeTempDir()
        let epoch = Date(timeIntervalSince1970: 0)
        let snap = AntigravityQuotaSnapshot(
            fetchedAt: date("2026-11-26T23:13:16Z"),
            groups: [AntigravityQuotaGroup(name: "Claude and GPT models", buckets: [
                AntigravityQuotaBucket(id: "3p-5h", label: "Five Hour Limit Remaining", windowMinutes: 300,
                                       usedPercent: 0, remainingPercent: 100, resetsAt: epoch),
                AntigravityQuotaBucket(id: "3p-weekly", label: "Weekly Limit Remaining", windowMinutes: 10_080,
                                       usedPercent: 0, remainingPercent: 100, resetsAt: epoch),
            ])])
        AntigravityQuotaStore.save(snap, dataDir: dir)
        let loaded = AntigravityQuotaStore.load(dataDir: dir)
        XCTAssertNil(loaded?.groups.first?.buckets.first?.resetsAt,
                     "on-disk epoch sentinel must normalize to absent reset")
        let fetched = loaded!.fetchedAt
        let now = fetched.addingTimeInterval(4 * 3600)
        let five = loaded!.groups[0].buckets[0]
        XCTAssertFalse(AntigravityQuotaDisplay.isExpired(five, fetchedAt: fetched, now: now),
                         "epoch on disk must not instantly expire the 5h third-party bucket")
        XCTAssertTrue(AntigravityQuotaDisplay.bucketSummary(five, fetchedAt: fetched, now: now)
            .hasPrefix("100% left"))
        let base = ProviderLimitState(providerId: "antigravity",
                                      fiveHour: LimitWindowState(windowMinutes: 300, confidence: .high),
                                      weekly: LimitWindowState(windowMinutes: 10_080, confidence: .high))
        let st = AntigravityQuotaDisplay.expandLimitStates([base], quota: loaded, now: now)
            .first { $0.providerId == AntigravityQuotaDisplay.claudeGptId }
        XCTAssertEqual(st?.fiveHour.usedPercent, 0)
        XCTAssertEqual(st?.fiveHourOfficial, .usable)
    }

    func testLiveAgyThirdPartyResetsNormalized() {
        guard let snap = AntigravityQuotaFetcher.fetch() else { return }
        let third = snap.groups.first { $0.name == "Claude and GPT models" }
        XCTAssertNotNil(third)
        for b in third?.buckets ?? [] {
            XCTAssertNil(b.resetsAt, "bucket \(b.id) resetsAt must be absent, not agy epoch sentinel")
        }
    }

    func testLiveAgySaveStripsEpochFromDisk() throws {
        guard let snap = AntigravityQuotaFetcher.fetch() else { return }
        let dir = makeTempDir()
        AntigravityQuotaStore.save(snap, dataDir: dir)
        let raw = try String(contentsOf: AntigravityQuotaStore.url(dataDir: dir), encoding: .utf8)
        XCTAssertFalse(raw.contains("1970"), raw)
    }

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
