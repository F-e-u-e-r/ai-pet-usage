import Foundation

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

public enum WidgetSnapshotBuilder {
    public static let preferredProviderOrder = [
        "codex",
        "claude-code",
        "grok-code",
        "opencode",
    ]

    public static func build(
        dashboard: DashboardState,
        limitStates: [ProviderLimitState],
        enabledProviders: Set<String>,
        maxRows: Int = 12
    ) -> WidgetSnapshot {
        let rowCap = max(0, maxRows)
        let names = Dictionary(
            dashboard.snapshots.map { ($0.providerId, $0.displayName) },
            uniquingKeysWith: { _, latest in latest }
        )
        let states = limitStates.filter { enabledProviders.contains($0.providerId) }

        func intPercent(_ percent: Double?) -> Int? {
            guard let percent, percent.isFinite else { return nil }
            let clamped = min(100, max(0, percent))
            return Int(clamped.rounded(.toNearestOrAwayFromZero))
        }

        var rows: [WidgetSnapshotRow] = []
        var seenProviderIds = Set<String>()
        for state in states {
            let fiveHour = intPercent(state.fiveHour.usedPercent)
            let weekly = intPercent(state.weekly.usedPercent)
            let idle = state.fiveHour.idle && fiveHour == nil && weekly == nil
            if fiveHour == nil, weekly == nil, !idle { continue }
            // 同一 provider 重複的 state:第一個有資料的勝出,避免重複 row id 佔掉 row cap。
            guard seenProviderIds.insert(state.providerId).inserted else { continue }

            let displayName = names[state.providerId] ?? state.providerId
            let chrome = WidgetProviderChrome.meta(for: state.providerId, displayName: displayName)
            rows.append(WidgetSnapshotRow(
                providerId: state.providerId,
                shortName: chrome.shortName,
                code: chrome.code,
                dotColor: chrome.dotColor,
                fiveHourPercent: fiveHour,
                weeklyPercent: weekly,
                idle: idle
            ))
        }

        rows.sort {
            let lhs = orderIndex(preferredProviderOrder, $0.providerId)
            let rhs = orderIndex(preferredProviderOrder, $1.providerId)
            if lhs != rhs { return lhs < rhs }
            return $0.providerId < $1.providerId
        }
        if rows.count > rowCap {
            rows = Array(rows.prefix(rowCap))
        }

        let knownCost = dashboard.todayCost.knownUSD
        return WidgetSnapshot(
            generatedAt: dashboard.generatedAt,
            todayTokens: dashboard.todayTotals.total,
            todayCostUSD: knownCost.isFinite ? knownCost : nil,
            todayCostIsEstimated: dashboard.todayCost.isEstimated,
            rows: rows
        )
    }

    private static func orderIndex(_ order: [String], _ providerId: String) -> Int {
        order.firstIndex(of: providerId) ?? order.count
    }
}

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
        case "grok-code":
            return Meta(shortName: "Grok", code: "GK", dotColor: 0x2E3138)
        case "opencode":
            return Meta(shortName: "OpenCode", code: "OC", dotColor: 0xCA8A04)
        default:
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? providerId : trimmed
            let code = String(name.prefix(2)).uppercased()
            return Meta(shortName: name, code: code.isEmpty ? "?" : code, dotColor: 0x9AA1AB)
        }
    }
}
