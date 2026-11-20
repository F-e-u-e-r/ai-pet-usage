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
}