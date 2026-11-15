import Foundation
@testable import UsageCore

final class WidgetSnapshotTests: XCTestCase {
    func testBuilderFiltersDisabledProviders() {
        let now = Date()
        let limits = [
            ProviderLimitState(
                providerId: "codex",
                fiveHour: LimitWindowState(usedPercent: 40, windowMinutes: 300, confidence: .high),
                weekly: LimitWindowState(usedPercent: 55, windowMinutes: 10_080, confidence: .high)
            ),
            ProviderLimitState(
                providerId: "grok-code",
                fiveHour: LimitWindowState(usedPercent: 10, windowMinutes: 300, confidence: .estimated),
                weekly: LimitWindowState(windowMinutes: 10_080, confidence: .unknown)
            ),
        ]
        let dash = DashboardState(
            generatedAt: now,
            snapshots: [],
            limitStates: limits,
            todayTotals: .zero,
            todayCost: .zero,
            todayByProvider: [],
            burnRateTokensPerHour: 0,
            burnCostPerHour: 0,
            hourly: [],
            topProjects: [],
            models: [],
            dataQuality: [],
            lastRefreshAt: now
        )
        let snap = WidgetSnapshotBuilder.build(
            dashboard: dash,
            limitStates: limits,
            enabledProviders: ["codex"]
        )
        XCTAssertEqual(snap.rows.map { $0.providerId }, ["codex"])
    }

    func testWidgetExtensionReadPrefersSupportBeforeShared() {
        let dir = makeTempDir()
        setenv("AIPET_DATA_DIR", dir.path, 1)
        defer { unsetenv("AIPET_DATA_DIR") }

        let support = WidgetSnapshotPaths.supportFileURL()
        let shared = WidgetSnapshotPaths.sharedFileURL()
        try? FileManager.default.createDirectory(at: shared.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let inSupport = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 100),
                                       todayTokens: 1, todayCostUSD: nil, todayCostIsEstimated: false, rows: [])
        let inShared = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 200),
                                      todayTokens: 2, todayCostUSD: nil, todayCostIsEstimated: false, rows: [])
        try? AtomicJSON.write(inSupport, to: support)
        try? AtomicJSON.write(inShared, to: shared)
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: shared)
        }

        let fromWidget = WidgetSnapshotStore.read(from: .widgetExtension)
        XCTAssertEqual(fromWidget?.todayTokens, 2, "sandboxed widget reads shared mirror before App Support")
        let fromDefault = WidgetSnapshotStore.read(from: .default)
        XCTAssertEqual(fromDefault?.todayTokens, 2)
    }

    func testStoreRoundTripInSupportPath() {
        let dir = makeTempDir()
        setenv("AIPET_DATA_DIR", dir.path, 1)
        defer { unsetenv("AIPET_DATA_DIR") }

        let snap = WidgetSnapshot(
            generatedAt: Date(),
            todayTokens: 99,
            todayCostUSD: 1.5,
            todayCostIsEstimated: true,
            rows: []
        )
        WidgetSnapshotStore.write(snap)
        let read = WidgetSnapshotStore.read()
        XCTAssertEqual(read?.todayTokens, 99)
        XCTAssertEqual(read?.todayCostUSD, 1.5)
    }
}