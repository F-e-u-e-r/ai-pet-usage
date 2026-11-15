import Foundation
import UsageCore

final class CursorQuotaTests: XCTestCase {
    private let now = date("2026-11-15T12:00:00Z")

    func testParseCurrentPeriodUsageJSON() {
        let body = """
        {"billingCycleStart":"1793886977012","billingCycleEnd":"1796478977012",
        "planUsage":{"autoPercentUsed":23.5,"apiPercentUsed":48.77}}
        """.data(using: .utf8)!
        let outcome = CursorQuotaEngine.parseResponse(statusCode: 200, data: body, now: now)
        guard case .success(let snap) = outcome else {
            XCTAssertEqual(String(describing: outcome), "success")
            return
        }
        XCTAssertEqual(snap.autoPercentUsed, 23.5, accuracy: 0.01)
        XCTAssertEqual(snap.apiPercentUsed, 48.77, accuracy: 0.01)
        XCTAssertNotNil(snap.billingCycleEnd)
    }

    func testExpandLimitStatesSplitsCursorIde() {
        let base = ProviderLimitState(
            providerId: "cursor-ide",
            fiveHour: LimitWindowState(windowMinutes: 300, confidence: .unknown),
            weekly: LimitWindowState(windowMinutes: 10_080, confidence: .unknown),
            burnRateTokensPerHour: 100,
            lastEventAt: now,
            lastReadingAt: now,
            warning: .ok)
        let quota = CursorQuotaSnapshot(autoPercentUsed: 10, apiPercentUsed: 20,
                                         billingCycleStart: now, billingCycleEnd: now.addingTimeInterval(86400 * 20),
                                         fetchedAt: now)
        let expanded = CursorQuotaDisplay.expandLimitStates([base], quota: quota)
        XCTAssertEqual(expanded.map { $0.providerId }, [CursorQuotaDisplay.autoId, CursorQuotaDisplay.apiId])
        XCTAssertEqual(expanded[0].weekly.usedPercent, 10)
        XCTAssertEqual(expanded[1].weekly.usedPercent, 20)
    }

    func testHTTP401MapsToKeyRejected() {
        XCTAssertEqual(CursorQuotaEngine.parseResponse(statusCode: 401, data: Data(), now: now), .keyRejected)
    }

    func testPartitionAndMenuSegmentsGroupCursorMeters() {
        let base = ProviderLimitState(
            providerId: "codex",
            fiveHour: LimitWindowState(windowMinutes: 300, confidence: .unknown),
            weekly: LimitWindowState(windowMinutes: 10_080, confidence: .unknown),
            burnRateTokensPerHour: 0,
            lastEventAt: nil,
            lastReadingAt: now,
            warning: .ok)
        let quota = CursorQuotaSnapshot(autoPercentUsed: 1, apiPercentUsed: 2,
                                         billingCycleStart: now, billingCycleEnd: now,
                                         fetchedAt: now)
        let expanded = CursorQuotaDisplay.expandLimitStates([base], quota: quota)
        let parts = ChromeMenuGrouping.partition(expanded)
        XCTAssertEqual(parts.cursor.count, 2)
        let segments = ChromeMenuGrouping.menuSegments(ChromeMenuGrouping.orderForMenu(expanded))
        XCTAssertTrue(segments.contains { seg in
            if case .cursorGroup(let g) = seg { return g.count == 2 }
            return false
        })
    }
}