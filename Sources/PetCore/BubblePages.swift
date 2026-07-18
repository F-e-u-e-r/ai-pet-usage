import Foundation

/// 泡泡頁面的行預算組合器(R1 雙審 C10:**絕不靜默截斷**)。
/// 泡泡保留區 92pt ≈ 4 行 11pt mono(R3 佈局決策,不放大)。
public enum BubblePages {
    /// 決定性槽位規則:`extraLine`(如 OpenRouter credits 行)固定佔最後一槽,
    /// provider 行填滿其餘;放不下時最後一個 provider 槽變成「+N more」——
    /// 使用者看得見還有幾家被收合,而不是憑空消失。
    /// `extraLine == nil` 且行數 ≤ `maxLines` 時輸出與輸入完全相同(既有行為位元不變)。
    public static func compose(providerLines: [String], extraLine: String?, maxLines: Int = 4) -> [String] {
        precondition(maxLines >= 2, "need at least one provider slot + overflow/extra slot")
        guard let extra = extraLine else {
            if providerLines.count <= maxLines { return providerLines }
            let kept = maxLines - 1
            return Array(providerLines.prefix(kept)) + ["+\(providerLines.count - kept) more"]
        }
        let slots = maxLines - 1
        if providerLines.count <= slots { return providerLines + [extra] }
        let kept = slots - 1
        return Array(providerLines.prefix(kept)) + ["+\(providerLines.count - kept) more", extra]
    }
}
