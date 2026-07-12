import Foundation
import CoreGraphics

/// 寵物漫遊「範圍帶」:以 **寵物中心 x(center-x)** 為統一座標定義允許帶,
/// legacy 視窗路徑與 EngineV2 都消費同一語意(座標契約:legacy 操作 panel origin,
/// 需經 `originRange` 轉換;V2 的 MotionState.position.x 即底部中心,直接用 center 帶)。
///
/// 語意(計畫 A1/D4):home 錨定 — home = 寵物當下 center-x,於
/// (a) 漫遊由關轉開、(b) 手動拖曳落定、(c) app 啟動、(d) 範圍百分比變更 時重錨;
/// 重錨後若當下位置在新帶外,做一次性 clamp(呼叫端負責)。100% = 整個螢幕(原行為)。
public enum WanderBand {

    /// 允許的 center-x 範圍:home ± (range% × 螢幕寬)/2,夾進 [minX+margin+w/2, maxX−margin−w/2]。
    /// rangePercent ≥ 100 → 整幕(等同無帶)。螢幕過窄(可行區間退化)→ 回傳單點範圍。
    public static func centerBand(homeCenterX: CGFloat, rangePercent: Double,
                                  screen: CGRect, petWidth: CGFloat,
                                  margin: CGFloat = 12) -> ClosedRange<CGFloat> {
        let lo = screen.minX + margin + petWidth / 2
        let hi = screen.maxX - margin - petWidth / 2
        guard hi > lo else {
            let mid = (screen.minX + screen.maxX) / 2
            return mid...mid
        }
        guard rangePercent < 100 else { return lo...hi }
        let half = max(0, CGFloat(rangePercent) / 100 * screen.width / 2)
        let start = max(lo, min(homeCenterX - half, hi))
        let end = min(hi, max(homeCenterX + half, lo))
        return start...min(max(start, end), hi)
    }

    /// legacy 視窗路徑的轉換:center-x 帶 → panel origin.x 帶(origin = center − petWidth/2)。
    public static func originRange(centerBand: ClosedRange<CGFloat>, petWidth: CGFloat) -> ClosedRange<CGFloat> {
        (centerBand.lowerBound - petWidth / 2)...(centerBand.upperBound - petWidth / 2)
    }

    /// EngineV2 的消費形態:把 visibleFrame 的水平範圍收窄成 **center band 本身**。
    /// Motion 夾限/折返作用在 `position.x`(= 底部中心,center-x),bounds 必須恰為
    /// 允許的中心區間 —— 不得再加 petWidth 半寬(那是 origin 外接語意,只屬 legacy;
    /// 放寬會讓 V2 帶比設定寬 petWidth,雙審 P1)。RegionMap §4 公式只依高度,不受影響。
    public static func narrowedFrame(visibleFrame vf: CGRect,
                                     centerBand: ClosedRange<CGFloat>) -> CGRect {
        let minX = max(vf.minX, centerBand.lowerBound)
        let maxX = min(vf.maxX, centerBand.upperBound)
        guard maxX > minX else {
            // 帶退化為單點(過窄螢幕/極小 range):給 1pt 寬,Motion 夾在點上。
            let x = min(max(centerBand.lowerBound, vf.minX), vf.maxX)
            return CGRect(x: x, y: vf.minY, width: 1, height: vf.height)
        }
        return CGRect(x: minX, y: vf.minY, width: maxX - minX, height: vf.height)
    }

    /// 範圍百分比的合法化(設定檔手改防護;UI 滑桿 10–100,解碼一律夾回)。
    /// 下限 10%(R3 使用者要求):寵物活動被壓到很窄仍保有一點生氣。
    public static func clampRangePercent(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(100, max(10, value))
    }
}
