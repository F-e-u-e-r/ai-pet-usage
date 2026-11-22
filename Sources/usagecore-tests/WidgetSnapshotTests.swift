import Foundation
@testable import UsageCore

final class WidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func limit(
        _ providerId: String,
        fiveHour: Double?,
        weekly: Double?
    ) -> ProviderLimitState {
        ProviderLimitState(
            providerId: providerId,
            fiveHour: LimitWindowState(
                usedPercent: fiveHour,
                windowMinutes: 300,
                confidence: .high
            ),
            weekly: LimitWindowState(
                usedPercent: weekly,
                windowMinutes: 10_080,
                confidence: .high
            )
        )
    }

    private func dashboard(
        limits: [ProviderLimitState],
        snapshots: [UsageSnapshot] = [],
        cost: CostResult = .zero
    ) -> DashboardState {
        DashboardState(
            generatedAt: now,
            snapshots: snapshots,
            limitStates: limits,
            todayTotals: TokenBreakdown(input: 11, output: 2),
            todayCost: cost,
            todayByProvider: [],
            burnRateTokensPerHour: 0,
            burnCostPerHour: 0,
            hourly: [],
            topProjects: [],
            models: [],
            dataQuality: [],
            lastRefreshAt: now
        )
    }

    func testBuilderFiltersDisabledProviders() {
        let limits = [
            limit("codex", fiveHour: 40, weekly: 55),
            limit("grok-code", fiveHour: 10, weekly: 30),
            limit("codex-preview", fiveHour: 20, weekly: 25),
        ]
        let snapshot = WidgetSnapshotBuilder.build(
            dashboard: dashboard(limits: limits),
            limitStates: limits,
            enabledProviders: ["codex"]
        )

        XCTAssertEqual(snapshot.rows.map(\.providerId), ["codex"])
    }

    func testBuilderIgnoresNonFinitePercents() {
        var bad = limit("codex", fiveHour: 1, weekly: 10)
        bad.fiveHour.usedPercent = .nan
        let snapshot = WidgetSnapshotBuilder.build(
            dashboard: dashboard(limits: [bad]),
            limitStates: [bad],
            enabledProviders: ["codex"]
        )

        XCTAssertNil(snapshot.rows.first?.fiveHourPercent)
        XCTAssertEqual(snapshot.rows.first?.weeklyPercent, 10)
    }

    func testUnknownProviderEmptyNameFallsBackToId() {
        XCTAssertEqual(WidgetProviderChrome.meta(for: "custom-x", displayName: "").shortName, "custom-x")
        XCTAssertEqual(WidgetProviderChrome.meta(for: "custom-x", displayName: "  ").shortName, "custom-x")
        XCTAssertEqual(WidgetProviderChrome.meta(for: "custom-x", displayName: "Foo").shortName, "Foo")
        XCTAssertEqual(WidgetProviderChrome.meta(for: "custom-x", displayName: "").code, "CU")
    }

    func testWidgetSnapshotDayCheck() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let snapshot = WidgetSnapshot(
            generatedAt: date("2026-11-15T23:50:00Z"),
            todayTokens: 10_000,
            todayCostUSD: 1,
            todayCostIsEstimated: false,
            rows: []
        )

        XCTAssertTrue(snapshot.isFromSameDay(
            as: date("2026-11-15T23:59:00Z"),
            calendar: calendar
        ))
        XCTAssertFalse(snapshot.isFromSameDay(
            as: date("2026-11-16T00:01:00Z"),
            calendar: calendar
        ))
    }

    func testGrokCopiesBothWindows() {
        let state = limit("grok-code", fiveHour: 10, weekly: 30)
        let snapshot = WidgetSnapshotBuilder.build(
            dashboard: dashboard(limits: [state]),
            limitStates: [state],
            enabledProviders: ["grok-code"]
        )

        XCTAssertEqual(snapshot.rows.first?.fiveHourPercent, 10)
        XCTAssertEqual(snapshot.rows.first?.weeklyPercent, 30)
    }

    func testDuplicateProviderStatesKeepFirstRowBeforeCap() {
        let limits = [
            limit("codex", fiveHour: 40, weekly: 55),
            limit("codex", fiveHour: 90, weekly: 95),
            limit("claude-code", fiveHour: 10, weekly: 20),
        ]
        let snapshot = WidgetSnapshotBuilder.build(
            dashboard: dashboard(limits: limits),
            limitStates: limits,
            enabledProviders: ["codex", "claude-code"],
            maxRows: 2
        )

        XCTAssertEqual(snapshot.rows.map(\.providerId), ["codex", "claude-code"])
        XCTAssertEqual(snapshot.rows.first?.fiveHourPercent, 40)
    }

    func testPercentMatrixClampsAndRounds() {
        let cases: [(Double?, Int?)] = [
            (nil, nil),
            (.nan, nil),
            (.infinity, nil),
            (-.infinity, nil),
            (-1, 0),
            (0, 0),
            (49.5, 50),
            (101, 100),
        ]

        for (input, expected) in cases {
            var state = limit("codex", fiveHour: 1, weekly: 1)
            state.fiveHour.usedPercent = input
            let snapshot = WidgetSnapshotBuilder.build(
                dashboard: dashboard(limits: [state]),
                limitStates: [state],
                enabledProviders: ["codex"]
            )
            XCTAssertEqual(snapshot.rows.first?.fiveHourPercent, expected)
        }
    }

    func testProviderOrderAndRowCap() {
        let limits = [
            limit("opencode", fiveHour: 4, weekly: 40),
            limit("grok-code", fiveHour: 3, weekly: 30),
            limit("claude-code", fiveHour: 2, weekly: 20),
            limit("codex", fiveHour: 1, weekly: 10),
        ]
        let enabled = Set(limits.map(\.providerId))
        let expectedOrder = ["codex", "claude-code", "grok-code", "opencode"]
        let cases: [(Int, [String])] = [
            (-1, []),
            (0, []),
            (2, Array(expectedOrder.prefix(2))),
            (10, expectedOrder),
        ]

        for (cap, expected) in cases {
            let snapshot = WidgetSnapshotBuilder.build(
                dashboard: dashboard(limits: limits),
                limitStates: limits,
                enabledProviders: enabled,
                maxRows: cap
            )
            XCTAssertEqual(snapshot.rows.map(\.providerId), expected)
        }
    }

    func testCodableRoundTrip() throws {
        let original = WidgetSnapshot(
            generatedAt: now,
            todayTokens: 13,
            todayCostUSD: 2.5,
            todayCostIsEstimated: true,
            rows: [
                WidgetSnapshotRow(
                    providerId: "codex",
                    shortName: "Codex",
                    code: "CX",
                    dotColor: 0x3B82F6,
                    fiveHourPercent: 12,
                    weeklyPercent: 34,
                    idle: false
                ),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testBuilderSanitizesNonFiniteTodayCost() throws {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            let snapshot = WidgetSnapshotBuilder.build(
                dashboard: dashboard(
                    limits: [],
                    cost: CostResult(knownUSD: value, isEstimated: true)
                ),
                limitStates: [],
                enabledProviders: []
            )
            XCTAssertNil(snapshot.todayCostUSD)
            _ = try JSONEncoder().encode(snapshot)
        }

        let finite = WidgetSnapshotBuilder.build(
            dashboard: dashboard(
                limits: [],
                cost: CostResult(knownUSD: 12.5, isEstimated: false)
            ),
            limitStates: [],
            enabledProviders: []
        )
        XCTAssertEqual(finite.todayCostUSD, 12.5)
        _ = try JSONEncoder().encode(finite)
    }
}
