import Foundation

// Usage-M3 B(2026-09-27):Dashboard 分頁的時間範圍選擇,自 AppModel 搬入 UsageCore 成純值。
// 動機:Projects 與 Models 是**兩個獨立分頁、各自擁有一份 range**(owner 契約:Models 換 range 絕不可
// 動到 Projects,反之亦然)。把「選擇 → 區間」抽成唯一一份純函式 `RangeSelection.interval(now:)`,
// 兩分頁(與 export)共用,不得另寫語意不同的第二份;零 UI 依賴,usagecore-tests 可直測(G / I)。

/// 分頁的時間範圍預設(可逆、可直接跳轉——規格明令禁止單向循環)。
public enum RangePreset: String, CaseIterable, Identifiable, Sendable {
    case today, yesterday, last7Days, thisWeek, lastWeek, allTime, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7Days: return "Last 7 days"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .allTime: return "All time"
        case .custom: return "Custom"
        }
    }
}

/// 一個分頁**擁有**的區間選擇(值型別)。Projects 與 Models 各持一份:改其一在型別層面不可能影響另一份
/// (state ownership 分離);coordinator 端兩分頁另有各自的快取槽(`cachedProjectPage` / `cachedModelPage`),
/// AppModel 端各自的 reload 序號 —— 三層全部分開,才算「兩個 range 真正獨立」。
public struct RangeSelection: Equatable, Sendable {
    public var preset: RangePreset
    public var customStart: Date
    public var customEnd: Date

    /// 預設 = Today;custom 起訖預設為「最近 7 天」(與原 Projects 頁預設逐字相同)。
    public init(preset: RangePreset = .today, customStart: Date? = nil, customEnd: Date? = nil,
                now: Date = Date(), calendar: Calendar = .current) {
        self.preset = preset
        self.customStart = customStart ?? calendar.startOfDay(for: now.addingTimeInterval(-6 * 86400))
        self.customEnd = customEnd ?? now
    }

    /// 選擇 → 查詢區間。原 `AppModel.currentRange()` 逐字搬入(唯一實作;Projects / Models / export 共用)。
    /// `.custom` 的「不晚於現在」上界原以 `Date()` 取值,此處改用 `now` —— production 預設 `now = Date()` 故行為相同,
    /// 但注入 `now` 時整個函式成純函式(可測)。
    public func interval(now: Date = Date(), calendar cal: Calendar = .current) -> DateInterval {
        switch preset {
        case .today:
            return .today(now: now, calendar: cal)
        case .yesterday:
            return .day(containing: cal.date(byAdding: .day, value: -1, to: now)!, calendar: cal)
        case .last7Days:
            return DateInterval(start: cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now)!), end: now)
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: now)!.start
            return DateInterval(start: start, end: now)
        case .lastWeek:
            let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!
            return DateInterval(start: cal.date(byAdding: .day, value: -7, to: thisWeek.start)!, end: thisWeek.start)
        case .allTime:
            // 涵蓋整個本機歷史(帳本有保留期上限,起點取足夠早即可;coordinator 再 clamp 進 retained window)
            return DateInterval(start: Date(timeIntervalSince1970: 0), end: now)
        case .custom:
            let start = cal.startOfDay(for: customStart)
            let end = min(cal.startOfDay(for: customEnd).addingTimeInterval(86400), now)
            return DateInterval(start: start, end: max(end, start.addingTimeInterval(60)))
        }
    }
}

/// 重載寫回競態防護(序號守門)的純核心,每個 surface 一份。AppModel 的 Projects / Trends 以 inline 序號實作
/// 同一規則(見其 `projectPageLoadSeq` 註解:MainActor 上 continuation 的 resume 順序不保證等於 actor 完成順序,
/// 舊結果可能後寫覆蓋新結果);Models 分頁把規則抽成此型別 —— 守門在 `publish` **內部**,呼叫端無法繞過,
/// usagecore-tests 可直接證明「較舊發起者的完成,無論何時 resume,都不得蓋掉較新者」(test H)。
public struct SequencedSlot<Value: Sendable>: Sendable {
    /// 目前已落地的值(最新發起者的完成結果;尚無 → nil)。
    public private(set) var value: Value?
    private var latest: UInt64 = 0

    public init() {}

    /// 發起一次重載 → 回傳本次票號(單調遞增;舊票立即失效)。
    public mutating func begin() -> UInt64 {
        latest &+= 1
        return latest
    }

    /// 完成時寫回:**只有最新票號**可落地;較舊的完成(即使後到)被丟棄。回傳是否落地。
    @discardableResult
    public mutating func publish(_ ticket: UInt64, _ newValue: Value) -> Bool {
        guard ticket == latest else { return false }
        value = newValue
        return true
    }
}
