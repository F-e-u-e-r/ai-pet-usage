import AppKit

/// menu 下拉面板 provider 列的欄寬(單一事實來源;view 與測試共用)。
///
/// 欄寬 = **實測** worst-case 內容寬(實際系統字體)+ 呼吸邊距。背景:5h/wk 欄原本寫死 50pt,
/// 兩位數百分比放得下,但 weekly/5h 到 **100%(三位數)** 時 "wk 100%" 超過 50pt →
/// SwiftUI 在固定 frame 內壓縮子 Text,文字被截/折行(2026-07-16 使用者回報)。
/// 實測值隨系統字體版本自適應;測試釘住「欄寬 ≥ 各 worst-case 內容」的不變量。
public enum MenuPanelMetrics {

    /// 窗欄(5h/wk)單一 cell 的內容寬:label(caption2)+ 2pt spacing + value(callout
    /// semibold monospacedDigit)。與 MenuBarPanel.windowText 的字體規格一一對應 ——
    /// 這裡改字體,view 也要同步(測試只能釘住這份規格)。
    public static func measuredWindowCellWidth(label: String, value: String) -> CGFloat {
        let labelFont = NSFont.preferredFont(forTextStyle: .caption2)
        let valueSize = NSFont.preferredFont(forTextStyle: .callout).pointSize
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .semibold)
        let l = (label as NSString).size(withAttributes: [.font: labelFont]).width
        let v = (value as NSString).size(withAttributes: [.font: valueFont]).width
        return l + 2 + v
    }

    /// worst-case 內容組合:label 取較寬者、value 取 "100%"(三位數)與 "idle"。
    public static var worstWindowCellWidth: CGFloat {
        [("5h", "100%"), ("wk", "100%"), ("5h", "idle"), ("wk", "idle")]
            .map { measuredWindowCellWidth(label: $0.0, value: $0.1) }
            .max() ?? 0
    }

    /// 5h/wk 欄寬:實測 worst-case + 2pt(ceil 去次像素)。
    public static var windowColumnWidth: CGFloat { ceil(worstWindowCellWidth) + 2 }

    /// reset 欄寬(compact 標籤 ≤ 9 字元,見 ResetLabelTests.testCompactWorstCaseFitsBudget)。
    public static let resetColumnWidth: CGFloat = 64

    /// 面板總寬:名稱欄下限(dot 8 + 短名)~110 + 兩個窗欄 + reset 欄 + HStack spacing 8×4
    /// + 面板 padding 12;與現行 340 取大者(欄寬未超過原預算時外觀不變)。
    public static var panelWidth: CGFloat {
        max(340, ceil(110 + 2 * windowColumnWidth + resetColumnWidth + 4 * 8 + 12))
    }
}
