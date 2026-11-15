import Foundation

// MARK: - macOS Notification Center widget payload

/// Lightweight, share-safe snapshot for the WidgetKit extension (App Group JSON).
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var todayTokens: Int
    public var todayCostUSD: Double?
    public var todayCostIsEstimated: Bool
    public var rows: [WidgetSnapshotRow]

    public init(
        generatedAt: Date,
        todayTokens: Int,
        todayCostUSD: Double?,
        todayCostIsEstimated: Bool,
        rows: [WidgetSnapshotRow]
    ) {
        self.generatedAt = generatedAt
        self.todayTokens = todayTokens
        self.todayCostUSD = todayCostUSD
        self.todayCostIsEstimated = todayCostIsEstimated
        self.rows = rows
    }

    public static let empty = WidgetSnapshot(
        generatedAt: .distantPast,
        todayTokens: 0,
        todayCostUSD: nil,
        todayCostIsEstimated: false,
        rows: []
    )
}

public struct WidgetSnapshotRow: Codable, Sendable, Equatable, Identifiable {
    public var providerId: String
    public var shortName: String
    public var code: String
    public var dotColor: UInt32
    public var fiveHourPercent: Int?
    public var weeklyPercent: Int?
    public var idle: Bool

    public var id: String { providerId }

    public init(
        providerId: String,
        shortName: String,
        code: String,
        dotColor: UInt32,
        fiveHourPercent: Int?,
        weeklyPercent: Int?,
        idle: Bool
    ) {
        self.providerId = providerId
        self.shortName = shortName
        self.code = code
        self.dotColor = dotColor
        self.fiveHourPercent = fiveHourPercent
        self.weeklyPercent = weeklyPercent
        self.idle = idle
    }
}

public enum WidgetSnapshotPaths {
    public static let appGroupID = "group.dev.aipetusage.app"
    public static let fileName = "widget-snapshot.json"

    public static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static func appGroupFileURL() -> URL? {
        appGroupContainerURL()?.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Mirror in Application Support (main app, diagnostics, CLI).
    public static func supportFileURL() -> URL {
        AppPaths.dataDirectory().appendingPathComponent(fileName, isDirectory: false)
    }

    /// Personal / ad-hoc builds: sandboxed widget can read this (see widget appex entitlements).
    public static func sharedFileURL() -> URL {
        URL(fileURLWithPath: "/Users/Shared/AIPetUsage/\(fileName)")
    }

    /// Best-effort `0644` so a sandboxed widget (or another user) can read the shared mirror.
    public static func makeWorldReadableIfPossible(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: url.path)
    }
}

public enum WidgetSnapshotStore {
    /// Set when the widget appex runs App Sandbox (typical gallery builds).
    static var widgetExtensionRunsInSandbox: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
    /// Write to App Support, `/Users/Shared/…`, and App Group (when the container exists).
    public static func write(_ snapshot: WidgetSnapshot) {
        let sharedDir = WidgetSnapshotPaths.sharedFileURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        var urls = [WidgetSnapshotPaths.supportFileURL(), WidgetSnapshotPaths.sharedFileURL()]
        if let group = WidgetSnapshotPaths.appGroupFileURL() { urls.append(group) }
        for url in urls {
            try? AtomicJSON.write(snapshot, to: url)
            WidgetSnapshotPaths.makeWorldReadableIfPossible(url)
        }
    }

    public static func read() -> WidgetSnapshot? {
        read(from: WidgetReadContext.default)
    }

    /// Sandbox widget extensions cannot see the host app's Application Support; personal (ad-hoc)
    /// builds are unsandboxed and should prefer the shared JSON next to the ledger.
    public enum WidgetReadContext {
        case `default`
        case widgetExtension

        fileprivate var candidateURLs: [URL] {
            switch self {
            case .default:
                var list: [URL] = []
                if let group = WidgetSnapshotPaths.appGroupFileURL() { list.append(group) }
                list.append(WidgetSnapshotPaths.sharedFileURL())
                list.append(WidgetSnapshotPaths.supportFileURL())
                return list
            case .widgetExtension:
                var list: [URL] = []
                if let group = WidgetSnapshotPaths.appGroupFileURL() { list.append(group) }
                list.append(WidgetSnapshotPaths.sharedFileURL())
                // Sandboxed appex: App Support resolves inside the extension container (not the host app).
                if !WidgetSnapshotStore.widgetExtensionRunsInSandbox {
                    list.append(WidgetSnapshotPaths.supportFileURL())
                }
                return list
            }
        }
    }

    public static func read(from context: WidgetReadContext) -> WidgetSnapshot? {
        for url in context.candidateURLs {
            if let snap = AtomicJSON.read(WidgetSnapshot.self, from: url) { return snap }
        }
        return nil
    }

    public static func isPopulated(_ snap: WidgetSnapshot) -> Bool {
        snap.generatedAt != .distantPast
    }
}

/// Rows for the macOS widget (Codex · Antigravity · Grok · OpenCode + Claude account).
public enum WidgetSnapshotBuilder {
    /// Provider chrome ids shown in the widget when data exists (excludes Cursor unless added later).
    public static let preferredProviderOrder: [String] = [
        "codex",
        "claude-code",
        "claude-code-fable",
        "antigravity-gemini",
        "antigravity-claude-gpt",
        "antigravity-argon",
        "grok-code",
        "opencode",
    ]

    public static func build(
        dashboard: DashboardState,
        limitStates: [ProviderLimitState],
        enabledProviders: Set<String>,
        maxRows: Int = 8
    ) -> WidgetSnapshot {
        let names = Dictionary(uniqueKeysWithValues:
            dashboard.snapshots.map { ($0.providerId, $0.displayName) })

        let states = limitStates.filter { st in
            let root = rootProviderId(st.providerId)
            return enabledProviders.contains(root) || enabledProviders.contains(st.providerId)
        }

        func intPercent(_ p: Double?) -> Int? {
            p.map { Int($0.rounded()) }
        }

        var rows: [WidgetSnapshotRow] = []
        for st in states {
            let display = names[st.providerId] ?? st.providerId
            let five = intPercent(st.fiveHour.usedPercent)
            let week = intPercent(st.weekly.usedPercent)
            let idle = st.fiveHour.idle && five == nil && week == nil
            if five == nil, week == nil, !idle { continue }
            let meta = WidgetProviderChrome.meta(for: st.providerId, displayName: display)
            rows.append(WidgetSnapshotRow(
                providerId: st.providerId,
                shortName: meta.shortName,
                code: meta.code,
                dotColor: meta.dotColor,
                fiveHourPercent: five,
                weeklyPercent: week,
                idle: idle
            ))
        }

        rows.sort { orderIndex(preferredProviderOrder, $0.providerId) < orderIndex(preferredProviderOrder, $1.providerId) }
        if rows.count > maxRows {
            rows = Array(rows.prefix(maxRows))
        }

        let cost = dashboard.todayCost
        return WidgetSnapshot(
            generatedAt: dashboard.generatedAt,
            todayTokens: dashboard.todayTotals.total,
            todayCostUSD: cost.knownUSD,
            todayCostIsEstimated: cost.isEstimated,
            rows: rows
        )
    }

    private static func rootProviderId(_ id: String) -> String {
        if id.hasPrefix("antigravity") { return "antigravity" }
        if id.hasPrefix("claude-code") { return "claude-code" }
        if id.hasPrefix("cursor-ide") { return "cursor-ide" }
        return id
    }

    private static func orderIndex(_ order: [String], _ id: String) -> Int {
        if let i = order.firstIndex(of: id) { return i }
        return order.count + id.hashValue
    }
}

/// Widget-local provider chrome (mirrors PetCore/ProviderBrand without a UsageCore → PetCore dependency).
enum WidgetProviderChrome {
    struct Meta {
        let shortName: String
        let code: String
        let dotColor: UInt32
    }

    static func meta(for providerId: String, displayName: String) -> Meta {
        switch providerId {
        case "codex":
            return Meta(shortName: "Codex", code: "CX", dotColor: 0x3B82F6)
        case "claude-code", "claude-code-fable":
            return Meta(shortName: "Claude", code: providerId == "claude-code-fable" ? "Fb" : "CC", dotColor: 0xE8823A)
        case "grok-code":
            return Meta(shortName: "Grok", code: "GK", dotColor: 0x2E3138)
        case "opencode":
            return Meta(shortName: "OpenCode", code: "OC", dotColor: 0xCA8A04)
        case "antigravity-gemini":
            return Meta(shortName: "Antigravity", code: "Gm", dotColor: 0x8B5CF6)
        case "antigravity-claude-gpt":
            return Meta(shortName: "Antigravity", code: "3P", dotColor: 0x8B5CF6)
        case "antigravity-argon":
            return Meta(shortName: "Antigravity", code: "Ar", dotColor: 0x8B5CF6)
        default:
            if providerId.hasPrefix("antigravity") {
                return Meta(shortName: "Antigravity", code: "AG", dotColor: 0x8B5CF6)
            }
            let code = String(displayName.prefix(2)).uppercased()
            return Meta(shortName: displayName, code: code.isEmpty ? "?" : code, dotColor: 0x9AA1AB)
        }
    }
}