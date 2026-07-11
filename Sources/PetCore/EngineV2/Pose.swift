import Foundation
import CoreGraphics

// MARK: - PosePresenter 契約(§8 凍結;R2-F6 單一寫入者)

public struct ComposedPose: Sendable {
    public var position: CGPoint
    public var action: PetActionID
    public var frameIndex: Int
    public var anchorOffset: CGPoint
    public var mirrored: Bool

    public init(position: CGPoint, action: PetActionID, frameIndex: Int,
                anchorOffset: CGPoint, mirrored: Bool) {
        self.position = position
        self.action = action
        self.frameIndex = frameIndex
        self.anchorOffset = anchorOffset
        self.mirrored = mirrored
    }
}

/// 幀交換原子性:pose+anchor+sprite 每 tick 恰以單一 commit 落地。
public protocol PosePresenting: AnyObject {
    func commit(_ pose: ComposedPose)
}

// MARK: - Flyer 懸停控制(行為層拍翅;不出 hover 帶)

/// 決定本 tick 是否拍翅:僅在下墜且「煞車距離」觸及 hover 下緣時施加 +220 衝量。
/// 煞車距離 = 連續每 tick 拍翅可挽回的下墜行程(保守高估:忽略順向的空氣阻尼),
/// margin = 單 tick 最大下墜(600×dt)+ 餘裕(V2Tuning 自選),吸收離散 tick 的過衝。
public struct HoverController: Sendable {
    public init() {}

    public func flapImpulse(state: MotionState, regions: RegionMap, dt: TimeInterval) -> CGVector? {
        guard !state.grounded, state.velocity.dy <= 0 else { return nil }
        let dtC = CGFloat(min(max(dt, 0), EngineV2.dtCap))
        guard dtC > 0 else { return nil }
        let fallSpeed = -state.velocity.dy
        let flap = CGVector(dx: 0, dy: EngineV2.flapImpulse)
        // 每 tick 淨挽回速度(拍翅 − 該 tick 重力);dt 極大時直接拍。
        let gainPerTick = EngineV2.flapImpulse - EngineV2.gravity * dtC
        guard gainPerTick > 0 else { return flap }
        let brakingDistance = (fallSpeed * fallSpeed / (2 * gainPerTick) + fallSpeed) * dtC
        let margin = EngineV2.escapeSpeedCap * dtC + V2Tuning.hoverFlapMargin
        if state.position.y - brakingDistance <= regions.hover.lowerBound + margin {
            return flap
        }
        return nil
    }
}

// MARK: - 深閒置節流(§2.1 timer 必須 invalidate;§2.2 quiet/dock 10s 迷你路徑)

/// 純邏輯的 tick 節流器:Bridge 於 tick 與相位輸入變更時詢問 `directive`,
/// 依指令 invalidate / 重掛 timer。
/// - 深閒置(睡眠):進入 ≥5s 停表(E0 硬閘;邏輯測試斷言 ≤5s)。
/// - quiet/dock 迷你路徑:進入 **10s** 後才等同深閒置停表(計畫 §2.2 R2-F10 定案;
///   FIX-3 —— 早前版本誤以 5s 一體適用,測試同步更正)。
/// 停表後僅保留 usage 訊號監聽,無動畫 tick。
public struct IdleGovernor: Sendable {
    public enum Phase: Equatable, Sendable {
        case active, sleeping, docked
    }

    /// timer 指令(FIX-1 re-arm 路徑的純邏輯核心;Bridge 依此掛/停表)。
    public enum TimerDirective: Equatable, Sendable {
        case keep, stop, arm
    }

    /// 深閒置(睡眠)進入後至停表的延遲(秒);E0 硬閘,測試斷言 ≤5s。
    public static let sleepStopDelay: TimeInterval = 5
    /// quiet/dock 迷你路徑進入後至停表的延遲(秒);計畫 §2.2 凍結 10s。
    public static let dockStopDelay: TimeInterval = 10

    public private(set) var phase: Phase = .active
    private var phaseStart: Date

    public init(now: Date = Date()) {
        phaseStart = now
    }

    /// 設定相位;同相位重複設定不重置起算點(睡眠持續時間才會累積)。
    public mutating func setPhase(_ newPhase: Phase, at now: Date) {
        guard newPhase != phase else { return }
        phase = newPhase
        phaseStart = now
    }

    public func shouldTick(at now: Date) -> Bool {
        switch phase {
        case .active:
            return true
        case .sleeping:
            return now.timeIntervalSince(phaseStart) < Self.sleepStopDelay
        case .docked:
            return now.timeIntervalSince(phaseStart) < Self.dockStopDelay
        }
    }

    /// timer 應維持 / 停止 / 重掛(FIX-1 re-arm):
    /// - 有表且不該 tick → `.stop`(invalidate;深閒置 CPU 守則)
    /// - 無表且該 tick → `.arm`(喚醒/quiet 關閉/相位回 active 的重掛路徑)
    /// - 其餘 → `.keep`(含「停著就別動」:無表且仍不該 tick)
    public func directive(timerArmed: Bool, at now: Date) -> TimerDirective {
        let shouldRun = shouldTick(at: now)
        if timerArmed { return shouldRun ? .keep : .stop }
        return shouldRun ? .arm : .keep
    }
}

// MARK: - EngineLoop(單一寫入者:motion 位姿 × 行為幀 × overlay 覆寫 → 每 tick 單一 commit)

/// 引擎核心編排(純邏輯;Bridge 只負責 dt 供給與 NSPanel 寫入):
/// 1. 互動車道(E1 取法 A 案):佇列請求即刻搶佔 graph flavor;拖曳期間凍結佇列。
/// 2. 行為 lane:動作播畢 → BehaviorGraph 抽下一動作(overlay = mood 重塑,改變 moodTier)。
/// 3. 運動 glue:Flyer 懸停拍翅 / Swimmer 水中漂游目標速度(皆於物理 tick 前施加)。
/// 4. MotionController.tick(凍結積分律)。
/// 5. 雙車道仲裁:使用者互動(拖曳)搶佔隨機行為(全域優先表)。
/// 6. PosePresenter.commit — 每 tick 恰一次。
public final class EngineLoop {
    public let motion: MotionController
    public let pack: SpeciesPack
    private let graph: BehaviorGraph
    private let registry: PackRegistry
    private var rng: any RandomNumberGenerator
    private let hover = HoverController()

    public weak var presenter: PosePresenting?

    /// 全域遮罩(reduce-motion / quiet);逐動作停用另以集合傳遞。
    /// FIX-8:遮罩同時鎖「行為圖」與「運動 glue」(見 tick 階段 3)。
    public var masks: BehaviorMasks = []
    /// 引擎運動總開關(FIX-9:Bridge 每 tick 對映 settings.petWanderEnabled)。
    /// false = 姿勢照常播放(行為圖與 overlay 不受影響),但不施加任何巡航/拍翅/
    /// 漂游 —— 位置原地不動(懸空者仍受重力落定)。預設 true(純邏輯測試直接驅動)。
    public var locomotionEnabled = true
    /// 使用者停用的動作集合(自 available 剔除)。
    public var disabledActions: Set<PetActionID> = []
    /// overlay 覆寫(E0 僅 working1 一態示範):mood 重塑 — 把 moodTier 拉向該動作的 tier,
    /// 使 graph 的距離衰減偏好該態;不硬搶佔(transient 屬 E3)。
    public var overlay: PetActionID?

    public private(set) var currentAction: PetActionID = .idle
    private var actionElapsed: TimeInterval = 0
    private var dragging = false
    /// 互動車道佇列(E1 graft;空佇列 = 行為位元不變)。
    private var interactions = InteractionLane()
    /// Walker 巡航朝向(±1;FIX-6):首次進入 walk 時由 seeded rng 擲籤(lazy —
    /// 非 walker 包完全不消耗 rng,飛/游物種的既有決定性串流位元不變),
    /// 之後**僅**在觸及水平邊界時回頭(不再擲籤)。
    private var heading: CGFloat?

    /// 每幀時長(自選值單一出處在 V2Tuning;此為既有公開別名)。
    public static let frameDuration: TimeInterval = V2Tuning.frameDuration

    public init(pack: SpeciesPack, registry: PackRegistry = PackRegistry(),
                position: CGPoint, regions: RegionMap, seed: UInt64) {
        self.pack = pack
        self.registry = registry
        registry.register(pack)
        graph = BehaviorGraph(table: pack.behavior)
        rng = SeededRNG(seed: seed)
        motion = MotionController(profile: pack.locomotion, position: position, regions: regions)
    }

    // MARK: 拖曳轉發(互動車道)

    public func beginDrag(at point: CGPoint) {
        dragging = true
        motion.beginDrag(at: point)
    }

    public func dragMoved(to point: CGPoint, dt: TimeInterval) {
        motion.dragMoved(to: point, dt: dt)
    }

    public func endDrag() {
        dragging = false
        motion.endDrag()
    }

    /// 外部互動(點擊/餵食等)排入互動車道;下個 tick 即刻搶佔 graph flavor。
    /// 拖曳走 beginDrag(同車道內更即時的互動),佇列請求在放手後才被消化。
    /// 【E3 預告 · 雙審裁定延後】滑鼠事件 → DragRecognizer → 本入口的 Bridge 接線
    /// 屬參與感包(E3)互動範圍;flag 預設關,E1 僅測試與未來接線使用,非缺陷。
    public func noteInteraction(_ action: PetActionID) {
        interactions.enqueue(action)
    }

    // MARK: tick

    @discardableResult
    public func tick(dt: TimeInterval, regions: RegionMap) -> [MotionEvent] {
        // 1. 互動車道(E1 取法 A 案):每 tick 至多消化一件,即刻搶佔目前動作
        //    (GlobalPriority:userInteraction > graphFlavor;不等 graph 動作播畢)。
        if !dragging, let queued = interactions.dequeue() {
            currentAction = queued
            actionElapsed = 0
        }

        // 2. 行為 lane:目前動作播畢才轉移(拖曳中凍結行為推進)。
        if !dragging {
            actionElapsed += dt
            let frameCount = max(1, resolvedFrames(for: currentAction).count)
            if actionElapsed >= Self.frameDuration * Double(frameCount) {
                actionElapsed = 0
                // overlay = mood 重塑:目標 tier 取 overlay 動作的 tier(預設 1)。
                let moodTier = overlay.map { pack.behavior.moodTier[$0] ?? 1 } ?? 0
                currentAction = graph.next(after: currentAction, moodTier: moodTier,
                                           masks: masks, available: availableActions(),
                                           region: motion.region, rng: &rng)
            }

            // 3. 運動 glue(行為層,於物理 tick 前施加)。
            // FIX-8:quiet/reduce-motion 也要鎖運動 —— 行為圖已收斂 idle,運動層
            // 若繼續拍翅/漂游即違反 §3-B 靜態姿勢集(a11y)。FIX-9:petWanderEnabled
            // =false 同樣鎖運動(姿勢照播、原地不動)。兩者皆:零衝量 + 清除目標;
            // reduce-motion 再硬性歸零速度,立即落定(重力/著地 settle 照常,不懸浮)。
            if !locomotionEnabled || !masks.isDisjoint(with: [.quiet, .reduceMotion]) {
                motion.setTargetVelocity(nil)
                if masks.contains(.reduceMotion) {
                    motion.cancelMomentum()
                }
            } else {
                switch pack.locomotion {
                case .flyer:
                    if motion.state.grounded {
                        // FIX-5:地面起飛 —— 行為抽中 flyFlap 而仍接地時,施加凍結 +220
                        // 一次性起飛衝量;升空即清除 grounded(不會連發),空中交回懸停控制。
                        // 沒有這條,著地(grounded=true)後 HoverController 恆回 nil、
                        // air 條件邊全遭遮罩 → 鳥著地一次即永久軟鎖。
                        if currentAction == .flyFlap {
                            motion.applyImpulse(CGVector(dx: 0, dy: EngineV2.flapImpulse))
                        }
                    } else if let flap = hover.flapImpulse(state: motion.state, regions: regions,
                                                           dt: dt) {
                        motion.applyImpulse(flap)
                    }
                case .swimmer:
                    motion.setTargetVelocity(
                        motion.region == .water ? CGVector(dx: EngineV2.swimmerDrift, dy: 0) : nil)
                case .walker:
                    // FIX-6:walk 動作 → ±cruise 36 px/s 水平巡航(§5);非 walk 清除目標,
                    // 沿凍結減速律自然停下。首次 walk 擲籤定初始朝向;之後僅在觸及
                    // 水平邊界時回頭(決定性,不再擲籤)。向左位移的鏡像由 compose
                    // 依 pack.mirrorSafe 裁決(狗/貓沿 legacy 全 sprite 翻轉,皆 mirror-safe)。
                    if currentAction == .walk {
                        if heading == nil { heading = rng.next() & 1 == 0 ? 1 : -1 }
                        if motion.state.position.x <= regions.bounds.minX { heading = 1 }
                        if motion.state.position.x >= regions.bounds.maxX { heading = -1 }
                        motion.setTargetVelocity(CGVector(dx: EngineV2.walkerCruise * (heading ?? 1),
                                                          dy: 0))
                    } else {
                        motion.setTargetVelocity(nil)
                    }
                }
            }
        }

        // 4. 物理積分(凍結律)。
        let events = motion.tick(dt: dt, regions: regions)

        // 5. 雙車道仲裁(全域優先表):拖曳=活躍的 userInteraction 車道,搶佔 graph flavor
        //    顯示槽;佇列互動已在階段 1 直接接管 currentAction,顯示走 graph 路徑即可。
        let lanes: Set<GlobalPriority> = dragging ? [.userInteraction, .graphFlavor] : [.graphFlavor]
        let displayAction: PetActionID
        if GlobalPriority.winner(lanes) == .userInteraction {
            // 拖曳態:drag 槽缺幀時沿 fallback(如魚類以 float 頂替)。
            displayAction = registry.resolve(.drag, in: pack)
        } else {
            displayAction = registry.resolve(currentAction, in: pack)
        }

        // 6. 單一寫入者 commit(每 tick 恰一次)。
        let frames = pack.frames[displayAction] ?? []
        let frameIndex = frames.isEmpty ? 0
            : Int(actionElapsed / Self.frameDuration) % frames.count
        let pose = ComposedPose(
            position: motion.presentedPosition,
            action: displayAction,
            frameIndex: frameIndex,
            anchorOffset: pack.anchorOffsets[displayAction] ?? .zero,
            mirrored: motion.state.velocity.dx < 0 && pack.mirrorSafe.contains(displayAction))
        presenter?.commit(pose)
        return events
    }

    // MARK: 私有

    private func resolvedFrames(for action: PetActionID) -> [String] {
        pack.frames[registry.resolve(action, in: pack)] ?? []
    }

    /// 可用動作 = 有幀的槽位 − 使用者停用(缺動畫/停用「集合另傳」進 graph)。
    private func availableActions() -> Set<PetActionID> {
        var available = Set(pack.frames.filter { !$0.value.isEmpty }.keys)
        available.subtract(disabledActions)
        return available
    }
}
