import Foundation
import CoreGraphics

// MARK: - 型別(§8 凍結契約)

/// 運動參數集(§5 常數綁定;E1+ 需要時各 case 可帶參數 struct)。
public enum LocomotionProfile: Sendable {
    case walker, flyer, swimmer

    /// 重力(px/s²):Swimmer 水中 0、出水 900(彈道回水);其餘一律 900。
    public func gravity(inWater: Bool) -> CGFloat {
        (self == .swimmer && inWater) ? 0 : EngineV2.gravity
    }

    /// 行為層水平巡航/漂游目標速度(px/s);Flyer 以拍翅衝量行動,無巡航值。
    public var cruiseSpeed: CGFloat? {
        switch self {
        case .walker: return EngineV2.walkerCruise
        case .flyer: return nil
        case .swimmer: return EngineV2.swimmerDrift
        }
    }
}

public struct MotionState: Sendable {
    public var position: CGPoint
    public var velocity: CGVector
    public var grounded: Bool

    public init(position: CGPoint, velocity: CGVector, grounded: Bool) {
        self.position = position
        self.velocity = velocity
        self.grounded = grounded
    }
}

public enum DropSeverity: Sendable, Equatable {
    case soft, bounce, hard
}

public enum MotionEvent: Sendable, Equatable {
    case dropped(DropSeverity)
    case enteredRegion(RegionKind)
    case leftRegion(RegionKind)
}

public protocol MotionControlling: AnyObject {
    var state: MotionState { get }
    func applyImpulse(_ delta: CGVector)
    func setTargetVelocity(_ target: CGVector?)      // cruise/drift;nil = 無目標
    func beginDrag(at: CGPoint)
    func dragMoved(to: CGPoint, dt: TimeInterval)
    func endDrag()
    func tick(dt: TimeInterval, regions: RegionMap) -> [MotionEvent]
}

// MARK: - 減速常數組(golden mutation guard 的注入點)

/// 每軸線性減速常數組。出貨路徑只用 `.frozen`(§5 凍結:地面 450 / 水中 300 / 空中 120);
/// 測試得注入**故意錯誤**的變異組,證明 golden gate 對錯常數確實會失敗
/// (自我檢核的 mutation 測試 — 防止 golden 斷言退化成永遠綠燈)。
public struct DecelSet: Sendable, Equatable {
    public var ground: CGFloat
    public var water: CGFloat
    public var air: CGFloat

    public init(ground: CGFloat, water: CGFloat, air: CGFloat) {
        self.ground = ground
        self.water = water
        self.air = air
    }

    /// §5 凍結值(唯一出貨組)。
    public static let frozen = DecelSet(ground: EngineV2.groundDecel,
                                        water: EngineV2.waterDecel,
                                        air: EngineV2.airDecel)
}

// MARK: - MotionController

/// 物理積分器 — §3/§6 凍結律逐字實作:
/// ```
/// (行為層先施加 one-shot impulse / 設定目標速度)
/// dt = min(dt, 0.25)
/// v.y -= gravity(profile, region) × dt
/// 每軸: v -= min(|v|, decel × dt) × sign(v)    // 地面 450 / 水中 300 / 空中 120
/// if |v| > 600: v ×= 600 / |v|                 // 歐氏逃逸帽(無軸速帽)
/// pos += v × dt → 區域反應 → 呈現 = pos.rounded()
/// ```
/// 模擬用浮點座標;呈現另取整(half away from zero)。
public final class MotionController: MotionControlling {

    public let profile: LocomotionProfile
    /// 減速常數組(預設 §5 凍結;僅 mutation-guard 測試注入變異組)。
    private let decel: DecelSet

    private var position: CGPoint
    private var velocity: CGVector = .zero
    private var grounded = false
    private var targetVelocity: CGVector?

    /// 目前所在區域(依物種過濾的檢定結果;首次 tick 前為出生點分類,不發事件)。
    public private(set) var region: RegionKind

    // 拖曳:grab-point 保持 + 位置差/dt 注入速度;拖曳中物理暫停(Flyer 拖曳=暫停飛行)。
    private var dragging = false
    private var grabOffset = CGVector.zero

    // MARK: NaN 失控防護(§2.8:Debug assert;Release 夾停歸零+計數+log,絕不 crash)

    public enum NaNHandling {
        /// Debug 模式:呼叫 trap(預設 assertionFailure)後仍復原,絕不留毒。
        case debugTrap
        /// Release 模式:靜默夾停歸零 + 計數 + log。
        case recoverAndCount
    }

    /// 預設依編譯組態;測試可注入以同一 binary 覆蓋兩種模式。
    public var nanHandling: NaNHandling
    /// Debug trap 掛鉤(測試替換以觀測;預設 assertionFailure)。
    public var nanTrap: (String) -> Void = { assertionFailure("EngineV2 MotionController NaN: \($0)") }
    /// Release 復原計數器。
    public private(set) var nanRecoveryCount = 0

    public init(profile: LocomotionProfile, position: CGPoint, regions: RegionMap,
                decel: DecelSet = .frozen) {
        self.profile = profile
        self.position = position
        self.decel = decel
        #if DEBUG
        nanHandling = .debugTrap
        #else
        nanHandling = .recoverAndCount
        #endif
        region = Self.classify(profile: profile, position: position, grounded: false, regions: regions)
    }

    public var state: MotionState {
        MotionState(position: position, velocity: velocity, grounded: grounded)
    }

    /// 呈現座標:凍結取整規則 `.rounded()`(half away from zero)。
    public var presentedPosition: CGPoint {
        CGPoint(x: position.x.rounded(), y: position.y.rounded())
    }

    // MARK: 行為層輸入(皆於物理 tick 之前施加)

    public func applyImpulse(_ delta: CGVector) {
        velocity.dx += delta.dx
        velocity.dy += delta.dy
    }

    public func setTargetVelocity(_ target: CGVector?) {
        targetVelocity = target
    }

    /// 硬性歸零速度(FIX-8:reduce-motion 靜態姿勢集)。位置不動;後續 tick 的
    /// 重力與著地反應照常 —— 懸空的寵物以每 tick 重力增量緩降落定,不懸浮、
    /// 也不再有任何向上分量。冪等,reduce-motion 期間每 tick 呼叫。
    public func cancelMomentum() {
        velocity = .zero
    }

    /// 一次性水平 clamp(A1 漫遊範圍帶重算後):位置若落在新 bounds 之外,
    /// 拉回帶內並吸掉水平動量,避免下一 tick 的邊界反應造成可見瞬移。
    /// 帶內位置為 no-op;垂直分量完全不動(§4 高度公式不受範圍帶影響)。
    public func clampHorizontally(into bounds: CGRect) {
        let clamped = min(max(position.x, bounds.minX), bounds.maxX)
        guard clamped != position.x else { return }
        position.x = clamped
        velocity.dx = 0
    }

    /// 一次性垂直 clamp(range 縮小 → flyer 天花板下移):位置若高於新天花板,拉回並吸掉
    /// 上行動量,避免下一 tick 邊界反應造成可見瞬移。界內為 no-op;呼叫端只對 `.flyer` 套用。
    public func clampBelowCeiling(_ ceiling: CGFloat) {
        guard position.y > ceiling else { return }
        position.y = ceiling
        if velocity.dy > 0 { velocity.dy = 0 }
    }

    /// 深閒置停表前的一次性落地 snap:位置落到地面線、速度歸零、標記接地。停表後無 tick 可再
    /// 帶其落定,故此為「飛行中的 flyer 絕不半空凍結」的最後硬保證(呼叫端只對空中的 .flyer 用)。
    public func snapToGround(_ groundY: CGFloat) {
        position.y = groundY
        velocity = .zero
        grounded = true
        region = .ground   // 消 stale .air:醒來首個行為轉移用對區域(否則下一 tick 前錯判)。
    }

    // MARK: 拖曳

    public func beginDrag(at point: CGPoint) {
        dragging = true
        grabOffset = CGVector(dx: position.x - point.x, dy: position.y - point.y)
        velocity = .zero
        grounded = false
    }

    public func dragMoved(to point: CGPoint, dt: TimeInterval) {
        guard dragging else { return }
        let new = CGPoint(x: point.x + grabOffset.dx, y: point.y + grabOffset.dy)
        // dt 過小(或 0)不注入速度,避免除零產生 inf/NaN。
        if dt > 1e-4 {
            velocity = CGVector(dx: (new.x - position.x) / dt, dy: (new.y - position.y) / dt)
        }
        position = new
    }

    public func endDrag() {
        // 放手甩出:沿用最後注入速度;逃逸帽於下個 tick 內夾限。
        dragging = false
    }

    // MARK: 積分 tick

    public func tick(dt rawDT: TimeInterval, regions: RegionMap) -> [MotionEvent] {
        // 拖曳中:位置由外部驅動,物理暫停;仍作 NaN 防護。
        if dragging {
            guardAgainstNaN(fallback: position)
            return []
        }

        let lastGood = position
        let dt = CGFloat(min(max(rawDT, 0), EngineV2.dtCap))   // dt 夾限(凍結 0.25s)
        var events: [MotionEvent] = []

        // 0. 行為層目標速度(cruise/drift;僅水平軸 — 垂直軸交給重力/衝量)。
        if let target = targetVelocity {
            velocity.dx = target.dx
        }

        // 1. 重力(依 profile × 區域;Swimmer 以「位置是否在水帶」判定)。
        let inWater = profile == .swimmer && position.y <= regions.water.maxY
        velocity.dy -= profile.gravity(inWater: inWater) * dt

        // 2. 每軸線性減速夾停:decel = 地面接觸 450 / 水中 300 / 空中 120(自 DecelSet 取值;
        //    出貨恆為 .frozen,mutation-guard 測試注入錯值以驗證 golden gate 能失敗)。
        let decelRate: CGFloat = grounded ? decel.ground : (inWater ? decel.water : decel.air)
        velocity.dx -= min(abs(velocity.dx), decelRate * dt) * sign(velocity.dx)
        velocity.dy -= min(abs(velocity.dy), decelRate * dt) * sign(velocity.dy)

        // 3. 歐氏逃逸帽 600(無軸速帽)。
        let speed = (velocity.dx * velocity.dx + velocity.dy * velocity.dy).squareRoot()
        if speed > EngineV2.escapeSpeedCap {
            let scale = EngineV2.escapeSpeedCap / speed
            velocity.dx *= scale
            velocity.dy *= scale
        }

        // 4. 位置積分。
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt

        // 5. 區域反應(側緣反彈、天花板、落地判定)。
        events.append(contentsOf: applyRegionReactions(regions: regions))

        // 6. NaN 防護(失控來源如 NaN 衝量;Debug trap / Release 夾停歸零)。
        guardAgainstNaN(fallback: lastGood)

        // 7. 區域轉換事件(依物種過濾的檢定;變更才發 left/entered)。
        let newRegion = Self.classify(profile: profile, position: position,
                                      grounded: grounded, regions: regions)
        if newRegion != region {
            events.append(.leftRegion(region))
            events.append(.enteredRegion(newRegion))
            region = newRegion
        }
        return events
    }

    // MARK: - 區域反應(著地分級門檻為 V2Tuning 自選值,非凍結)

    private func applyRegionReactions(regions: RegionMap) -> [MotionEvent] {
        var events: [MotionEvent] = []
        let vf = regions.bounds

        // 側緣:夾回 + 能量係數反彈(0.55)。
        if position.x < vf.minX {
            position.x = vf.minX
            velocity.dx = abs(velocity.dx) * EngineV2.bounceEnergy
        } else if position.x > vf.maxX {
            position.x = vf.maxX
            velocity.dx = -abs(velocity.dx) * EngineV2.bounceEnergy
        }

        // 天花板:夾回 + 向下反彈。Flyer 用 range% 封套的(可能較低)天花板;
        // walker/swimmer 仍用 vf.maxY —— 封套絕不下修其他物種的界。
        let ceilingY = (profile == .flyer) ? regions.flyer.ceiling : vf.maxY
        if position.y > ceilingY {
            position.y = ceilingY
            velocity.dy = -abs(velocity.dy) * EngineV2.bounceEnergy
        }

        // 地板(全部物種的最低界 = 地面線;Swimmer 即水底沉底)。
        if position.y <= regions.groundY, velocity.dy <= 0 {
            let impact = abs(velocity.dy)
            position.y = regions.groundY
            if grounded {
                velocity.dy = 0   // 靜置:持續夾在地面線,不重發事件。
            } else if impact < V2Tuning.softLandingSpeed {
                velocity.dy = 0
                grounded = true
                events.append(.dropped(.soft))
            } else if impact < V2Tuning.bounceLandingSpeed {
                velocity.dy = impact * EngineV2.bounceEnergy   // 反彈:保持空中,能量 0.55。
                events.append(.dropped(.bounce))
            } else {
                velocity.dy = 0
                grounded = true
                events.append(.dropped(.hard))
            }
        }

        // 起飛:接地中獲得向上速度(衝量)即離地。
        if grounded, velocity.dy > 0 {
            grounded = false
        }
        return events
    }

    /// 區域檢定(依物種過濾):Walker/Flyer 只分 ground/air;Swimmer 以水帶分 water/air。
    private static func classify(profile: LocomotionProfile, position: CGPoint,
                                 grounded: Bool, regions: RegionMap) -> RegionKind {
        switch profile {
        case .walker, .flyer:
            return grounded ? .ground : .air
        case .swimmer:
            return position.y <= regions.water.maxY ? .water : .air
        }
    }

    // MARK: - NaN 防護

    private func guardAgainstNaN(fallback: CGPoint) {
        guard !position.x.isFinite || !position.y.isFinite
            || !velocity.dx.isFinite || !velocity.dy.isFinite else { return }
        let detail = "pos=\(position) v=\(velocity)"
        // 兩種模式皆復原(Debug trap 預設 assertionFailure 會先中止;測試注入 spy 後可驗證復原)。
        position = CGPoint(x: fallback.x.isFinite ? fallback.x : 0,
                           y: fallback.y.isFinite ? fallback.y : 0)
        velocity = .zero
        nanRecoveryCount += 1
        switch nanHandling {
        case .debugTrap:
            nanTrap(detail)
        case .recoverAndCount:
            NSLog("EngineV2 MotionController NaN recovered (#%d): %@", nanRecoveryCount, detail)
        }
    }

    private func sign(_ x: CGFloat) -> CGFloat {
        x > 0 ? 1 : (x < 0 ? -1 : 0)
    }
}
