import Foundation

// MARK: - macOS Notification Center widget payload

/// Lightweight, share-safe snapshot for the WidgetKit extension (App Group JSON).
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var todayTokens: Int
    public var todayCostUSD: Double?
    public var todayCostIsEstimated: Bool
    public var rows: [WidgetSnapshotRow]
    /// Opt-in account credits (Colab compute units, etc.) — not 5h/wk limit meters.
    public var creditRows: [WidgetCreditRow]

    public init(
        generatedAt: Date,
        todayTokens: Int,
        todayCostUSD: Double?,
        todayCostIsEstimated: Bool,
        rows: [WidgetSnapshotRow],
        creditRows: [WidgetCreditRow] = []
    ) {
        self.generatedAt = generatedAt
        self.todayTokens = todayTokens
        self.todayCostUSD = todayCostUSD
        self.todayCostIsEstimated = todayCostIsEstimated
        self.rows = rows
        self.creditRows = creditRows
    }

    public static let empty = WidgetSnapshot(
        generatedAt: .distantPast,
        todayTokens: 0,
        todayCostUSD: nil,
        todayCostIsEstimated: false,
        rows: [],
        creditRows: []
    )

    /// Xcode / WidgetKit canvas placeholder (must live on the type — stored statics are illegal in extensions).
    public static let preview = WidgetSnapshot(
        generatedAt: Date(),
        todayTokens: 128_400,
        todayCostUSD: 2.14,
        todayCostIsEstimated: true,
        rows: [
            WidgetSnapshotRow(providerId: "codex", shortName: "Codex", code: "CX", dotColor: 0x3B82F6,
                              fiveHourPercent: 42, weeklyPercent: 61, idle: false),
            WidgetSnapshotRow(providerId: "grok-code", shortName: "Grok", code: "GK", dotColor: 0x2E3138,
                              fiveHourPercent: nil, weeklyPercent: 18, idle: false, hidesFiveHourMeter: true),
            WidgetSnapshotRow(providerId: "opencode", shortName: "OpenCode", code: "OC", dotColor: 0xCA8A04,
                              fiveHourPercent: nil, weeklyPercent: 33, idle: false),
        ]
    )

    private enum CodingKeys: String, CodingKey {
        case generatedAt, todayTokens, todayCostUSD, todayCostIsEstimated, rows, creditRows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        todayTokens = try c.decode(Int.self, forKey: .todayTokens)
        todayCostUSD = try c.decodeIfPresent(Double.self, forKey: .todayCostUSD)
        todayCostIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .todayCostIsEstimated) ?? false
        rows = try c.decode([WidgetSnapshotRow].self, forKey: .rows)
        creditRows = try c.decodeIfPresent([WidgetCreditRow].self, forKey: .creditRows) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(todayTokens, forKey: .todayTokens)
        try c.encodeIfPresent(todayCostUSD, forKey: .todayCostUSD)
        try c.encode(todayCostIsEstimated, forKey: .todayCostIsEstimated)
        try c.encode(rows, forKey: .rows)
        if !creditRows.isEmpty {
            try c.encode(creditRows, forKey: .creditRows)
        }
    }

    /// `todayTokens` / `todayCostUSD` describe the day the snapshot was generated; once the app stops
    /// publishing, a snapshot from an earlier day must not be rendered as "today".
    public func isFromSameDay(as now: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(generatedAt, inSameDayAs: now)
    }
}

public struct WidgetSnapshotRow: Codable, Sendable, Equatable, Identifiable {
    public var providerId: String
    public var shortName: String
    public var code: String
    public var dotColor: UInt32
    public var fiveHourPercent: Int?
    public var weeklyPercent: Int?
    public var idle: Bool
    /// 週窗讀數時間(Claude / Cursor / Antigravity 列);widget 在 render 時依 `now` 決定是否顯示「as of …」。
    public var weeklyAsOf: Date?
    /// Grok billing credits on the weekly column (`LimitWindowState.confidence == .estimated`).
    public var weeklyEstimated: Bool
    /// Publisher marks weekly/monthly-only chrome (Grok, Cursor plan, Argon); widget must not reserve a 5h column.
    public var hidesFiveHourMeter: Bool
    /// Window reset times (small widget "resets in …"); nil when the source gives none.
    public var fiveHourResetAt: Date?
    public var weeklyResetAt: Date?

    public var id: String { providerId }

    public init(
        providerId: String,
        shortName: String,
        code: String,
        dotColor: UInt32,
        fiveHourPercent: Int?,
        weeklyPercent: Int?,
        idle: Bool,
        weeklyAsOf: Date? = nil,
        weeklyEstimated: Bool = false,
        hidesFiveHourMeter: Bool = false,
        fiveHourResetAt: Date? = nil,
        weeklyResetAt: Date? = nil
    ) {
        self.providerId = providerId
        self.shortName = shortName
        self.code = code
        self.dotColor = dotColor
        self.fiveHourPercent = fiveHourPercent
        self.weeklyPercent = weeklyPercent
        self.idle = idle
        self.weeklyAsOf = weeklyAsOf
        self.weeklyEstimated = weeklyEstimated
        self.hidesFiveHourMeter = hidesFiveHourMeter
        self.fiveHourResetAt = fiveHourResetAt
        self.weeklyResetAt = weeklyResetAt
    }

    private enum CodingKeys: String, CodingKey {
        case providerId, shortName, code, dotColor, fiveHourPercent, weeklyPercent, idle, weeklyAsOf
        case weeklyEstimated, hidesFiveHourMeter, fiveHourResetAt, weeklyResetAt
    }

    /// Single week/month column in the widget (no 5h slot, no empty bar track).
    /// Only for weekly/monthly-only providers; a missing 5h value elsewhere keeps its "–" slot.
    public var widgetSinglePeriodColumn: Bool {
        hidesFiveHourMeter || LimitMeterChrome.skipsFiveHourMeter(providerId)
    }

    /// Spoken name of the weekly column: Cursor's plan quota is monthly, everything else weekly.
    public var periodWindowName: String {
        CursorChromeDisplay.usesMonthlyOnlyMeter(providerId) ? "month" : "week"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try c.decode(String.self, forKey: .providerId)
        shortName = try c.decode(String.self, forKey: .shortName)
        code = try c.decode(String.self, forKey: .code)
        dotColor = try c.decode(UInt32.self, forKey: .dotColor)
        fiveHourPercent = try c.decodeIfPresent(Int.self, forKey: .fiveHourPercent)
        weeklyPercent = try c.decodeIfPresent(Int.self, forKey: .weeklyPercent)
        idle = try c.decode(Bool.self, forKey: .idle)
        weeklyAsOf = try c.decodeIfPresent(Date.self, forKey: .weeklyAsOf)
        weeklyEstimated = try c.decodeIfPresent(Bool.self, forKey: .weeklyEstimated) ?? false
        hidesFiveHourMeter = try c.decodeIfPresent(Bool.self, forKey: .hidesFiveHourMeter) ?? false
        fiveHourResetAt = try c.decodeIfPresent(Date.self, forKey: .fiveHourResetAt)
        weeklyResetAt = try c.decodeIfPresent(Date.self, forKey: .weeklyResetAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(providerId, forKey: .providerId)
        try c.encode(shortName, forKey: .shortName)
        try c.encode(code, forKey: .code)
        try c.encode(dotColor, forKey: .dotColor)
        try c.encodeIfPresent(fiveHourPercent, forKey: .fiveHourPercent)
        try c.encodeIfPresent(weeklyPercent, forKey: .weeklyPercent)
        try c.encode(idle, forKey: .idle)
        try c.encodeIfPresent(weeklyAsOf, forKey: .weeklyAsOf)
        if weeklyEstimated { try c.encode(true, forKey: .weeklyEstimated) }
        if hidesFiveHourMeter { try c.encode(true, forKey: .hidesFiveHourMeter) }
        try c.encodeIfPresent(fiveHourResetAt, forKey: .fiveHourResetAt)
        try c.encodeIfPresent(weeklyResetAt, forKey: .weeklyResetAt)
    }

    /// a11y/age text for a stale weekly value; nil when the weekly value is live or absent.
    public func weeklyStaleLabel(now: Date) -> String? {
        guard let observed = weeklyAsOf, weeklyPercent != nil else { return nil }
        let age = now.timeIntervalSince(observed)
        if age < 0 { return "stale" }
        return StatuslineAge.asOfLabel(observedAt: observed, now: now)
    }

    public func isWeeklyStale(now: Date) -> Bool { weeklyStaleLabel(now: now) != nil }

    /// Providers whose weekly column can age out while the widget re-renders on a frozen JSON snapshot.
    static func carryWeeklyObservation(providerId: String, weeklyPercent: Int?) -> Bool {
        guard weeklyPercent != nil else { return false }
        return ClaudeScopedDisplay.isClaudeChromeId(providerId)
            || AntigravityQuotaDisplay.isQuotaChromeId(providerId)
            || CursorQuotaDisplay.isQuotaChromeId(providerId)
    }
}

public struct WidgetCreditRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var shortName: String
    public var dotColor: UInt32
    /// Primary value, e.g. `169 CU`.
    public var primary: String
    /// Secondary detail, e.g. `6.73/hr · 1 active`.
    public var secondary: String?

    public init(id: String, shortName: String, dotColor: UInt32, primary: String, secondary: String?) {
        self.id = id
        self.shortName = shortName
        self.dotColor = dotColor
        self.primary = primary
        self.secondary = secondary
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

    /// Ad-hoc builds: per-UID mirror so multi-user Macs do not clobber each other's snapshots.
    public static func sharedMirrorDirectoryURL() -> URL {
        URL(fileURLWithPath: SharedMirrorGate.uidDirectoryPath(), isDirectory: true)
    }

    /// Refuse symlinks / wrong-owner paths under the shared mirror root.
    static func sharedPathOwnedByCurrentUser(_ url: URL) -> Bool {
        SharedMirrorGate.sharedPathOwnedByCurrentUser(url)
    }

    /// Personal / ad-hoc builds: sandboxed widget can read this (see widget appex entitlements).
    public static func sharedFileURL() -> URL {
        URL(fileURLWithPath: SharedMirrorGate.snapshotFilePath(), isDirectory: false)
    }

    static func writeSharedMirror(_ snapshot: WidgetSnapshot) {
        guard let ctx = SharedMirrorGate.prepareWriteContext(),
              let data = try? AtomicJSON.encoder().encode(snapshot) else { return }
        _ = SharedMirrorGate.writeSnapshotJSON(data, dirPath: ctx.uidDirPath, dirIdentity: ctx.dirIdentity)
    }
}

public enum WidgetSnapshotStore {
    /// Set when the widget appex runs App Sandbox (typical gallery builds).
    static var widgetExtensionRunsInSandbox: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
    /// Write to App Support; App Group when available; `/Users/Shared/…` only when App Group is absent.
    public static func write(_ snapshot: WidgetSnapshot) {
        try? AtomicJSON.write(snapshot, to: WidgetSnapshotPaths.supportFileURL())
        if let group = WidgetSnapshotPaths.appGroupFileURL() {
            try? AtomicJSON.write(snapshot, to: group)
        }
        // Ad-hoc widget builds lack App Group; keep Shared mirror even when the host has a group container.
        WidgetSnapshotPaths.writeSharedMirror(snapshot)
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
        var best: WidgetSnapshot?
        for url in context.candidateURLs {
            guard let snap = decodeSnapshot(at: url) else { continue }
            if let best, snap.generatedAt <= best.generatedAt { continue }
            best = snap
        }
        return best
    }

    private static func decodeSnapshot(at url: URL) -> WidgetSnapshot? {
        let isShared = url.path.hasPrefix(SharedMirrorGate.rootPath + "/")
        if isShared {
            guard WidgetSnapshotPaths.sharedPathOwnedByCurrentUser(url.deletingLastPathComponent()),
                  url.path == SharedMirrorGate.snapshotFilePath(),
                  let data = SharedMirrorGate.readSnapshotJSON() else { return nil }
            return try? AtomicJSON.decoder().decode(WidgetSnapshot.self, from: data)
        }
        return AtomicJSON.read(WidgetSnapshot.self, from: url)
    }

    public static func isPopulated(_ snap: WidgetSnapshot) -> Bool {
        snap.generatedAt != .distantPast
            && (!snap.rows.isEmpty || !snap.creditRows.isEmpty || snap.todayTokens > 0)
    }
}

/// Rows for the macOS widget (Codex · Claude · Antigravity · Grok · OpenCode · Cursor).
public enum WidgetSnapshotBuilder {
    /// Display order of provider chrome ids in the widget (ids not listed sort after, by id).
    public static let preferredProviderOrder: [String] = [
        "codex",
        "claude-code",
        "claude-code-fable",
        "antigravity-gemini",
        "antigravity-claude-gpt",
        "antigravity-argon",
        "grok-code",
        "opencode",
        "cursor-ide",
        "cursor-ide-auto",
        "cursor-ide-api",
    ]

    public static func build(
        dashboard: DashboardState,
        limitStates: [ProviderLimitState],
        enabledProviders: Set<String>,
        colabCreditsEnabled: Bool = false,
        colabSnapshot: ColabCreditsSnapshot? = nil,
        maxRows: Int = 12
    ) -> WidgetSnapshot {
        let rowCap = max(0, maxRows)
        let names = Dictionary(
            dashboard.snapshots.map { ($0.providerId, $0.displayName) },
            uniquingKeysWith: { _, latest in latest }
        )

        let states = limitStates.filter { st in
            let root = rootProviderId(st.providerId)
            return enabledProviders.contains(root) || enabledProviders.contains(st.providerId)
        }

        func intPercent(_ p: Double?) -> Int? {
            guard let p, p.isFinite else { return nil }
            let clamped = min(100, max(0, p))
            return Int(clamped.rounded(.toNearestOrAwayFromZero))
        }

        var rows: [WidgetSnapshotRow] = []
        for st in states {
            let display = names[st.providerId] ?? st.providerId
            // Grok 只用 weekly 欄(credits → weekly,confidence .estimated);5h 永不發佈。
            let monthlyOnly = LimitMeterChrome.skipsFiveHourMeter(st.providerId)
            let five: Int? = monthlyOnly ? nil : intPercent(st.fiveHour.usedPercent)
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
                idle: idle,
                weeklyAsOf: WidgetSnapshotRow.carryWeeklyObservation(providerId: st.providerId, weeklyPercent: week)
                    ? st.weekly.observedAt : nil,
                weeklyEstimated: st.weekly.confidence == .estimated && week != nil,
                hidesFiveHourMeter: monthlyOnly,
                fiveHourResetAt: five == nil ? nil : st.fiveHour.resetAt,
                weeklyResetAt: week == nil ? nil : st.weekly.resetAt
            ))
        }

        rows.sort {
            let ai = orderIndex(preferredProviderOrder, $0.providerId)
            let bi = orderIndex(preferredProviderOrder, $1.providerId)
            if ai != bi { return ai < bi }
            return $0.providerId < $1.providerId
        }
        if rows.count > rowCap {
            rows = Array(rows.prefix(rowCap))
        }

        var creditRows: [WidgetCreditRow] = []
        if colabCreditsEnabled, let snap = colabSnapshot {
            let bal = ColabCreditsStatus.fmtUnits(snap.balanceUnits)
            let rate = ColabCreditsStatus.fmtUnits(snap.consumptionRatePerHour)
            // Widget columns are 30pt like 5h/wk — keep strings short; menu bar keeps full detail.
            creditRows.append(WidgetCreditRow(
                id: "colab",
                shortName: "Colab",
                dotColor: 0xF9AB00,
                primary: "\(bal)CU",
                secondary: "\(rate)/h"
            ))
        }

        let cost = dashboard.todayCost
        return WidgetSnapshot(
            generatedAt: dashboard.generatedAt,
            todayTokens: dashboard.todayTotals.total,
            todayCostUSD: cost.knownUSD,
            todayCostIsEstimated: cost.isEstimated,
            rows: rows,
            creditRows: creditRows
        )
    }

    private static func rootProviderId(_ id: String) -> String {
        if id.hasPrefix("antigravity") { return "antigravity" }
        if id.hasPrefix("claude-code") { return "claude-code" }
        if id.hasPrefix("cursor-ide") { return "cursor-ide" }
        return id
    }

    private static func orderIndex(_ order: [String], _ id: String) -> Int {
        order.firstIndex(of: id) ?? order.count
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
        case "claude-code":
            return Meta(shortName: "Claude", code: "CC", dotColor: 0xE8823A)
        case "claude-code-fable":
            return Meta(shortName: "Claude Fable", code: "Fb", dotColor: 0xE8823A)
        case "grok-code":
            return Meta(shortName: "Grok", code: "GK", dotColor: 0x2E3138)
        case "opencode":
            return Meta(shortName: "OpenCode", code: "OC", dotColor: 0xCA8A04)
        case "antigravity-gemini":
            return Meta(shortName: "AG Gemini", code: "Gm", dotColor: 0x8B5CF6)
        case "antigravity-claude-gpt":
            return Meta(shortName: "AG Claude/GPT", code: "3P", dotColor: 0x8B5CF6)
        case "antigravity-argon":
            return Meta(shortName: "AG Argon", code: "Ar", dotColor: 0x8B5CF6)
        case "cursor-ide":
            return Meta(shortName: "Cursor", code: "CU", dotColor: 0x1E1E1E)
        case "cursor-ide-auto":
            return Meta(shortName: "Cursor", code: "C1", dotColor: 0x1E1E1E)
        case "cursor-ide-api":
            return Meta(shortName: "Cursor Other", code: "C3", dotColor: 0x1E1E1E)
        default:
            if providerId.hasPrefix("antigravity") {
                return Meta(shortName: "Antigravity", code: "AG", dotColor: 0x8B5CF6)
            }
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? providerId : trimmed
            let code = String(name.prefix(2)).uppercased()
            return Meta(shortName: name, code: code.isEmpty ? "?" : code, dotColor: 0x9AA1AB)
        }
    }
}
/// The single limit closest to running out (small widget hero).
public struct WidgetUrgentLimit: Equatable, Sendable {
    public enum Window: Equatable, Sendable { case fiveHour, period }
    public var row: WidgetSnapshotRow
    public var window: Window
    public var percent: Int
    public var resetAt: Date?
    public var estimated: Bool
    /// Weekly reading past its as-of age; only chosen when no live reading exists.
    public var stale: Bool

    /// Short window tag: `5h`, `wk`, or `mo` (Cursor plan quota).
    public var windowTag: String {
        switch window {
        case .fiveHour: return "5h"
        case .period: return row.periodWindowName == "month" ? "mo" : "wk"
        }
    }
}

extension WidgetSnapshot {
    /// Live (and stale) window readings per row; idle rows contribute nothing.
    static func urgentCandidates(_ row: WidgetSnapshotRow, now: Date) -> [WidgetUrgentLimit] {
        guard !row.idle else { return [] }
        var out: [WidgetUrgentLimit] = []
        if !row.widgetSinglePeriodColumn, let p = row.fiveHourPercent {
            out.append(WidgetUrgentLimit(row: row, window: .fiveHour, percent: min(100, max(0, p)),
                                         resetAt: row.fiveHourResetAt, estimated: false, stale: false))
        }
        if let p = row.weeklyPercent {
            out.append(WidgetUrgentLimit(row: row, window: .period, percent: min(100, max(0, p)),
                                         resetAt: row.weeklyResetAt, estimated: row.weeklyEstimated,
                                         stale: row.isWeeklyStale(now: now)))
        }
        return out
    }

    /// Highest percent wins; ties → earlier reset (nil last) → earlier row. Stale weekly readings
    /// count only when no live reading exists. nil when no row has a reading.
    public func mostUrgentLimit(now: Date) -> WidgetUrgentLimit? {
        let all = rows.flatMap { Self.urgentCandidates($0, now: now) }
        let live = all.filter { !$0.stale }
        let pool = live.isEmpty ? all : live
        var best: WidgetUrgentLimit?
        for c in pool {
            guard let b = best else { best = c; continue }
            if c.percent != b.percent {
                if c.percent > b.percent { best = c }
                continue
            }
            switch (c.resetAt, b.resetAt) {
            case let (cr?, br?) where cr < br: best = c
            case (_?, nil): best = c
            default: break
            }
        }
        return best
    }

    /// Other providers (not windows) with a live reading at or above `threshold`.
    public func otherProvidersNear(limit: WidgetUrgentLimit, threshold: Int = 80, now: Date) -> Int {
        rows.filter { $0.providerId != limit.row.providerId }
            .filter { row in
                Self.urgentCandidates(row, now: now).contains { !$0.stale && $0.percent >= threshold }
            }
            .count
    }
}

extension WidgetSnapshot {
    /// Header legend naming the columns actually on screen: `5h · wk · mo`, `wk · mo`, `5h · ~wk`, …
    /// Idle rows show no values, so they don't add a column name. Falls back to `wk` when nothing shows.
    public var legendCaption: String {
        let active = rows.filter { !$0.idle }
        func tag(_ name: String, _ short: String) -> String? {
            let hits = active.filter { $0.periodWindowName == name }
            guard !hits.isEmpty else { return nil }
            return (hits.contains(where: \.weeklyEstimated) ? "~" : "") + short
        }
        var parts: [String] = []
        if active.contains(where: { !$0.widgetSinglePeriodColumn }) { parts.append("5h") }
        if let wk = tag("week", "wk") { parts.append(wk) }
        if let mo = tag("month", "mo") { parts.append(mo) }
        return parts.isEmpty ? "wk" : parts.joined(separator: " · ")
    }
}
