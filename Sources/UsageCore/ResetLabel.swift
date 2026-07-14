import Foundation

/// 限額重置倒數的顯示格式(純函式;menu 浮動面板與 dashboard 共用,可單元測試 —— 純函式放
/// UsageCore 讓 usagecore-tests 能直接 import 驗證,避免邏輯困在無法測試的 app 執行檔目標)。
public enum ResetLabel {

    /// 倒數字串:`—`(nil)、`now`(已到/過期)、`59m`、`4h 59m`、`6d 3h`(>48h 進位到「日 時」)。
    public static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "now" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h > 48 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// menu 面板 reset 欄的**壓縮**標籤:5h 有重置 → 純倒數;否則 weekly → `wk ` + 倒數;皆無 → `—`。
    /// 刻意去掉「resets / wk resets」冗字,讓最壞情況(weekly `6d 3h`)在固定窄欄不被截斷;
    /// 完整語意保留在 `accessibility(...)`。5h 優先(較短窗、較常是當前約束)。
    public static func compact(fiveHourResetAt: Date?, weeklyResetAt: Date?, now: Date = Date()) -> String {
        if let r = fiveHourResetAt { return countdown(to: r, now: now) }
        if let r = weeklyResetAt { return "wk " + countdown(to: r, now: now) }
        return "—"
    }

    /// a11y 完整句(視覺壓縮時朗讀仍完整):例「5-hour limit resets in 4h 59m」。
    public static func accessibility(fiveHourResetAt: Date?, weeklyResetAt: Date?, now: Date = Date()) -> String {
        if let r = fiveHourResetAt { return "5-hour limit resets in \(countdown(to: r, now: now))" }
        if let r = weeklyResetAt { return "weekly limit resets in \(countdown(to: r, now: now))" }
        return "no reset scheduled"
    }
}
