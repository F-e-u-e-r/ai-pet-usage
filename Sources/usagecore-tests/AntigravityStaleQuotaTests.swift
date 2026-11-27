import Foundation
@testable import UsageCore

/// Regression: a persisted `antigravity-quota.json` must not be shown while the official fetch is off.
/// The opt-in toggle defaulted to off on upgrade, so `agy /usage` stopped running, yet the dashboard
/// kept loading the last snapshot and presenting it as a live official reading (frozen meter).
final class AntigravityStaleQuotaTests: XCTestCase {
    private func seededDataDir() throws -> URL {
        let dir = makeTempDir()
        let snapshot = AntigravityQuotaSnapshot(
            fetchedAt: date("2026-11-15T14:22:48Z"),
            groups: [AntigravityQuotaGroup(name: "Gemini Models", buckets: [
                AntigravityQuotaBucket(id: "gemini-5h", label: "Five Hour Limit Remaining", windowMinutes: 300,
                                       usedPercent: 0.26, remainingPercent: 99.74,
                                       resetsAt: date("2026-11-15T15:58:10Z"))])])
        AntigravityQuotaStore.save(snapshot, dataDir: dir)
        XCTAssertNotNil(AntigravityQuotaStore.load(dataDir: dir), "fixture snapshot must be on disk")
        return dir
    }

    private func dashboard(dataDir: URL, fetchEnabled: Bool) -> DashboardState {
        let adapter = AgyAdapter(brainRoots: [], conversationMetadataURLs: [],
                                 enableOfficialQuotaFetch: fetchEnabled, quotaFetcher: { nil })
        let coord = UsageCoordinator(dataDir: dataDir, adapters: [adapter])
        let sem = DispatchSemaphore(value: 0)
        var out: DashboardState?
        Task { out = await coord.dashboard(now: date("2026-11-16T02:30:00Z")); sem.signal() }
        sem.wait()
        return out!
    }

    func testPersistedSnapshotHiddenWhenOfficialFetchDisabled() throws {
        let dir = try seededDataDir()
        XCTAssertNil(dashboard(dataDir: dir, fetchEnabled: false).antigravityQuota,
                     "fetch off → last snapshot must not be presented as current")
    }

    func testPersistedSnapshotShownWhenOfficialFetchEnabled() throws {
        let dir = try seededDataDir()
        XCTAssertEqual(dashboard(dataDir: dir, fetchEnabled: true).antigravityQuota?.groups.first?.name,
                       "Gemini Models")
    }

    func testSetAntigravityOfficialQuotaEnabledTogglesSnapshotVisibility() throws {
        let dir = try seededDataDir()
        let coord = UsageCoordinator(dataDir: dir, adapters: [
            AgyAdapter(brainRoots: [], conversationMetadataURLs: [], enableOfficialQuotaFetch: false,
                       quotaFetcher: { nil })])
        let sem = DispatchSemaphore(value: 0)
        var before: AntigravityQuotaSnapshot?
        var after: AntigravityQuotaSnapshot?
        Task {
            before = await coord.dashboard().antigravityQuota
            await coord.setAntigravityOfficialQuotaEnabled(true)
            after = await coord.dashboard().antigravityQuota
            sem.signal()
        }
        sem.wait()
        XCTAssertNil(before)
        XCTAssertNotNil(after)
    }
    // MARK: - fetch enabled but failing: snapshot ages on disk

    private let now = date("2026-11-16T12:00:00Z")

    private func snapshot(fetchedAt: Date, fiveResets: Date?, weekResets: Date?) -> AntigravityQuotaSnapshot {
        AntigravityQuotaSnapshot(fetchedAt: fetchedAt, groups: [
            AntigravityQuotaGroup(name: "Gemini Models", buckets: [
                AntigravityQuotaBucket(id: "gemini-5h", label: "5h", windowMinutes: 300,
                                       usedPercent: 4, remainingPercent: 96, resetsAt: fiveResets),
                AntigravityQuotaBucket(id: "gemini-weekly", label: "w", windowMinutes: 10_080,
                                       usedPercent: 1.3, remainingPercent: 98.7, resetsAt: weekResets)])])
    }

    private func gemini(_ quota: AntigravityQuotaSnapshot) -> ProviderLimitState {
        let base = ProviderLimitState(providerId: "antigravity",
                                      fiveHour: LimitWindowState(windowMinutes: 300, confidence: .high),
                                      weekly: LimitWindowState(windowMinutes: 10_080, confidence: .high))
        return AntigravityQuotaDisplay.expandLimitStates([base], quota: quota, now: now)
            .first { $0.providerId == AntigravityQuotaDisplay.geminiId }!
    }

    func testFreshSnapshotIsLiveWithoutAgeLabel() {
        let st = gemini(snapshot(fetchedAt: now.addingTimeInterval(-60),
                                 fiveResets: now.addingTimeInterval(3600),
                                 weekResets: now.addingTimeInterval(86_400)))
        XCTAssertEqual(st.warning, .ok)
        XCTAssertEqual(st.fiveHour.usedPercent, 4)
        XCTAssertEqual(st.weekly.usedPercent, 1.3)
        XCTAssertNil(StatuslineAge.weeklyAsOfLabel(for: st, now: now))
    }

    func testSnapshotAtThresholdIsNotYetStale() {
        let st = gemini(snapshot(fetchedAt: now.addingTimeInterval(-StatuslineAge.labelThreshold),
                                 fiveResets: now.addingTimeInterval(3600),
                                 weekResets: now.addingTimeInterval(86_400)))
        XCTAssertEqual(st.warning, .ok)
    }

    func testOldSnapshotMarkedStaleAndLabelled() {
        let fetched = now.addingTimeInterval(-2 * 3600)
        let st = gemini(snapshot(fetchedAt: fetched, fiveResets: now.addingTimeInterval(3600),
                                 weekResets: now.addingTimeInterval(86_400)))
        XCTAssertEqual(st.warning, .stale, "fetch failing for 2h → not a live reading")
        XCTAssertEqual(st.weekly.usedPercent, 1.3, "weekly value kept, only flagged")
        XCTAssertEqual(st.weekly.observedAt, fetched)
        XCTAssertEqual(StatuslineAge.weeklyAsOfLabel(for: st, now: now), "as of 2h ago")
    }

    func testWindowsPastResetDropTheirOldValue() {
        let st = gemini(snapshot(fetchedAt: now.addingTimeInterval(-12 * 3600),
                                 fiveResets: now.addingTimeInterval(-6 * 3600),
                                 weekResets: now))
        XCTAssertNil(st.fiveHour.usedPercent, "5h window reset since the snapshot → value unknown")
        XCTAssertEqual(st.fiveHourOfficial, .expiredUnusable)
        XCTAssertNil(st.weekly.usedPercent, "reset exactly now counts as reset")
        XCTAssertEqual(st.weeklyOfficial, .expiredUnusable)
    }

    /// Dashboard panel (renders the raw snapshot, not the menu rows) must apply the same expiry rule.
    func testDashboardBucketSummaryDropsExpiredValue() {
        func bucket(resets: Date?) -> AntigravityQuotaBucket {
            AntigravityQuotaBucket(id: "g-5h", label: "5h", windowMinutes: 300,
                                   usedPercent: 4, remainingPercent: 96, resetsAt: resets)
        }
        XCTAssertEqual(AntigravityQuotaDisplay.bucketSummary(bucket(resets: now.addingTimeInterval(3600)),
                                                              fetchedAt: now.addingTimeInterval(-60), now: now),
                       "96% left · 1h 0m")
        XCTAssertEqual(AntigravityQuotaDisplay.bucketSummary(bucket(resets: now.addingTimeInterval(-6 * 3600)),
                                                              fetchedAt: now.addingTimeInterval(-12 * 3600), now: now),
                       "— · awaiting agy /usage refresh")
        XCTAssertEqual(AntigravityQuotaDisplay.bucketSummary(bucket(resets: nil),
                                                              fetchedAt: now.addingTimeInterval(-6 * 3600), now: now),
                       "— · awaiting agy /usage refresh")
    }

    func testFiveHourWithoutResetExpiresAfterItsWindow() {
        let st = gemini(snapshot(fetchedAt: now.addingTimeInterval(-6 * 3600), fiveResets: nil,
                                 weekResets: now.addingTimeInterval(86_400)))
        XCTAssertNil(st.fiveHour.usedPercent)
        XCTAssertEqual(st.weekly.usedPercent, 1.3)
    }
}
