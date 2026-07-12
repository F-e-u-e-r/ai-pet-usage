import Foundation
import CoreGraphics
import UsageCore

/// 寵物用量環的純幾何/資料模型(R2 B1/B2;View 只負責畫)。
///
/// 幾何契約:最內環直徑 = sprite 淨空 `1.75 × petSize`(嚴格大於 sprite frame
/// 對角 √(1.3²+1.15²)s ≈ 1.735s,含 64pt 下的次像素餘裕);每多一家 provider
/// **向外** +13pt 直徑(線寬 3.5 + 環距 3;固定 pt,不隨 petSize 縮放)。
/// 絕不向內縮 — 內縮的第二圈會重新蓋回 sprite。容器/面板以 **4 環容量** 保留
/// 空間,環數變動不觸發視窗改尺寸。
///
/// 環色 = provider identity 恆定(嚴重度由 mood 徽章承載;E2a A11 的環上
/// warn/danger 換色規則自 R2 起廢止 — 僅環,選單/量表/文字 severity 不動)。
public enum UsageRingModel {

    /// 每環直徑增量(= 2 × (線寬 3.5 + 環距 3);pt 固定)。
    public static let ringStep: CGFloat = 13
    public static let strokeWidth: CGFloat = 3.5
    /// 面板保留的環數上限(Antigravity 未來加入也不改視窗尺寸)。
    public static let capacity = 4
    /// 底部缺口(所有環同缺口、同起點)。
    public static let gapFraction: Double = 0.08

    /// 最內環直徑(sprite 淨空)。
    public static func baseDiameter(petSize: Double) -> CGFloat {
        CGFloat(petSize) * 1.75
    }

    /// 容量外徑(容器邊長;含 4 環)。
    public static func capacityOuterDiameter(petSize: Double) -> CGFloat {
        baseDiameter(petSize: petSize) + CGFloat(capacity - 1) * ringStep
    }

    /// 一環的資料(進度弧 = identity 色;percent 已保證非 nil)。
    public struct Entry: Equatable, Sendable {
        public let providerId: String
        public let percent: Double
        public init(providerId: String, percent: Double) {
            self.providerId = providerId
            self.percent = percent
        }
    }

    /// 過濾規則(B2):有 5h 百分比者各一環,依傳入順序(orderedLimitStates)、
    /// 至多 capacity 家;Grok(nil)自然跳過。
    public static func entries(from limits: [ProviderLimitState]) -> [Entry] {
        limits.compactMap { st in
            st.fiveHour.usedPercent.map { Entry(providerId: st.providerId, percent: $0) }
        }
        .prefix(capacity)
        .map { $0 }
    }

    /// 第 k 家(0-based,共 n 家)的環直徑:第一家最外,自 base 向外疊。
    public static func diameter(index k: Int, count n: Int, petSize: Double) -> CGFloat {
        baseDiameter(petSize: petSize) + CGFloat(max(0, n - 1 - k)) * ringStep
    }
}
