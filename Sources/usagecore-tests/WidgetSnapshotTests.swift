import Foundation
@testable import UsageCore

final class WidgetSnapshotTests: XCTestCase {
    func testBuilderIncludesColabCreditRowWhenEnabled() {
        let now = Date()
        let dash = DashboardState(
            generatedAt: now,
            snapshots: [],
            limitStates: [],
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
        let colab = ColabCreditsSnapshot(balanceUnits: 169.77, consumptionRatePerHour: 6.73,
                                         activeAssignments: 1, fetchedAt: now)
        let snap = WidgetSnapshotBuilder.build(
            dashboard: dash,
            limitStates: [],
            enabledProviders: [],
            colabCreditsEnabled: true,
            colabSnapshot: colab
        )
        XCTAssertEqual(snap.creditRows.count, 1)
        XCTAssertEqual(snap.creditRows[0].id, "colab")
        XCTAssertEqual(snap.creditRows[0].primary, "169.77CU")
        XCTAssertEqual(snap.creditRows[0].secondary, "6.73/h")
        XCTAssertTrue(WidgetSnapshotStore.isPopulated(snap))
        let off = WidgetSnapshotBuilder.build(
            dashboard: dash, limitStates: [], enabledProviders: [],
            colabCreditsEnabled: false, colabSnapshot: colab)
        XCTAssertTrue(off.creditRows.isEmpty)
    }

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
                weekly: LimitWindowState(usedPercent: 30, windowMinutes: 10_080, confidence: .estimated)
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

        // 契約:Grok 只出 weekly 欄;5h 即使有值(10)也永不發佈。
        let grokOnly = WidgetSnapshotBuilder.build(
            dashboard: dash,
            limitStates: limits,
            enabledProviders: ["grok-code"]
        )
        XCTAssertEqual(grokOnly.rows.map { $0.providerId }, ["grok-code"])
        XCTAssertNil(grokOnly.rows.first?.fiveHourPercent)
        XCTAssertEqual(grokOnly.rows.first?.weeklyPercent, 30)
        XCTAssertEqual(grokOnly.rows.first?.weeklyEstimated, true)
        let codexRow = snap.rows.first { $0.providerId == "codex" }
        XCTAssertEqual(codexRow?.weeklyEstimated, false)
    }

    func testWidgetExtensionReadPrefersSupportBeforeShared() {
        let dir = makeTempDir()
        setenv("AIPET_DATA_DIR", dir.path, 1)
        defer { unsetenv("AIPET_DATA_DIR") }
        let root = makeTempDir()
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o1777)], ofItemAtPath: root.path)

        let support = WidgetSnapshotPaths.supportFileURL()
        let shared = WidgetSnapshotPaths.sharedFileURL()
        try? FileManager.default.createDirectory(at: shared.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: shared.deletingLastPathComponent().path)
        let inSupport = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 100),
                                       todayTokens: 1, todayCostUSD: nil, todayCostIsEstimated: false, rows: [])
        let inShared = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 200),
                                      todayTokens: 2, todayCostUSD: nil, todayCostIsEstimated: false, rows: [])
        try? AtomicJSON.write(inSupport, to: support)
        WidgetSnapshotPaths.writeSharedMirror(inShared)
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: shared)
        }

        let fromWidget = WidgetSnapshotStore.read(from: .widgetExtension)
        XCTAssertEqual(fromWidget?.todayTokens, 2, "sandboxed widget reads shared mirror before App Support")
        let fromDefault = WidgetSnapshotStore.read(from: .default)
        XCTAssertEqual(fromDefault?.todayTokens, 2)
    }

    func testBuilderIgnoresNonFinitePercents() {
        let now = Date()
        var bad = ProviderLimitState(
            providerId: "codex",
            fiveHour: LimitWindowState(usedPercent: 1, windowMinutes: 300, confidence: .high),
            weekly: LimitWindowState(usedPercent: 10, windowMinutes: 10_080, confidence: .high)
        )
        bad.fiveHour.usedPercent = .nan
        let dash = DashboardState(
            generatedAt: now, snapshots: [], limitStates: [bad], todayTotals: .zero, todayCost: .zero,
            todayByProvider: [], burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [], topProjects: [],
            models: [], dataQuality: [], lastRefreshAt: now)
        let snap = WidgetSnapshotBuilder.build(dashboard: dash, limitStates: [bad], enabledProviders: ["codex"])
        XCTAssertEqual(snap.rows.first?.fiveHourPercent, nil)
        XCTAssertEqual(snap.rows.first?.weeklyPercent, 10)
    }

    /// Regression (2026-11-19): with 7 other providers, the 8-row cap plus Cursor sorting last
    /// (api < auto by id) silently dropped "Cursor Auto". Every provider must reach the widget.
    func testBuilderKeepsBothCursorQuotaRowsAfterOtherProviders() {
        let now = Date()
        func st(_ id: String, _ five: Double?, _ week: Double) -> ProviderLimitState {
            ProviderLimitState(
                providerId: id,
                fiveHour: LimitWindowState(usedPercent: five, windowMinutes: 300, confidence: .high),
                weekly: LimitWindowState(usedPercent: week, windowMinutes: 10_080, confidence: .high))
        }
        let limits = [
            st("cursor-ide-api", nil, 61), st("cursor-ide-auto", nil, 12),
            st("codex", 7, 78), st("claude-code", 28, 94), st("claude-code-fable", nil, 41),
            st("antigravity-gemini", 78, 51), st("antigravity-claude-gpt", 0, 0),
            st("antigravity-argon", nil, 22), st("grok-code", nil, 100),
        ]
        let dash = DashboardState(
            generatedAt: now, snapshots: [], limitStates: limits, todayTotals: .zero, todayCost: .zero,
            todayByProvider: [], burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [], topProjects: [],
            models: [], dataQuality: [], lastRefreshAt: now)
        let snap = WidgetSnapshotBuilder.build(
            dashboard: dash, limitStates: limits,
            enabledProviders: ["codex", "claude-code", "antigravity", "grok-code", "cursor-ide"])
        XCTAssertEqual(snap.rows.map { $0.providerId }, [
            "codex", "claude-code", "claude-code-fable",
            "antigravity-gemini", "antigravity-claude-gpt", "antigravity-argon",
            "grok-code", "cursor-ide-auto", "cursor-ide-api",
        ])
        XCTAssertEqual(snap.rows.first { $0.providerId == "cursor-ide-auto" }?.shortName, "Cursor")
    }

    /// Review fix (sol3/grok8): an unknown provider with an empty display name must not render a blank row.
    func testUnknownProviderEmptyNameFallsBackToId() {
        XCTAssertEqual(WidgetProviderChrome.meta(for: "custom-x", displayName: "").shortName, "custom-x")
        XCTAssertEqual(WidgetProviderChrome.meta(for: "custom-x", displayName: "  ").shortName, "custom-x")
        XCTAssertEqual(WidgetProviderChrome.meta(for: "custom-x", displayName: "Foo").shortName, "Foo")
        XCTAssertEqual(WidgetProviderChrome.meta(for: "custom-x", displayName: "").code, "CU")
    }

    func testIsPopulatedRejectsEmptyPreviewShapedSnapshot() {
        let stale = WidgetSnapshot(generatedAt: .distantPast, todayTokens: 0, todayCostUSD: nil,
                                   todayCostIsEstimated: false, rows: [])
        XCTAssertFalse(WidgetSnapshotStore.isPopulated(stale))
    }

    func testOverrideMirrorRootIsNeverChmodded() throws {
        let root = makeTempDir()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        XCTAssertNil(SharedMirrorGate.prepareWriteContext(), "non-sticky override root must skip the mirror")
        let mode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700, "override root mode must not be changed to 1777")
    }

    func testSharedMirrorRejectsSymlinkedUIDDirectory() throws {
        let root = makeTempDir()
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o1777)], ofItemAtPath: root.path)
        let uidDir = root.appendingPathComponent("\(getuid())")
        try FileManager.default.createDirectory(at: uidDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: uidDir.path)
        let snap = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 50),
            todayTokens: 7,
            todayCostUSD: nil,
            todayCostIsEstimated: false,
            rows: [])
        WidgetSnapshotPaths.writeSharedMirror(snap)
        XCTAssertEqual(SharedMirrorGate.readSnapshotJSON().flatMap {
            try? AtomicJSON.decoder().decode(WidgetSnapshot.self, from: $0)
        }?.todayTokens, 7)
        try FileManager.default.removeItem(at: uidDir)
        let other = makeTempDir()
        try FileManager.default.createSymbolicLink(atPath: uidDir.path, withDestinationPath: other.path)
        XCTAssertNil(SharedMirrorGate.readSnapshotJSON())
        XCTAssertNil(SharedMirrorGate.prepareWriteContext())
    }

    func testReadPrefersNewestPopulatedSnapshotAcrossLocations() throws {
        let dir = makeTempDir()
        setenv("AIPET_DATA_DIR", dir.path, 1)
        defer { unsetenv("AIPET_DATA_DIR") }
        let root = makeTempDir()
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o1777)], ofItemAtPath: root.path)
        let support = WidgetSnapshotPaths.supportFileURL()
        let shared = WidgetSnapshotPaths.sharedFileURL()
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: shared.deletingLastPathComponent().path)
        let stale = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 10),
            todayTokens: 1, todayCostUSD: nil, todayCostIsEstimated: false, rows: [])
        let fresh = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 900),
            todayTokens: 9, todayCostUSD: nil, todayCostIsEstimated: false, rows: [])
        try? AtomicJSON.write(stale, to: support)
        WidgetSnapshotPaths.writeSharedMirror(fresh)
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: shared)
        }
        XCTAssertEqual(WidgetSnapshotStore.read(from: .default)?.todayTokens, 9)
    }

    func testReadNewestEmptySnapshotClearsStaleData() throws {
        let dir = makeTempDir()
        setenv("AIPET_DATA_DIR", dir.path, 1)
        defer { unsetenv("AIPET_DATA_DIR") }
        let root = makeTempDir()
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o1777)], ofItemAtPath: root.path)
        let support = WidgetSnapshotPaths.supportFileURL()
        let shared = WidgetSnapshotPaths.sharedFileURL()
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: shared.deletingLastPathComponent().path)
        let stale = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 10),
            todayTokens: 42, todayCostUSD: nil, todayCostIsEstimated: false, rows: [])
        let cleared = WidgetSnapshot.empty
        var freshCleared = cleared
        freshCleared.generatedAt = Date(timeIntervalSince1970: 900)
        try? AtomicJSON.write(stale, to: support)
        WidgetSnapshotPaths.writeSharedMirror(freshCleared)
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: shared)
        }
        let read = WidgetSnapshotStore.read(from: .default)
        XCTAssertEqual(read?.generatedAt, freshCleared.generatedAt)
        XCTAssertFalse(WidgetSnapshotStore.isPopulated(read ?? .empty))
    }

    func testStoreRoundTripInSupportPath() {
        let dir = makeTempDir()
        setenv("AIPET_DATA_DIR", dir.path, 1)
        defer { unsetenv("AIPET_DATA_DIR") }
        // write() also mirrors to the shared root — keep it off the real /Users/Shared mirror.
        let root = makeTempDir()
        setenv("AIPET_SHARED_MIRROR_ROOT", root.path, 1)
        defer { unsetenv("AIPET_SHARED_MIRROR_ROOT") }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o1777)], ofItemAtPath: root.path)

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

    func testWeeklyStaleLabelNilWhenNoAsOf() {
        let now = Date()
        let row = WidgetSnapshotRow(
            providerId: "claude-code",
            shortName: "Claude",
            code: "cc",
            dotColor: 0,
            fiveHourPercent: 10,
            weeklyPercent: 40,
            idle: false,
            weeklyAsOf: nil
        )
        XCTAssertNil(row.weeklyStaleLabel(now: now))
        XCTAssertFalse(row.isWeeklyStale(now: now))
    }

    func testWeeklyStaleLabelNilWhenNoWeeklyPercent() {
        let now = Date()
        let row = WidgetSnapshotRow(
            providerId: "claude-code",
            shortName: "Claude",
            code: "cc",
            dotColor: 0,
            fiveHourPercent: 10,
            weeklyPercent: nil,
            idle: false,
            weeklyAsOf: now.addingTimeInterval(-3600)
        )
        XCTAssertNil(row.weeklyStaleLabel(now: now))
        XCTAssertFalse(row.isWeeklyStale(now: now))
    }

    func testWeeklyStaleLabelTenHoursAgo() {
        let now = Date()
        let row = WidgetSnapshotRow(
            providerId: "claude-code",
            shortName: "Claude",
            code: "cc",
            dotColor: 0,
            fiveHourPercent: 10,
            weeklyPercent: 39,
            idle: false,
            weeklyAsOf: now.addingTimeInterval(-10 * 3600)
        )
        XCTAssertEqual(row.weeklyStaleLabel(now: now), "as of 10h ago")
        XCTAssertTrue(row.isWeeklyStale(now: now))
    }

    func testWeeklyStaleLabelFutureSkew() {
        let now = Date()
        let row = WidgetSnapshotRow(
            providerId: "claude-code",
            shortName: "Claude",
            code: "cc",
            dotColor: 0,
            fiveHourPercent: 10,
            weeklyPercent: 39,
            idle: false,
            weeklyAsOf: now.addingTimeInterval(5 * 60)
        )
        XCTAssertEqual(row.weeklyStaleLabel(now: now), "stale")
        XCTAssertTrue(row.isWeeklyStale(now: now))
    }

    func testWeeklyStaleLabelUnderThreshold() {
        let now = Date()
        let row = WidgetSnapshotRow(
            providerId: "claude-code",
            shortName: "Claude",
            code: "cc",
            dotColor: 0,
            fiveHourPercent: 10,
            weeklyPercent: 39,
            idle: false,
            weeklyAsOf: now.addingTimeInterval(-10 * 60)
        )
        XCTAssertNil(row.weeklyStaleLabel(now: now))
        XCTAssertFalse(row.isWeeklyStale(now: now))
    }

    func testWeeklyStaleLabelAgesAfterSnapshotBuild() {
        let builtAt = Date(timeIntervalSince1970: 1_000_000)
        let observed = builtAt.addingTimeInterval(-20 * 60)
        let row = WidgetSnapshotRow(
            providerId: "claude-code",
            shortName: "Claude",
            code: "cc",
            dotColor: 0,
            fiveHourPercent: 10,
            weeklyPercent: 39,
            idle: false,
            weeklyAsOf: observed
        )
        XCTAssertNil(row.weeklyStaleLabel(now: builtAt))
        let twoHoursLater = builtAt.addingTimeInterval(2 * 3600)
        XCTAssertEqual(row.weeklyStaleLabel(now: twoHoursLater), "as of 2h ago")
    }

    func testWidgetSnapshotRowWeeklyAsOfJSONRoundTrip() throws {
        let asOf = Date(timeIntervalSince1970: 1_700_000_000)
        let row = WidgetSnapshotRow(
            providerId: "claude-code",
            shortName: "Claude",
            code: "cc",
            dotColor: 0xFF0000,
            fiveHourPercent: 5,
            weeklyPercent: 39,
            idle: false,
            weeklyAsOf: asOf
        )
        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(WidgetSnapshotRow.self, from: data)
        XCTAssertEqual(decoded.weeklyAsOf, asOf)
        XCTAssertEqual(decoded.weeklyPercent, 39)
    }
}