import Foundation
import CoreGraphics

/// 區域種類。幾何允許重疊(water rect 含 ground 線)— 區域「檢定」依物種過濾:
/// Walker/Flyer 永不判水,Swimmer 以 water rect 判水。
public enum RegionKind: String, Sendable {
    case ground, air, water
}

/// Flyer 專用飛行封套(movement-range% 疊加約束;**不**改 water/air/hover 正典幾何)。
/// - `ceiling`:位置 y 上界,僅 `.flyer` 於 `MotionController` 套用(walker/swimmer 仍用 vf.maxY)。
/// - `hover`:縮放後的懸停目標帶(`HoverController` 用)。
/// range=100% 時 `ceiling == vf.maxY`、`hover ==` 正典 hover(與傳統逐位一致 → golden 不動);
/// range<100% 時自「地面線(rest)」ground-lerp 縮放,把鳥關進 home 附近的小盒。
public struct FlyerEnvelope: Sendable, Equatable {
    public var ceiling: CGFloat
    public var hover: ClosedRange<CGFloat>
    public init(ceiling: CGFloat, hover: ClosedRange<CGFloat>) {
        self.ceiling = ceiling
        self.hover = hover
    }
}

/// 以寵物所在螢幕 visibleFrame 計算的區域幾何(§4 凍結公式;AppKit 底原點)。
/// 由 Bridge 建構(NSScreen 訂閱、佈局變更重算);PetCore 只消費。
public struct RegionMap: Sendable {
    public var bounds: CGRect
    public var water: CGRect
    public var groundY: CGFloat
    public var airMinY: CGFloat
    public var hover: ClosedRange<CGFloat>
    /// Flyer 的 range% 封套(§4 疊加擴充;預設 = 正典/無界 → 既有呼叫與 golden 零改動)。
    public var flyer: FlyerEnvelope

    /// - Parameter flyerRangePercent: 漫遊範圍 %(10…100);僅影響 `flyer` 封套的垂直範圍,
    ///   water/air/ground/hover/bounds 一律不動。預設 100 = 傳統無界(既有呼叫點/測試不變)。
    public init(visibleFrame vf: CGRect, flyerRangePercent: Double = 100) {
        bounds = vf
        // 水帶:lower = min(80, 0.22×H);waterH = clamp(0.18×H, lower, 0.22×H)。
        // lower ≤ 0.22×H 恆成立,水帶底對齊、永不空(矮螢幕 degenerate 必過)。
        let lower = min(80, 0.22 * vf.height)
        let waterH = min(max(0.18 * vf.height, lower), 0.22 * vf.height)
        water = CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: waterH)
        groundY = vf.minY
        // air 起於水面頂;懸停帶 = air 區高度的 [0.40, 0.80](雙端含)。
        airMinY = water.maxY
        let airH = vf.maxY - airMinY
        hover = (airMinY + 0.40 * airH)...(airMinY + 0.80 * airH)

        // Flyer 封套:自地面線(groundY = rest)ground-lerp 縮放。f=1 逐位還原傳統
        // (ceiling 直接取 vf.maxY,不以 airMinY+airH 重構;hover == 正典)→ golden 不動。
        let f = max(0, min(1, flyerRangePercent / 100))
        let ceiling = (f >= 1) ? vf.maxY : groundY + f * (vf.maxY - groundY)
        let fHover: ClosedRange<CGFloat> = (f >= 1)
            ? hover
            : (groundY + f * (hover.lowerBound - groundY))...(groundY + f * (hover.upperBound - groundY))
        flyer = FlyerEnvelope(ceiling: ceiling, hover: fHover)
    }
}
