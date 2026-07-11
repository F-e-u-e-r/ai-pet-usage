import Foundation
import CoreGraphics

/// 區域種類。幾何允許重疊(water rect 含 ground 線)— 區域「檢定」依物種過濾:
/// Walker/Flyer 永不判水,Swimmer 以 water rect 判水。
public enum RegionKind: String, Sendable {
    case ground, air, water
}

/// 以寵物所在螢幕 visibleFrame 計算的區域幾何(§4 凍結公式;AppKit 底原點)。
/// 由 Bridge 建構(NSScreen 訂閱、佈局變更重算);PetCore 只消費。
public struct RegionMap: Sendable {
    public var bounds: CGRect
    public var water: CGRect
    public var groundY: CGFloat
    public var airMinY: CGFloat
    public var hover: ClosedRange<CGFloat>

    public init(visibleFrame vf: CGRect) {
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
    }
}
