import Foundation
import CoreGraphics
import PetCore

// EngineV2(petEngineV2 flag 後的新引擎)測試。
// Golden set A 期望表為 M2_E0_PACKET §6 凍結 fixtures(由凍結積分律手算),逐 tick ±0。

// MARK: - 共用小工具

/// 無界平面:巨大 visibleFrame,使區域反應在測試視窗內為 no-op(§6 前提)。
private func unboundedRegions() -> RegionMap {
    RegionMap(visibleFrame: CGRect(x: -1e9, y: -1e9, width: 2e9, height: 2e9))
}

/// 標準測試螢幕(800×600,原點 0,0)。
private func standardRegions() -> RegionMap {
    RegionMap(visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
}

private func makeFlyer(at position: CGPoint, regions: RegionMap) -> MotionController {
    MotionController(profile: .flyer, position: position, regions: regions)
}

/// Pose 間諜:驗證單一寫入者「每 tick 恰一次 commit」。
private final class PoseSpy: PosePresenting {
    var poses: [ComposedPose] = []
    func commit(_ pose: ComposedPose) { poses.append(pose) }
}

// MARK: - Golden set A(§6;dt=1/30、Flyer、air、pos0=(0,400)、呈現取整 ±0)

final class EngineV2GoldenSetATests: XCTestCase {
    private let dt = 1.0 / 30.0

    /// (a) 自由落體 10 tick,v0=(0,0)。
    func testFreeFall() throws {
        let regions = unboundedRegions()
        let motion = makeFlyer(at: CGPoint(x: 0, y: 400), regions: regions)
        let expectedY: [CGFloat] = [399, 397, 395, 391, 387, 382, 376, 369, 361, 352]
        for (i, expected) in expectedY.enumerated() {
            _ = motion.tick(dt: dt, regions: regions)
            XCTAssertEqual(motion.presentedPosition.y, expected, "tick \(i + 1) y")
            XCTAssertEqual(motion.presentedPosition.x, 0, "tick \(i + 1) x 恆 0")
        }
    }

    /// (b) 水平滑翔 10 tick,v0=(120,0)。
    func testHorizontalGlide() throws {
        let regions = unboundedRegions()
        let motion = makeFlyer(at: CGPoint(x: 0, y: 400), regions: regions)
        motion.applyImpulse(CGVector(dx: 120, dy: 0))
        let expected: [(CGFloat, CGFloat)] = [
            (4, 399), (8, 397), (11, 395), (15, 391), (18, 387),
            (21, 382), (24, 376), (27, 369), (30, 361), (33, 352),
        ]
        for (i, point) in expected.enumerated() {
            _ = motion.tick(dt: dt, regions: regions)
            XCTAssertEqual(motion.presentedPosition.x, point.0, "tick \(i + 1) x")
            XCTAssertEqual(motion.presentedPosition.y, point.1, "tick \(i + 1) y")
        }
    }

    /// (c) flap 弧 8 tick,v0=(0,0),tick 1 前施加一次性 +220 y 衝量(非預含於 v0)。
    func testFlapArc() throws {
        let regions = unboundedRegions()
        let motion = makeFlyer(at: CGPoint(x: 0, y: 400), regions: regions)
        motion.applyImpulse(CGVector(dx: 0, dy: 220))   // one-shot pre-tick 事件
        let expectedY: [CGFloat] = [406, 411, 415, 418, 420, 420, 420, 419]
        for (i, expected) in expectedY.enumerated() {
            _ = motion.tick(dt: dt, regions: regions)
            XCTAssertEqual(motion.presentedPosition.y, expected, "tick \(i + 1) y")
            XCTAssertEqual(motion.presentedPosition.x, 0, "tick \(i + 1) x 恆 0")
        }
    }

    /// (d) 逃逸帽 1 tick,v0=(900,900) → (14,414);帽為歐氏(g→decel→cap 順序)。
    func testEscapeCap() throws {
        let regions = unboundedRegions()
        let motion = makeFlyer(at: CGPoint(x: 0, y: 400), regions: regions)
        motion.applyImpulse(CGVector(dx: 900, dy: 900))
        _ = motion.tick(dt: dt, regions: regions)
        XCTAssertEqual(motion.presentedPosition.x, 14, "tick 1 x")
        XCTAssertEqual(motion.presentedPosition.y, 414, "tick 1 y")
        let v = motion.state.velocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        XCTAssertTrue(speed <= 600.0 + 1e-9, "逃逸帽後歐氏速度 ≤600,實得 \(speed)")
    }
}

// MARK: - Golden set B(決定性:同 seed 兩 run 位元一致)+ xorshift64* 規格釘值

final class EngineV2DeterminismTests: XCTestCase {

    /// xorshift64* 已知值(獨立以凍結演算法離線推得,釘住實作)。
    func testXorshiftKnownValues() throws {
        var rng = SeededRNG(seed: 1)
        XCTAssertEqual(rng.next(), 0x47E4_CE4B_896C_DD1D)
        XCTAssertEqual(rng.next(), 0xABCF_A6A8_E079_651D)
        XCTAssertEqual(rng.next(), 0xB9D1_0D8F_EB73_1F57)
        var rng42 = SeededRNG(seed: 42)
        XCTAssertEqual(rng42.next(), 0x56CE_4AB7_719B_A3A0)
        // seed 0 為非法:以固定常數替代,仍為決定性且非吸收態。
        var rng0 = SeededRNG(seed: 0)
        XCTAssertTrue(rng0.next() != 0, "seed 0 不得落入吸收態")
    }

    /// 行為圖決定性:同 seed + 同輸入序列 → 動作序列完全一致。
    func testBehaviorGraphSameSeedBitIdentical() throws {
        func run(seed: UInt64) -> [String] {
            let graph = BehaviorGraph(table: SpeciesPacks.birdPack().behavior)
            var rng: any RandomNumberGenerator = SeededRNG(seed: seed)
            let available: Set<PetActionID> = [.idle, .flyFlap, .glide, .working1]
            var current = PetActionID.idle
            var sequence: [String] = []
            for step in 0..<300 {
                let region: RegionKind = step % 7 == 0 ? .ground : .air
                current = graph.next(after: current, moodTier: step % 11 == 0 ? 1 : 0,
                                     masks: [], available: available, region: region, rng: &rng)
                sequence.append(current.rawValue)
            }
            return sequence
        }
        XCTAssertEqual(run(seed: 42), run(seed: 42), "同 seed 兩 run 必須位元一致")
        XCTAssertTrue(run(seed: 42) != run(seed: 43), "異 seed 應得不同序列(非退化)")
    }

    /// 全引擎迴圈決定性:同 seed 兩 run 的 pose 串流(位置/動作/幀)位元一致。
    func testEngineLoopSameSeedBitIdentical() throws {
        func run() -> [(CGFloat, CGFloat, String, Int, Bool)] {
            let regions = standardRegions()
            let spy = PoseSpy()
            let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                                  position: CGPoint(x: 400, y: 350), regions: regions, seed: 7)
            loop.presenter = spy
            for _ in 0..<400 { loop.tick(dt: 1.0 / 30, regions: regions) }
            return spy.poses.map { ($0.position.x, $0.position.y, $0.action.rawValue,
                                    $0.frameIndex, $0.mirrored) }
        }
        let a = run()
        let b = run()
        XCTAssertEqual(a.count, b.count)
        for i in 0..<min(a.count, b.count) {
            XCTAssertTrue(a[i] == b[i], "tick \(i) pose 不一致:\(a[i]) vs \(b[i])")
        }
    }

    /// 物理決定性:同腳本(衝量+dt 序列)兩 run 位置位元一致(Double ==)。
    func testMotionSameScriptBitIdentical() throws {
        func run() -> [CGPoint] {
            let regions = standardRegions()
            let motion = makeFlyer(at: CGPoint(x: 100, y: 300), regions: regions)
            var rng: any RandomNumberGenerator = SeededRNG(seed: 99)
            var track: [CGPoint] = []
            for step in 0..<200 {
                if step % 13 == 0 {
                    let dx = Double(rng.next() >> 11) * 0x1p-53 * 80 - 40
                    motion.applyImpulse(CGVector(dx: dx, dy: 180))
                }
                _ = motion.tick(dt: 1.0 / 30, regions: regions)
                track.append(motion.state.position)
            }
            return track
        }
        let a = run()
        let b = run()
        for i in 0..<min(a.count, b.count) {
            XCTAssertTrue(a[i].x == b[i].x && a[i].y == b[i].y, "tick \(i) 位置位元不一致")
        }
    }
}

// MARK: - RegionMap 幾何(§4 凍結公式;含矮螢幕必過)

final class EngineV2RegionMapTests: XCTestCase {

    func testGeometryFormulas() throws {
        let vf = CGRect(x: 50, y: 25, width: 1200, height: 875)
        let map = RegionMap(visibleFrame: vf)
        // lower = min(80, 0.22×875=192.5) = 80;waterH = clamp(157.5, 80, 192.5) = 157.5。
        XCTAssertEqual(map.water, CGRect(x: 50, y: 25, width: 1200, height: 157.5))
        XCTAssertEqual(map.groundY, 25)
        XCTAssertEqual(map.airMinY, map.water.maxY)
        let airH = vf.maxY - map.airMinY
        XCTAssertEqual(map.hover.lowerBound, map.airMinY + 0.40 * airH, accuracy: 1e-9)
        XCTAssertEqual(map.hover.upperBound, map.airMinY + 0.80 * airH, accuracy: 1e-9)
        XCTAssertEqual(map.bounds, vf)
    }

    /// 矮螢幕(vf.height < 364pt)degenerate:水帶永不空、底對齊。
    func testShortScreenWaterBandNeverEmpty() throws {
        for height in [364.0, 300.0, 100.0, 40.0] {
            let map = RegionMap(visibleFrame: CGRect(x: 0, y: 0, width: 640, height: height))
            let lower = min(80.0, 0.22 * height)
            let expected = min(max(0.18 * height, lower), 0.22 * height)
            XCTAssertEqual(map.water.height, expected, accuracy: 1e-9, "height=\(height)")
            XCTAssertTrue(map.water.height > 0, "水帶永不空 (height=\(height))")
            XCTAssertEqual(map.water.minY, 0, "水帶底對齊")
            XCTAssertTrue(map.hover.lowerBound <= map.hover.upperBound, "hover 帶有效")
        }
        // 364pt:0.18H=65.52 < lower=80 → 夾到 80。
        let short = RegionMap(visibleFrame: CGRect(x: 0, y: 0, width: 640, height: 364))
        XCTAssertEqual(short.water.height, 80, accuracy: 1e-9)
    }
}

// MARK: - 必過情境(§7 Stage-1 定性)

final class EngineV2MotionScenarioTests: XCTestCase {
    private let dt = 1.0 / 30.0

    /// drag→甩→軟著地:著地反應觸發 dropped(.soft)。
    func testDragFlingSoftLanding() throws {
        let regions = standardRegions()
        let motion = MotionController(profile: .walker, position: CGPoint(x: 200, y: 80),
                                      regions: regions)
        // 點擊 vs 拖曳判定(§5:≥4px 且 ≥120ms)。
        XCTAssertTrue(EngineV2.isDrag(distance: 4, duration: 0.12))
        XCTAssertFalse(EngineV2.isDrag(distance: 3.9, duration: 0.5))
        XCTAssertFalse(EngineV2.isDrag(distance: 40, duration: 0.119))

        motion.beginDrag(at: CGPoint(x: 200, y: 80))
        // 拖曳中物理暫停:位置完全由外部驅動。
        _ = motion.tick(dt: dt, regions: regions)
        XCTAssertEqual(motion.state.position.y, 80, "拖曳中不受重力")
        motion.dragMoved(to: CGPoint(x: 240, y: 10), dt: 0.5)   // 緩慢放低(注入小速度)
        motion.endDrag()

        var events: [MotionEvent] = []
        for _ in 0..<120 { events.append(contentsOf: motion.tick(dt: dt, regions: regions)) }
        XCTAssertTrue(events.contains(.dropped(.soft)), "低速放手應軟著地,實得 \(events)")
        XCTAssertTrue(motion.state.grounded, "著地後接地")
        XCTAssertEqual(motion.state.position.y, regions.groundY, "停在地面線")
        XCTAssertTrue(events.contains(.enteredRegion(.ground)), "著地發 enteredRegion(ground)")
    }

    /// 甩出:速度經逃逸帽(≤600)、彈跳鏈以 0.55 能量衰減、最終著地接地。
    func testHardFlingCapsAndEventuallyLands() throws {
        let regions = standardRegions()
        let motion = MotionController(profile: .walker, position: CGPoint(x: 400, y: 200),
                                      regions: regions)
        motion.beginDrag(at: CGPoint(x: 400, y: 200))
        motion.dragMoved(to: CGPoint(x: 460, y: 250), dt: 0.016)   // 猛甩:注入超高速度
        motion.endDrag()
        var events: [MotionEvent] = []
        var sawCapRespected = true
        for _ in 0..<600 {
            events.append(contentsOf: motion.tick(dt: dt, regions: regions))
            let v = motion.state.velocity
            if (v.dx * v.dx + v.dy * v.dy).squareRoot() > 600.0 + 1e-9 { sawCapRespected = false }
        }
        XCTAssertTrue(sawCapRespected, "任何 tick 後歐氏速度都不得超過 600")
        XCTAssertTrue(events.contains(where: {
            if case .dropped = $0 { return true } else { return false }
        }), "甩出後應有著地事件")
        XCTAssertTrue(motion.state.grounded, "最終應靜置接地")
        // 側緣反彈不出界。
        XCTAssertTrue(motion.state.position.x >= regions.bounds.minX
                      && motion.state.position.x <= regions.bounds.maxX)
    }

    /// 大 dt(>0.25s)夾限:結果與 dt=0.25 位元一致。
    func testLargeDTClamped() throws {
        let regions = unboundedRegions()
        let a = makeFlyer(at: CGPoint(x: 0, y: 400), regions: regions)
        let b = makeFlyer(at: CGPoint(x: 0, y: 400), regions: regions)
        _ = a.tick(dt: 5.0, regions: regions)     // 喚醒後大 dt
        _ = b.tick(dt: 0.25, regions: regions)
        XCTAssertTrue(a.state.position == b.state.position, "dt=5 必須夾限為 0.25")
        // 手算:v=-900×0.25=-225 → decel 空中 min(225,30)=30 → -195 → y=400-48.75=351.25 → 351。
        XCTAssertEqual(a.presentedPosition.y, 351)
        XCTAssertEqual(a.state.position.y, 351.25, accuracy: 0)
    }

    /// NaN 防護 — Release 模式:夾停歸零 + 計數,絕不 crash。
    func testNaNReleaseModeRecovers() throws {
        let regions = standardRegions()
        let motion = makeFlyer(at: CGPoint(x: 100, y: 300), regions: regions)
        motion.nanHandling = .recoverAndCount
        motion.applyImpulse(CGVector(dx: CGFloat.nan, dy: 0))
        _ = motion.tick(dt: dt, regions: regions)
        XCTAssertTrue(motion.state.position.x.isFinite && motion.state.position.y.isFinite,
                      "復原後位置有限")
        XCTAssertEqual(motion.state.velocity.dx, 0, "夾停歸零")
        XCTAssertEqual(motion.state.velocity.dy, 0, "夾停歸零")
        XCTAssertEqual(motion.nanRecoveryCount, 1, "計數一次")
        // 後續 tick 正常(不留毒)。
        _ = motion.tick(dt: dt, regions: regions)
        XCTAssertTrue(motion.state.position.y.isFinite)
        XCTAssertEqual(motion.nanRecoveryCount, 1, "健康 tick 不再計數")
    }

    /// NaN 防護 — Debug 模式:trap 掛鉤觸發(預設 assertionFailure;測試注入 spy 觀測)。
    func testNaNDebugModeTraps() throws {
        let regions = standardRegions()
        let motion = makeFlyer(at: CGPoint(x: 100, y: 300), regions: regions)
        motion.nanHandling = .debugTrap
        var trapped: [String] = []
        motion.nanTrap = { trapped.append($0) }
        motion.applyImpulse(CGVector(dx: 0, dy: CGFloat.infinity))
        _ = motion.tick(dt: dt, regions: regions)
        XCTAssertEqual(trapped.count, 1, "Debug trap 應觸發一次")
        XCTAssertTrue(motion.state.velocity.dy == 0, "trap 後仍復原(測試環境不中止)")
    }

    /// 天花板與側緣:夾回邊界並以 0.55 能量反彈。
    func testCeilingAndWallBounce() throws {
        let regions = standardRegions()
        let motion = makeFlyer(at: CGPoint(x: 790, y: 590), regions: regions)
        motion.applyImpulse(CGVector(dx: 400, dy: 400))
        _ = motion.tick(dt: dt, regions: regions)
        XCTAssertTrue(motion.state.position.x <= regions.bounds.maxX, "不出右緣")
        XCTAssertTrue(motion.state.position.y <= regions.bounds.maxY, "不出天花板")
        XCTAssertTrue(motion.state.velocity.dx <= 0, "側緣反彈朝內")
        XCTAssertTrue(motion.state.velocity.dy <= 0, "天花板反彈朝下")
    }
}

// MARK: - Flyer 懸停 / Swimmer 出水(§7 必過)

final class EngineV2ProfileScenarioTests: XCTestCase {
    private let dt = 1.0 / 30.0

    /// flyer 懸停不出 hover 帶:自帶中點起 600 tick,模擬座標恆在帶內(雙端含)。
    func testFlyerHoverStaysInBand() throws {
        let regions = standardRegions()
        let hover = HoverController()
        let mid = (regions.hover.lowerBound + regions.hover.upperBound) / 2
        let motion = makeFlyer(at: CGPoint(x: 400, y: mid), regions: regions)
        for i in 0..<600 {
            if let flap = hover.flapImpulse(state: motion.state, regions: regions, dt: dt) {
                motion.applyImpulse(flap)   // 行為層拍翅(one-shot,物理 tick 前)
            }
            _ = motion.tick(dt: dt, regions: regions)
            let y = motion.state.position.y
            XCTAssertTrue(regions.hover.contains(y),
                          "tick \(i):y=\(y) 出帶 [\(regions.hover.lowerBound), \(regions.hover.upperBound)]")
            if !regions.hover.contains(y) { break }   // 首次出帶即停,避免刷屏
        }
    }

    /// 矮螢幕的 hover 帶同樣關得住(§4 degenerate 幾何 × 懸停行為)。
    func testFlyerHoverShortScreen() throws {
        let regions = RegionMap(visibleFrame: CGRect(x: 0, y: 0, width: 640, height: 364))
        let hover = HoverController()
        let mid = (regions.hover.lowerBound + regions.hover.upperBound) / 2
        let motion = makeFlyer(at: CGPoint(x: 320, y: mid), regions: regions)
        for i in 0..<600 {
            if let flap = hover.flapImpulse(state: motion.state, regions: regions, dt: dt) {
                motion.applyImpulse(flap)
            }
            _ = motion.tick(dt: dt, regions: regions)
            XCTAssertTrue(regions.hover.contains(motion.state.position.y), "tick \(i) 出帶")
            if !regions.hover.contains(motion.state.position.y) { break }
        }
    }

    /// swimmer 越界依宣告反應:出水適用重力 900,彈道回落水面;水中 g=0、decel 300 收斂。
    func testSwimmerLeavesWaterBallisticReturn() throws {
        let regions = standardRegions()   // waterH = clamp(108, 80, 132) = 108
        let motion = MotionController(profile: .swimmer, position: CGPoint(x: 400, y: 50),
                                      regions: regions)
        XCTAssertEqual(motion.region, .water, "出生於水帶")
        motion.applyImpulse(CGVector(dx: 0, dy: 520))   // 甩出水面
        var events: [MotionEvent] = []
        var maxY = motion.state.position.y
        for _ in 0..<900 {
            events.append(contentsOf: motion.tick(dt: dt, regions: regions))
            maxY = max(maxY, motion.state.position.y)
        }
        XCTAssertTrue(maxY > regions.water.maxY, "應衝出水面(maxY=\(maxY))")
        XCTAssertTrue(events.contains(.leftRegion(.water)), "出水事件")
        XCTAssertTrue(events.contains(.enteredRegion(.air)), "入空事件")
        XCTAssertTrue(events.contains(.leftRegion(.air)), "回落事件")
        XCTAssertTrue(events.contains(.enteredRegion(.water)), "回水事件")
        XCTAssertTrue(motion.state.position.y <= regions.water.maxY, "最終回到水帶")
        let v = motion.state.velocity
        XCTAssertTrue((v.dx * v.dx + v.dy * v.dy).squareRoot() < 30,
                      "水中 decel 300 應收斂(v=\(v))")
    }

    /// 水中無重力:靜止的 swimmer 恆浮不沉。
    func testSwimmerNeutralBuoyancy() throws {
        let regions = standardRegions()
        let motion = MotionController(profile: .swimmer, position: CGPoint(x: 400, y: 60),
                                      regions: regions)
        for _ in 0..<60 { _ = motion.tick(dt: dt, regions: regions) }
        XCTAssertEqual(motion.state.position.y, 60, "水中 g=0,原地漂浮")
    }

    /// walker 巡航目標速度(§5:36 px/s)由行為層施加、水平推進。
    func testWalkerCruiseTargetVelocity() throws {
        let regions = standardRegions()
        let motion = MotionController(profile: .walker, position: CGPoint(x: 100, y: 0),
                                      regions: regions)
        _ = motion.tick(dt: dt, regions: regions)   // 先著地(soft)
        XCTAssertTrue(motion.state.grounded)
        XCTAssertEqual(LocomotionProfile.walker.cruiseSpeed, EngineV2.walkerCruise)
        motion.setTargetVelocity(CGVector(dx: EngineV2.walkerCruise, dy: 0))
        let startX = motion.state.position.x
        for _ in 0..<30 { _ = motion.tick(dt: dt, regions: regions) }
        XCTAssertTrue(motion.state.position.x > startX + 10, "巡航應持續向右推進")
        XCTAssertTrue(motion.state.grounded, "巡航中保持接地")
    }
}

// MARK: - BehaviorGraph(遮罩 / mood 衰減 / 區域邊 / 雙車道優先表)

final class EngineV2BehaviorGraphTests: XCTestCase {

    private func makeTable() -> BehaviorTable {
        BehaviorTable(
            rows: [
                .idle: [
                    BehaviorEdge(next: .flyFlap, weight: 1),
                    BehaviorEdge(next: .working1, weight: 1),
                    BehaviorEdge(next: .glide, weight: 1, region: .air),
                ],
            ],
            moodTier: [.flyFlap: 0, .working1: 2, .glide: 0])
    }

    /// 遮罩後零權重列 fallback → idle(§7 必過):全部候選不可用。
    func testZeroWeightRowFallsBackToIdle() throws {
        let graph = BehaviorGraph(table: makeTable())
        var rng: any RandomNumberGenerator = SeededRNG(seed: 5)
        let next = graph.next(after: .idle, moodTier: 0, masks: [], available: [],
                              region: .air, rng: &rng)
        XCTAssertEqual(next, PetActionID.idle, "零權重列必回 idle")
        // 無此列(未知動作)亦回 idle。
        let unknown = graph.next(after: PetActionID(rawValue: "nope"), moodTier: 0, masks: [],
                                 available: [.flyFlap], region: .air, rng: &rng)
        XCTAssertEqual(unknown, PetActionID.idle)
    }

    /// quiet / reduce-motion 遮罩:graph flavor 全遮 → idle 靜態姿勢集。
    func testQuietAndReduceMotionMask() throws {
        let graph = BehaviorGraph(table: makeTable())
        var rng: any RandomNumberGenerator = SeededRNG(seed: 5)
        let all: Set<PetActionID> = [.flyFlap, .working1, .glide]
        XCTAssertEqual(graph.next(after: .idle, moodTier: 0, masks: [.quiet], available: all,
                                  region: .air, rng: &rng), PetActionID.idle)
        XCTAssertEqual(graph.next(after: .idle, moodTier: 0, masks: [.reduceMotion], available: all,
                                  region: .air, rng: &rng), PetActionID.idle)
    }

    /// 區域條件邊:region 不符的邊不可選(ground 時 glide 永不出現)。
    func testRegionConditionedEdges() throws {
        let graph = BehaviorGraph(table: makeTable())
        var rng: any RandomNumberGenerator = SeededRNG(seed: 11)
        for _ in 0..<200 {
            let next = graph.next(after: .idle, moodTier: 0, masks: [],
                                  available: [.glide], region: .ground, rng: &rng)
            XCTAssertEqual(next, PetActionID.idle, "ground 區僅剩 air 條件邊 → 零權重 → idle")
        }
        var picked = Set<String>()
        for _ in 0..<200 {
            picked.insert(graph.next(after: .idle, moodTier: 0, masks: [],
                                     available: [.glide, .flyFlap], region: .air,
                                     rng: &rng).rawValue)
        }
        XCTAssertTrue(picked.contains("glide"), "air 區 glide 邊可選")
    }

    /// mood tier 距離衰減 ×0.25/層:tier 差 2 → 權重 ×0.0625;
    /// 固定 seed 下抽樣頻率應貼近 0.0625/(1+1+0.0625) ≈ 5.9%(寬鬆帶)。
    func testMoodTierDistanceDecay() throws {
        let graph = BehaviorGraph(table: makeTable())
        var rng: any RandomNumberGenerator = SeededRNG(seed: 2026)
        let all: Set<PetActionID> = [.flyFlap, .working1, .glide]
        var counts: [String: Int] = [:]
        let draws = 4000
        for _ in 0..<draws {
            let next = graph.next(after: .idle, moodTier: 0, masks: [], available: all,
                                  region: .air, rng: &rng)
            counts[next.rawValue, default: 0] += 1
        }
        let workingShare = Double(counts["working1"] ?? 0) / Double(draws)
        XCTAssertTrue(workingShare > 0.02 && workingShare < 0.12,
                      "tier 距離 2 → 期望 ≈5.9%,實得 \(workingShare * 100)%")
        // mood tier 拉到 2:working1 變滿權重,鄰邊反被衰減 → 佔比翻轉過半。
        var counts2: [String: Int] = [:]
        for _ in 0..<draws {
            let next = graph.next(after: .idle, moodTier: 2, masks: [], available: all,
                                  region: .air, rng: &rng)
            counts2[next.rawValue, default: 0] += 1
        }
        let workingShare2 = Double(counts2["working1"] ?? 0) / Double(draws)
        XCTAssertTrue(workingShare2 > 0.7, "moodTier=2 時 working1 應成主導,實得 \(workingShare2 * 100)%")
    }

    /// 全域優先表(§3-B):exhausted > alert > 互動 > transient > 入睡/dock > graph flavor。
    func testGlobalPriorityOrder() throws {
        XCTAssertTrue(GlobalPriority.exhausted > .alert)
        XCTAssertTrue(GlobalPriority.alert > .userInteraction)
        XCTAssertTrue(GlobalPriority.userInteraction > .transient)
        XCTAssertTrue(GlobalPriority.transient > .sleepOrDock)
        XCTAssertTrue(GlobalPriority.sleepOrDock > .graphFlavor)
        XCTAssertEqual(GlobalPriority.winner([.graphFlavor, .userInteraction]), .userInteraction)
        XCTAssertEqual(GlobalPriority.winner([.exhausted, .alert, .transient]), .exhausted)
        XCTAssertNil(GlobalPriority.winner([]))
    }
}

// MARK: - Pack 契約(registry / fallback 鏈 / 假 pack / 佔位美術完整性)

final class EngineV2PackTests: XCTestCase {

    func testRegistryRegisterAndLookup() throws {
        let registry = PackRegistry()
        let bird = SpeciesPacks.birdPack()
        registry.register(bird)
        XCTAssertNotNil(registry.pack(id: "bird"))
        XCTAssertNil(registry.pack(id: "ghost-species"))
        XCTAssertEqual(registry.pack(id: "bird")?.locomotion, LocomotionProfile.flyer)
    }

    /// 鳥佔位包:24×24 網格全幀 well-formed(沿 PixelArtTests 慣例)、必要槽位齊備。
    func testBirdPackFramesWellFormed() throws {
        let bird = SpeciesPacks.birdPack()
        XCTAssertEqual(bird.gridWidth, 24)
        XCTAssertEqual(bird.gridHeight, 24)
        for slot in bird.requiredSlots {
            XCTAssertTrue(!(bird.frames[slot]?.isEmpty ?? true), "必要槽位 \(slot.rawValue) 缺幀")
        }
        for (action, frames) in bird.frames {
            XCTAssertTrue(!frames.isEmpty, "\(action.rawValue) 幀列表為空")
            for (i, frame) in frames.enumerated() {
                let rows = frame.split(separator: "\n", omittingEmptySubsequences: false)
                XCTAssertEqual(rows.count, bird.gridHeight, "\(action.rawValue)[\(i)] 列數")
                for row in rows {
                    XCTAssertEqual(row.count, bird.gridWidth, "\(action.rawValue)[\(i)] 行寬")
                }
            }
        }
        // mirror 語意:不安全者不得進 mirrorSafe(drag/working1 有方向性細節)。
        XCTAssertFalse(bird.mirrorSafe.contains(.drag))
    }

    /// 假 pack 缺槽 fallback 解析(§7 必過):缺幀沿鏈、環與斷鏈終止於 idle。
    func testBrokenPackFallbackResolution() throws {
        let registry = PackRegistry()
        let broken = SpeciesPacks.brokenSample()
        registry.register(broken)
        // 宣告 requiredSlots 含 float,但幀缺 → fallback float→idle。
        XCTAssertTrue(broken.requiredSlots.contains(.float))
        XCTAssertNil(broken.frames[.float])
        XCTAssertEqual(registry.resolve(.float, in: broken), PetActionID.idle)
        // 環:dance→spin→dance → 終止 idle(不無窮迴圈)。
        XCTAssertEqual(registry.resolve(PetActionID(rawValue: "dance"), in: broken), PetActionID.idle)
        // 空幀陣列視同缺幀(mid-chain):spin=[] → dance → 環 → idle。
        XCTAssertEqual(registry.resolve(PetActionID(rawValue: "spin"), in: broken), PetActionID.idle)
        // 斷鏈:ghost→nowhere(無 fallback)→ idle。
        XCTAssertEqual(registry.resolve(PetActionID(rawValue: "ghost"), in: broken), PetActionID.idle)
        // 有幀者直接命中。
        XCTAssertEqual(registry.resolve(.idle, in: broken), PetActionID.idle)
        // 非方形 8×6 網格 well-formed(協議 grid-agnostic)。
        let rows = broken.frames[.idle]![0].split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(rows.count, broken.gridHeight)
        for row in rows { XCTAssertEqual(row.count, broken.gridWidth) }
    }

    /// 鳥包 fallback:glide 缺幀時應解析到 flyFlap(mid-chain 首個有幀者)。
    func testBirdFallbackChainPrefersDeclaredOrder() throws {
        let registry = PackRegistry()
        var bird = SpeciesPacks.birdPack()
        bird.frames[.glide] = []   // 人工移除 glide 幀
        registry.register(bird)
        XCTAssertEqual(registry.resolve(.glide, in: bird), PetActionID.flyFlap)
    }

    // MARK: E2a 真美術 golden(換皮不換行為;palette 契約)

    /// palette 契約:≤9 色(M2 §4 硬上限)、全幀字元 ⊆ palette∪{.}、
    /// idle 兩幀相異(呼吸)、flyFlap 四幀翅位相異(四相拍翅)。
    func testBirdArtPaletteAndFrameVariety() throws {
        let bird = SpeciesPacks.birdPack()
        XCTAssertFalse(bird.palette.isEmpty, "真美術必附 palette")
        XCTAssertTrue(bird.palette.count <= 9, "M2 §4:每物種 ≤9 色(現 \(bird.palette.count))")
        for (action, frames) in bird.frames {
            for (i, frame) in frames.enumerated() {
                let extraneous = Set(frame).subtracting(bird.palette.keys).subtracting(["\n", "."])
                XCTAssertTrue(extraneous.isEmpty,
                              "\(action.rawValue)[\(i)] 含 palette 外字元 \(extraneous)")
            }
        }
        let idle = bird.frames[.idle]!
        XCTAssertTrue(idle[0] != idle[1], "idle 兩幀必須相異(呼吸)")
        let flap = bird.frames[.flyFlap]!
        XCTAssertEqual(Set(flap).count, 4, "flyFlap 四幀翅位必須各不相同")
        // 使用者指定配色落地:主體藍、喙腳橘(k = 0xE8823A,與 app 暖色一致)。
        XCTAssertEqual(bird.palette["k"], 0xE8823A)
        XCTAssertEqual(bird.palette["b"], 0x4C8DE8)
    }

    /// 行為表凍結 golden:美術換皮不得動行為(權重/邊/槽位/fallback/錨點逐項釘住)。
    func testBirdBehaviorTableFrozenAcrossArtSwap() throws {
        let bird = SpeciesPacks.birdPack()
        XCTAssertEqual(bird.requiredSlots, [PetActionID.idle, PetActionID.drag])
        XCTAssertEqual(bird.optionalSlots, [PetActionID.glide, PetActionID.working1])
        XCTAssertEqual(bird.fallback, [.glide: .flyFlap, .working1: .idle, .float: .idle])
        XCTAssertEqual(bird.behavior.moodTier,
                       [.idle: 0, .flyFlap: 0, .glide: 0, .working1: 1, .drag: 0])
        let idleEdges = bird.behavior.rows[.idle]!
        XCTAssertEqual(idleEdges.count, 5)
        XCTAssertEqual(idleEdges.map(\.weight), [3, 2, 1, 1.5, 2])
        XCTAssertEqual(bird.anchorOffsets[.flyFlap], CGPoint(x: 0, y: -1))
        XCTAssertEqual(bird.anchorOffsets[.drag], CGPoint(x: 0, y: 1))
    }

    /// legacy pack 的 palette 傳遞:狗/貓 pack 直接帶 legacy sprite palette;
    /// palette 為 init 預設參數 — 未附美術的 pack(brokenSample)維持空(相容)。
    func testPackPalettePropagationAndDefault() throws {
        XCTAssertEqual(SpeciesPacks.dogPack().palette,
                       PixelPets.sprite(for: .dog).palette)
        XCTAssertEqual(SpeciesPacks.catPack().palette,
                       PixelPets.sprite(for: .cat).palette)
        XCTAssertTrue(SpeciesPacks.brokenSample().palette.isEmpty)
    }

    /// pack 顯示資訊(B5):bird 有名字與 emoji;未知 id 回 nil(UI fallback 到 enum)。
    func testPackDisplayInfo() throws {
        XCTAssertEqual(SpeciesPacks.displayInfo(packId: "bird")?.name, "Bird")
        XCTAssertEqual(SpeciesPacks.displayInfo(packId: "bird")?.emoji, "🐦")
        XCTAssertEqual(SpeciesPacks.displayInfo(packId: "dog")?.name, PetSpecies.dog.displayName)
        XCTAssertNil(SpeciesPacks.displayInfo(packId: "ghost"))
    }
}

// MARK: - 漫遊範圍帶(A1;center-x 座標契約)

final class WanderBandTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testFullRangeEqualsWholeScreen() {
        let band = WanderBand.centerBand(homeCenterX: 500, rangePercent: 100,
                                         screen: screen, petWidth: 200)
        XCTAssertEqual(band.lowerBound, 112)   // minX + margin 12 + petW/2
        XCTAssertEqual(band.upperBound, 888)
        // range=100 與 home 無關(整幕;原行為)。
        let band2 = WanderBand.centerBand(homeCenterX: 50, rangePercent: 100,
                                          screen: screen, petWidth: 200)
        XCTAssertEqual(band, band2)
    }

    func testNarrowBandCentersOnHome() {
        let band = WanderBand.centerBand(homeCenterX: 500, rangePercent: 40,
                                         screen: screen, petWidth: 200)
        XCTAssertEqual(band.lowerBound, 300)   // 500 − 40%×1000/2
        XCTAssertEqual(band.upperBound, 700)
    }

    func testHomeNearEdgeClampsIntoScreen() {
        // home 貼左緣:帶下界夾到可行下限,上界仍為 home+half(帶寬縮小、不外溢)。
        let band = WanderBand.centerBand(homeCenterX: 120, rangePercent: 40,
                                         screen: screen, petWidth: 200)
        XCTAssertEqual(band.lowerBound, 112)
        XCTAssertEqual(band.upperBound, 320)
        // home 貼右緣對稱。
        let right = WanderBand.centerBand(homeCenterX: 880, rangePercent: 40,
                                          screen: screen, petWidth: 200)
        XCTAssertEqual(right.lowerBound, 680)
        XCTAssertEqual(right.upperBound, 888)
    }

    func testOriginRangeConversionAndNarrowedFrame() {
        let band = WanderBand.centerBand(homeCenterX: 500, rangePercent: 40,
                                         screen: screen, petWidth: 200)
        let origin = WanderBand.originRange(centerBand: band, petWidth: 200)
        XCTAssertEqual(origin.lowerBound, 200)   // center 300 − 100
        XCTAssertEqual(origin.upperBound, 600)
        // V2 bounds = center band 本身(雙審 P1:不得加 petWidth 外接半寬,
        // Motion 夾的就是 center-x)。
        let narrowed = WanderBand.narrowedFrame(visibleFrame: screen, centerBand: band)
        XCTAssertEqual(narrowed.minX, 300)
        XCTAssertEqual(narrowed.maxX, 700)
        XCTAssertEqual(narrowed.minY, screen.minY)
        XCTAssertEqual(narrowed.height, screen.height)   // §4 高度公式的輸入不受影響
    }

    /// V2 與 legacy 同一 centerBand:legacy origin 帶反推回 center 後必須恰等於
    /// V2 bounds — 同設定同帶寬(雙審 P1 的等價釘)。
    func testV2AndLegacyBandsAgreeOnCenterInterval() {
        let petW: CGFloat = 200
        let band = WanderBand.centerBand(homeCenterX: 500, rangePercent: 40,
                                         screen: screen, petWidth: petW)
        let origin = WanderBand.originRange(centerBand: band, petWidth: petW)
        let narrowed = WanderBand.narrowedFrame(visibleFrame: screen, centerBand: band)
        XCTAssertEqual(origin.lowerBound + petW / 2, narrowed.minX)
        XCTAssertEqual(origin.upperBound + petW / 2, narrowed.maxX)
        // Motion 以此 bounds 夾 center-x:夾限結果必落在 band 內。
        let regions = RegionMap(visibleFrame: narrowed)
        let motion = MotionController(profile: .walker,
                                      position: CGPoint(x: 950, y: 0), regions: regions)
        motion.clampHorizontally(into: regions.bounds)
        XCTAssertTrue(band.contains(motion.state.position.x))
        XCTAssertEqual(motion.state.position.x, 700)
    }

    func testClampRangePercent() {
        XCTAssertEqual(WanderBand.clampRangePercent(60), 60)
        // 下限 10(R3 使用者調整,原 25)。
        XCTAssertEqual(WanderBand.clampRangePercent(10), 10)
        XCTAssertEqual(WanderBand.clampRangePercent(5), 10)
        XCTAssertEqual(WanderBand.clampRangePercent(400), 100)
        XCTAssertEqual(WanderBand.clampRangePercent(.nan), 100)
        XCTAssertEqual(WanderBand.clampRangePercent(-10), 10)
    }

    func testDegenerateScreenReturnsSinglePoint() {
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 100)
        let band = WanderBand.centerBand(homeCenterX: 50, rangePercent: 50,
                                         screen: tiny, petWidth: 200)
        XCTAssertEqual(band.lowerBound, band.upperBound)
    }

    func testMotionClampHorizontally() {
        let regions = RegionMap(visibleFrame: CGRect(x: 200, y: 0, width: 400, height: 800))
        let motion = MotionController(profile: .walker,
                                      position: CGPoint(x: 900, y: 0), regions: regions)
        motion.applyImpulse(CGVector(dx: 50, dy: 0))
        motion.clampHorizontally(into: regions.bounds)
        XCTAssertEqual(motion.state.position.x, 600, "帶外位置一次性拉回帶內")
        XCTAssertEqual(motion.state.velocity.dx, 0, "水平動量吸掉(避免下 tick 邊界反應)")
        // 帶內為 no-op(垂直速度不動)。
        motion.applyImpulse(CGVector(dx: 10, dy: -30))
        motion.clampHorizontally(into: regions.bounds)
        XCTAssertEqual(motion.state.velocity.dx, 10)
        XCTAssertEqual(motion.state.velocity.dy, -30)
    }
}

// MARK: - EngineLoop(單一寫入者 / working1 overlay 接線 / 互動搶佔)

final class EngineV2LoopTests: XCTestCase {
    private let dt = 1.0 / 30.0

    /// PosePresenter 單一寫入者:每 tick 恰一次 commit。
    func testExactlyOneCommitPerTick() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                              position: CGPoint(x: 400, y: 300), regions: regions, seed: 3)
        loop.presenter = spy
        for expected in 1...90 {
            loop.tick(dt: dt, regions: regions)
            XCTAssertEqual(spy.poses.count, expected, "tick \(expected) 應恰有 \(expected) 次 commit")
        }
        // 呈現座標必為整數(凍結取整規則)。
        for pose in spy.poses {
            XCTAssertEqual(pose.position.x, pose.position.x.rounded())
            XCTAssertEqual(pose.position.y, pose.position.y.rounded())
        }
    }

    /// working1 overlay 一態接線(mood 重塑):overlay 開啟時 working1 佔比顯著上升。
    func testWorking1OverlayMoodReshape() throws {
        // 觸發對照(§3-D):lastEventAt ≤60s + burn 檔半開區間。
        XCTAssertEqual(EngineV2.workingTier(secondsSinceLastEvent: 10, tokensPerHour: 100_000), 1)
        XCTAssertEqual(EngineV2.workingTier(secondsSinceLastEvent: 10, tokensPerHour: 500_000), 2)
        XCTAssertEqual(EngineV2.workingTier(secondsSinceLastEvent: 10, tokensPerHour: 5_000_000), 3)
        XCTAssertEqual(EngineV2.workingTier(secondsSinceLastEvent: 61, tokensPerHour: 100_000), 0)
        XCTAssertEqual(EngineV2.workingTier(secondsSinceLastEvent: -5, tokensPerHour: 100_000), 0)

        func working1Ticks(overlayOn: Bool) -> Int {
            let regions = standardRegions()
            let spy = PoseSpy()
            let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                                  position: CGPoint(x: 400, y: 300), regions: regions, seed: 12)
            loop.presenter = spy
            loop.overlay = overlayOn ? .working1 : nil
            for _ in 0..<2000 { loop.tick(dt: dt, regions: regions) }
            return spy.poses.filter { $0.action == .working1 }.count
        }
        let on = working1Ticks(overlayOn: true)
        let off = working1Ticks(overlayOn: false)
        XCTAssertTrue(on > 0, "overlay 開啟應出現 working1 幀")
        XCTAssertTrue(on > off * 2, "mood 重塑應顯著提升 working1 佔比(on=\(on), off=\(off))")
    }

    /// 雙車道:拖曳(使用者互動)搶佔隨機行為;放手即還車道。
    func testDragLanePreemptsGraphFlavor() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                              position: CGPoint(x: 400, y: 300), regions: regions, seed: 8)
        loop.presenter = spy
        loop.tick(dt: dt, regions: regions)
        loop.beginDrag(at: CGPoint(x: 400, y: 300))
        for _ in 0..<10 {
            loop.dragMoved(to: CGPoint(x: 410, y: 320), dt: dt)
            loop.tick(dt: dt, regions: regions)
        }
        XCTAssertTrue(spy.poses.suffix(10).allSatisfy { $0.action == .drag },
                      "拖曳中 pose 必為 drag 槽")
        loop.endDrag()
        loop.tick(dt: dt, regions: regions)
        XCTAssertTrue(spy.poses.last?.action != .drag, "放手後回到行為車道")
    }

    /// quiet 遮罩下行為收斂 idle;停用集合(缺動畫/停用另傳)剔除候選。
    func testMasksAndDisabledActionsInLoop() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                              position: CGPoint(x: 400, y: 300), regions: regions, seed: 21)
        loop.presenter = spy
        loop.masks = [.quiet]
        for _ in 0..<300 { loop.tick(dt: dt, regions: regions) }
        XCTAssertTrue(spy.poses.suffix(200).allSatisfy { $0.action == .idle },
                      "quiet 遮罩後應收斂 idle")
        spy.poses.removeAll()
        loop.masks = []
        loop.disabledActions = [.flyFlap, .glide, .working1]
        for _ in 0..<300 { loop.tick(dt: dt, regions: regions) }
        XCTAssertTrue(spy.poses.allSatisfy { $0.action == .idle },
                      "全部候選停用 → 零權重列 fallback idle")
    }
}

// MARK: - 深閒置節流 + flag 關零行為變化

final class EngineV2GovernorAndFlagTests: XCTestCase {

    /// timer 必須 invalidate:深閒置(睡眠)≥5s 內 shouldTick 轉 false(邏輯測試硬閘)。
    /// dock 段落依計畫 §2.2 為 10s(FIX-3 更正 —— 原 5s 斷言曾掩蓋凍結計畫違規)。
    func testGovernorStopsWithinFiveSeconds() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var governor = IdleGovernor(now: t0)
        XCTAssertTrue(governor.shouldTick(at: t0), "active 恆 tick")
        governor.setPhase(.sleeping, at: t0)
        XCTAssertTrue(governor.shouldTick(at: t0.addingTimeInterval(4.9)), "5s 內仍可收尾")
        XCTAssertFalse(governor.shouldTick(at: t0.addingTimeInterval(5.0)), "≤5s 必須停表")
        // 同相位重複設定不得重置起算點(否則永不停表)。
        governor.setPhase(.sleeping, at: t0.addingTimeInterval(3))
        XCTAssertFalse(governor.shouldTick(at: t0.addingTimeInterval(6)), "重複設定不重置計時")
        // 喚醒即恢復。
        governor.setPhase(.active, at: t0.addingTimeInterval(10))
        XCTAssertTrue(governor.shouldTick(at: t0.addingTimeInterval(10)))
        // dock 收合走 §2.2 迷你路徑:進入 10s 後才停表(sleep 5s 硬閘不變)。
        governor.setPhase(.docked, at: t0.addingTimeInterval(20))
        XCTAssertTrue(governor.shouldTick(at: t0.addingTimeInterval(25.1)), "dock <10s 仍 tick")
        XCTAssertFalse(governor.shouldTick(at: t0.addingTimeInterval(30.0)), "dock ≥10s 停表")
    }

    /// flag 關 = 零行為變化:預設值必為 false,且 legacy 動畫映射快照不受 EngineV2 存在影響。
    func testFlagOffByDefaultAndLegacySnapshotUnchanged() throws {
        XCTAssertFalse(EngineV2.isEnabled, "EngineV2.isEnabled 預設必須為 false(硬閘)")
        // legacy 快照:PixelPets 決定性映射(flag 關時 PetView/wander 走的原路徑)。
        XCTAssertEqual(PixelPets.animState(for: .idle, walking: true, species: .dog), .walk)
        XCTAssertEqual(PixelPets.animState(for: .sleeping, walking: false, species: .dog), .sleep)
        XCTAssertEqual(PixelPets.animState(for: .focused, walking: false, species: .cat), .focusedActive)
        XCTAssertEqual(PixelPets.animState(for: .warning, walking: false, species: .dog), .alert)
        let dog = PixelPets.sprite(for: .dog)
        XCTAssertEqual(dog.width, 20)
        XCTAssertEqual(dog.height, 18)
        // 短暫開關 flag 不影響 legacy 路徑輸出(EngineV2 與 legacy 無共享狀態)。
        EngineV2.isEnabled = true
        defer { EngineV2.isEnabled = false }
        XCTAssertEqual(PixelPets.animState(for: .idle, walking: true, species: .dog), .walk)
    }

    /// 凍結常數表(§5)釘值:防止未來誤調破壞 E0 可比性。
    func testFrozenConstants() throws {
        XCTAssertEqual(EngineV2.gravity, 900)
        XCTAssertEqual(EngineV2.airDecel, 120)
        XCTAssertEqual(EngineV2.groundDecel, 450)
        XCTAssertEqual(EngineV2.waterDecel, 300)
        XCTAssertEqual(EngineV2.walkerCruise, 36)
        XCTAssertEqual(EngineV2.flapImpulse, 220)
        XCTAssertEqual(EngineV2.swimmerDrift, 24)
        XCTAssertEqual(EngineV2.bounceEnergy, 0.55)
        XCTAssertEqual(EngineV2.escapeSpeedCap, 600)
        XCTAssertEqual(EngineV2.dtCap, 0.25)
        XCTAssertEqual(LocomotionProfile.swimmer.gravity(inWater: true), 0, "Swimmer 水中 g=0")
        XCTAssertEqual(LocomotionProfile.swimmer.gravity(inWater: false), 900, "Swimmer 出水 g=900")
        XCTAssertEqual(LocomotionProfile.flyer.gravity(inWater: false), 900)
    }
}

// MARK: - DragRecognizer(E1 graft:辨識狀態機與物理分離;門檻 §5 凍結)

final class EngineV2DragRecognizerTests: XCTestCase {

    /// 未達門檻的按放 = 點擊:距離不足(3.9px)或時間不足(119ms)皆不判拖曳。
    func testPressBelowThresholdsIsClick() throws {
        var rec = DragRecognizer()
        rec.began(at: CGPoint(x: 100, y: 100), time: 10.0)
        XCTAssertFalse(rec.moved(to: CGPoint(x: 103.9, y: 100), time: 10.5), "3.9px 距離不足")
        XCTAssertFalse(rec.isDragging)
        rec.ended()
        rec.began(at: CGPoint(x: 0, y: 0), time: 0)
        XCTAssertFalse(rec.moved(to: CGPoint(x: 40, y: 0), time: 0.119), "119ms 時間不足")
        XCTAssertFalse(rec.isDragging)
        rec.ended()
    }

    /// 邊界:恰 4px 且恰 120ms → 拖曳(§5 兩條件皆含等號)。
    func testBoundaryExactlyFourPxAnd120msIsDrag() throws {
        var rec = DragRecognizer()
        rec.began(at: CGPoint(x: 10, y: 10), time: 1.0)
        XCTAssertTrue(rec.moved(to: CGPoint(x: 14, y: 10), time: 1.12), "4px + 120ms 雙含等號")
        XCTAssertTrue(rec.isDragging)
    }

    /// 位移取歷史最大距離:先拖遠再拖回原點附近,時間到仍判拖曳(不中途退回點擊)。
    func testMaxDistanceRetainedWhenReturningNearOrigin() throws {
        var rec = DragRecognizer()
        rec.began(at: CGPoint(x: 0, y: 0), time: 0)
        XCTAssertFalse(rec.moved(to: CGPoint(x: 30, y: 0), time: 0.05), "距離夠但時間未到")
        XCTAssertTrue(rec.moved(to: CGPoint(x: 1, y: 0), time: 0.2), "歷史最大位移語意")
    }

    /// 達標後 sticky 直到 ended;ended/began 重置;未 began 的移動不判定。
    func testStickyUntilEndedAndBeganResets() throws {
        var rec = DragRecognizer()
        rec.began(at: .zero, time: 0)
        _ = rec.moved(to: CGPoint(x: 10, y: 0), time: 0.3)
        XCTAssertTrue(rec.isDragging)
        _ = rec.moved(to: CGPoint(x: 0.5, y: 0), time: 0.4)
        XCTAssertTrue(rec.isDragging, "達標後維持拖曳態")
        rec.ended()
        XCTAssertFalse(rec.isDragging)
        XCTAssertFalse(rec.moved(to: CGPoint(x: 100, y: 100), time: 9), "未 began 不判定")
        rec.began(at: CGPoint(x: 0, y: 0), time: 20)
        XCTAssertFalse(rec.moved(to: CGPoint(x: 2, y: 0), time: 20.2), "began 重置手勢")
    }

    /// 判定式單一出處:辨識器結論與凍結判定式 EngineV2.isDrag 一致。
    func testAgreesWithFrozenPredicate() throws {
        XCTAssertTrue(EngineV2.isDrag(distance: 4, duration: 0.12))
        XCTAssertFalse(EngineV2.isDrag(distance: 3.999, duration: 10))
        XCTAssertFalse(EngineV2.isDrag(distance: 400, duration: 0.1199))
        var rec = DragRecognizer()
        rec.began(at: .zero, time: 0)
        XCTAssertEqual(rec.moved(to: CGPoint(x: 3, y: 0), time: 0.5),
                       EngineV2.isDrag(distance: 3, duration: 0.5))
        XCTAssertEqual(rec.moved(to: CGPoint(x: 5, y: 0), time: 0.6),
                       EngineV2.isDrag(distance: 5, duration: 0.6))
    }
}

// MARK: - 互動車道(E1 graft:A 案 lane 清晰度 — 佇列互動即刻搶佔 graph flavor)

final class EngineV2InteractionLaneTests: XCTestCase {
    private let dt = 1.0 / 30.0

    /// 佇列互動即刻搶佔:graph 動作進行中,noteInteraction 後下個 tick 就換動作。
    func testQueuedInteractionPreemptsImmediately() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                              position: CGPoint(x: 400, y: 300), regions: regions, seed: 5)
        loop.presenter = spy
        for _ in 0..<3 { loop.tick(dt: dt, regions: regions) }   // graph 動作播放中(未播畢)
        loop.noteInteraction(.working1)
        loop.tick(dt: dt, regions: regions)
        XCTAssertEqual(loop.currentAction, PetActionID.working1, "互動不等 graph 動作播畢")
        XCTAssertEqual(spy.poses.last?.action, PetActionID.working1)
    }

    /// 拖曳期間佇列凍結(拖曳為同車道更即時互動);放手後下一 tick 才消化。
    func testInteractionLaneFrozenWhileDragging() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                              position: CGPoint(x: 400, y: 300), regions: regions, seed: 6)
        loop.presenter = spy
        loop.beginDrag(at: CGPoint(x: 400, y: 300))
        loop.noteInteraction(.working1)
        for _ in 0..<5 {
            loop.dragMoved(to: CGPoint(x: 405, y: 305), dt: dt)
            loop.tick(dt: dt, regions: regions)
        }
        XCTAssertTrue(spy.poses.suffix(5).allSatisfy { $0.action == .drag },
                      "拖曳中顯示 drag 槽,佇列不消化")
        XCTAssertTrue(loop.currentAction != .working1, "拖曳中互動仍在佇列")
        loop.endDrag()
        loop.tick(dt: dt, regions: regions)
        XCTAssertEqual(loop.currentAction, PetActionID.working1, "放手後接手佇列互動")
    }

    /// 互動動作播畢後 graph flavor 恢復接手(車道歸還)。
    func testInteractionPlaysThenGraphResumes() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                              position: CGPoint(x: 400, y: 300), regions: regions, seed: 11)
        loop.presenter = spy
        loop.noteInteraction(.working1)
        loop.tick(dt: dt, regions: regions)
        XCTAssertEqual(loop.currentAction, PetActionID.working1)
        var resumed = false
        for _ in 0..<600 {
            loop.tick(dt: dt, regions: regions)
            if loop.currentAction != .working1 { resumed = true; break }
        }
        XCTAssertTrue(resumed, "互動播畢後 graph 應恢復(不永久佔道)")
    }

    /// 決定性:同 seed + 同互動時刻表 → 兩 run pose 串流位元一致(空佇列已由既有測試涵蓋)。
    func testDeterminismWithInteractionSchedule() throws {
        func run() -> [(CGFloat, CGFloat, String, Int)] {
            let regions = standardRegions()
            let spy = PoseSpy()
            let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                                  position: CGPoint(x: 400, y: 350), regions: regions, seed: 77)
            loop.presenter = spy
            for step in 0..<300 {
                if step == 50 || step == 130 { loop.noteInteraction(.working1) }
                loop.tick(dt: dt, regions: regions)
            }
            return spy.poses.map { ($0.position.x, $0.position.y, $0.action.rawValue, $0.frameIndex) }
        }
        let a = run()
        let b = run()
        XCTAssertEqual(a.count, b.count)
        for i in 0..<min(a.count, b.count) {
            XCTAssertTrue(a[i] == b[i], "tick \(i) pose 不一致:\(a[i]) vs \(b[i])")
        }
    }
}

// MARK: - Golden mutation guard(E1 graft:證明 golden gate 對錯常數「能」失敗)

final class EngineV2MutationGuardTests: XCTestCase {
    private let dt = 1.0 / 30.0
    /// §6 (a) 自由落體 golden 期望表(凍結 fixtures,與 EngineV2GoldenSetATests 同源)。
    private let goldenFreeFallY: [CGFloat] = [399, 397, 395, 391, 387, 382, 376, 369, 361, 352]

    private func freeFallTrack(decel: DecelSet) -> [CGFloat] {
        let regions = unboundedRegions()
        let motion = MotionController(profile: .flyer, position: CGPoint(x: 0, y: 400),
                                      regions: regions, decel: decel)
        var track: [CGFloat] = []
        for _ in 0..<10 {
            _ = motion.tick(dt: dt, regions: regions)
            track.append(motion.presentedPosition.y)
        }
        return track
    }

    /// 自我檢核的 mutation 測試:凍結組全等 golden 表;air decel 蓄意調錯(120→240)
    /// 時軌跡必須偏離 golden 表(手算:tick 2 起偏離)。若此測試失敗,代表 golden
    /// 斷言對積分常數不敏感 —— gate 是假的。
    func testGoldenGateCanFail() throws {
        XCTAssertEqual(freeFallTrack(decel: .frozen), goldenFreeFallY, "凍結組必須逐 tick ±0")
        let mutated = DecelSet(ground: EngineV2.groundDecel,
                               water: EngineV2.waterDecel,
                               air: 240)   // 蓄意錯值:唯一與凍結組的差異
        let mutatedTrack = freeFallTrack(decel: mutated)
        XCTAssertTrue(mutatedTrack != goldenFreeFallY,
                      "錯 decel 必須讓 golden 表比對失敗(gate 靈敏度證明),實得 \(mutatedTrack)")
        XCTAssertEqual(mutatedTrack.count, goldenFreeFallY.count, "只允許值偏離,不允許長度差")
    }

    /// 凍結組與 §5 常數一致(注入點預設值不得漂移)。
    func testFrozenDecelSetMatchesLaw() throws {
        XCTAssertEqual(DecelSet.frozen.ground, 450)
        XCTAssertEqual(DecelSet.frozen.water, 300)
        XCTAssertEqual(DecelSet.frozen.air, 120)
        XCTAssertEqual(DecelSet.frozen, DecelSet(ground: EngineV2.groundDecel,
                                                 water: EngineV2.waterDecel,
                                                 air: EngineV2.airDecel))
    }
}

// MARK: - 狗/貓遷移包(E1 §3-C:行為等價 golden — 遷移在視覺上什麼都沒改)

final class EngineV2LegacyPackTests: XCTestCase {

    /// 狗:每 legacy 狀態逐幀斷言 pack 解析幀 == legacy 網格字串(join "\n")。
    func testDogPackFramesIdenticalToLegacy() throws {
        assertPackWrapsLegacy(pack: SpeciesPacks.dogPack(), species: .dog)
    }

    /// 貓:同上(含 focus 三態)。
    func testCatPackFramesIdenticalToLegacy() throws {
        assertPackWrapsLegacy(pack: SpeciesPacks.catPack(), species: .cat)
    }

    private func assertPackWrapsLegacy(pack: SpeciesPack, species: PetSpecies) {
        let sprite = PixelPets.sprite(for: species)
        let registry = PackRegistry()
        registry.register(pack)
        XCTAssertEqual(pack.gridWidth, sprite.width, "\(species.rawValue) 網格寬")
        XCTAssertEqual(pack.gridHeight, sprite.height, "\(species.rawValue) 網格高")
        for state in PixelAnimState.allCases {
            let action = SpeciesPacks.actionID(for: state)
            let resolved = registry.resolve(action, in: pack)
            let packFrames = pack.frames[resolved] ?? []
            let legacyFrames = sprite.frames(for: state)   // legacy 顯示語意(缺態→idle)
            XCTAssertEqual(packFrames.count, legacyFrames.count,
                           "\(species.rawValue)/\(state.rawValue) 幀數")
            for (i, legacyRows) in legacyFrames.enumerated() where i < packFrames.count {
                XCTAssertEqual(packFrames[i], legacyRows.joined(separator: "\n"),
                               "\(species.rawValue)/\(state.rawValue)[\(i)] 網格字串必須完全相等")
            }
            // join 轉換無損:列數 × 行寬與宣告網格一致。
            for (i, frame) in packFrames.enumerated() {
                let rows = frame.split(separator: "\n", omittingEmptySubsequences: false)
                XCTAssertEqual(rows.count, pack.gridHeight,
                               "\(species.rawValue)/\(state.rawValue)[\(i)] 列數")
                for row in rows {
                    XCTAssertEqual(row.count, pack.gridWidth,
                                   "\(species.rawValue)/\(state.rawValue)[\(i)] 行寬")
                }
            }
        }
    }

    /// 狗未畫 focus 三態:pack 解析與 legacy 一樣落回 idle;貓有畫則命中自身。
    func testMissingLegacyStatesResolveLikeLegacyFallback() throws {
        let registry = PackRegistry()
        let dog = SpeciesPacks.dogPack()
        registry.register(dog)
        for state in [PixelAnimState.focusStart, .focusedActive, .focusEnd] {
            XCTAssertEqual(registry.resolve(SpeciesPacks.actionID(for: state), in: dog),
                           PetActionID.idle, "狗 \(state.rawValue) → idle")
        }
        let cat = SpeciesPacks.catPack()
        registry.register(cat)
        XCTAssertEqual(registry.resolve(.focusedActive, in: cat), PetActionID.focusedActive)
        XCTAssertEqual(registry.resolve(.focusStart, in: cat), PetActionID.focusStart)
        XCTAssertEqual(registry.resolve(.focusEnd, in: cat), PetActionID.focusEnd)
    }

    /// pack 中繼資料與 legacy 一致;drag/float 契約槽位缺美術 → fallback idle;
    /// mirror 語意沿 legacy(整張翻轉不分狀態 → 全部有幀動作 mirror-safe)。
    func testPackMetadataMatchesLegacy() throws {
        let dog = SpeciesPacks.dogPack()
        let cat = SpeciesPacks.catPack()
        XCTAssertEqual(dog.id, PetSpecies.dog.packId)
        XCTAssertEqual(cat.id, PetSpecies.cat.packId)
        XCTAssertEqual(dog.id, "dog")
        XCTAssertEqual(cat.id, "cat")
        XCTAssertEqual(dog.displayName, PetSpecies.dog.displayName)
        XCTAssertEqual(cat.displayName, PetSpecies.cat.displayName)
        XCTAssertEqual(dog.locomotion, LocomotionProfile.walker)
        XCTAssertEqual(cat.locomotion, LocomotionProfile.walker)
        for pack in [dog, cat] {
            XCTAssertEqual(pack.requiredSlots, Set([PetActionID.idle, .drag]), "\(pack.id) 必要槽位")
            XCTAssertTrue(!(pack.frames[.idle]?.isEmpty ?? true), "\(pack.id) idle 必須有幀")
            let registry = PackRegistry()
            registry.register(pack)
            XCTAssertEqual(registry.resolve(.drag, in: pack), PetActionID.idle, "\(pack.id) drag→idle")
            XCTAssertEqual(registry.resolve(.float, in: pack), PetActionID.idle, "\(pack.id) float→idle")
            XCTAssertEqual(pack.mirrorSafe, Set(pack.frames.keys), "\(pack.id) mirror 語意沿 legacy")
            XCTAssertTrue(pack.anchorOffsets.isEmpty, "\(pack.id) legacy 無錨偏移(查表預設 .zero)")
            // 行為表引用的動作全部解析得到幀(graph 不會抽到空槽)。
            for (from, edges) in pack.behavior.rows {
                XCTAssertTrue(!(pack.frames[registry.resolve(from, in: pack)]?.isEmpty ?? true),
                              "\(pack.id) 列首 \(from.rawValue)")
                for edge in edges {
                    XCTAssertTrue(!(pack.frames[registry.resolve(edge.next, in: pack)]?.isEmpty ?? true),
                                  "\(pack.id) 邊 \(from.rawValue)→\(edge.next.rawValue)")
                }
            }
        }
    }

    /// PixelAnimState → PetActionID 為 rawValue 直通且無碰撞;便利常數一致。
    func testActionIDMappingIsRawValuePassthrough() throws {
        var seen = Set<PetActionID>()
        for state in PixelAnimState.allCases {
            let action = SpeciesPacks.actionID(for: state)
            XCTAssertEqual(action.rawValue, state.rawValue)
            XCTAssertTrue(seen.insert(action).inserted, "映射不得碰撞:\(state.rawValue)")
        }
        XCTAssertEqual(SpeciesPacks.actionID(for: .walk), PetActionID.walk)
        XCTAssertEqual(SpeciesPacks.actionID(for: .alert), PetActionID.alert)
        XCTAssertEqual(SpeciesPacks.actionID(for: .focusedActive), PetActionID.focusedActive)
    }

    /// PetSpecies ↔ pack id 相容層(settings facade 的 PetCore 端)。
    func testSpeciesPackIdMapping() throws {
        XCTAssertEqual(PetSpecies.dog.packId, "dog")
        XCTAssertEqual(PetSpecies.cat.packId, "cat")
        XCTAssertEqual(PetSpecies(packId: "dog"), PetSpecies.dog)
        XCTAssertEqual(PetSpecies(packId: "cat"), PetSpecies.cat)
        XCTAssertNil(PetSpecies(packId: "bird"), "未知 pack id → nil(呼叫端依 flag 矩陣落 dog)")
        XCTAssertNil(PetSpecies(packId: ""))
        for species in PetSpecies.allCases {
            XCTAssertEqual(PetSpecies(packId: species.packId), species, "來回映射")
        }
    }

    /// 遷移包可直接驅動引擎迴圈:每 tick 恰一次 commit,顯示動作必為 legacy 槽位。
    func testDogPackDrivesEngineLoop() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.dogPack(),
                              position: CGPoint(x: 400, y: 0), regions: regions, seed: 9)
        loop.presenter = spy
        for _ in 0..<240 { loop.tick(dt: 1.0 / 30, regions: regions) }
        XCTAssertEqual(spy.poses.count, 240, "單一寫入者:每 tick 恰一次")
        let shown = Set(spy.poses.map(\.action.rawValue))
        let legal = Set(PixelAnimState.allCases.map(\.rawValue))
        XCTAssertTrue(shown.isSubset(of: legal), "顯示動作必為 legacy 槽位,實得 \(shown)")
    }
}

// MARK: - Bridge 純邏輯(E1 雙審修正:timer re-arm / §2.2 dock 10s / pack 重建 / override facade)

final class EngineV2BridgeLogicTests: XCTestCase {

    /// FIX-1:active→docked(10s 內收尾、到點停表)→active(重掛並恢復 tick)的完整週期。
    /// Driver 於 tick 與相位觀察回呼中依 directive 掛/停表;此測試即該決策核心。
    func testDirectiveRearmCycleActiveDockedActive() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 5000)
        var g = IdleGovernor(now: t0)
        XCTAssertEqual(g.directive(timerArmed: true, at: t0), .keep, "active 有表 → 維持")
        XCTAssertEqual(g.directive(timerArmed: false, at: t0), .arm, "active 無表 → 重掛")
        g.setPhase(.docked, at: t0)
        XCTAssertEqual(g.directive(timerArmed: true, at: t0.addingTimeInterval(9.9)), .keep,
                       "dock <10s 收尾期仍維持")
        XCTAssertEqual(g.directive(timerArmed: true, at: t0.addingTimeInterval(10)), .stop,
                       "dock ≥10s → invalidate")
        XCTAssertEqual(g.directive(timerArmed: false, at: t0.addingTimeInterval(12)), .keep,
                       "停著且仍不該 tick → 別動")
        g.setPhase(.active, at: t0.addingTimeInterval(30))
        XCTAssertEqual(g.directive(timerArmed: false, at: t0.addingTimeInterval(30)), .arm,
                       "相位回 active(quiet 關閉/睡醒)→ 重掛")
        XCTAssertTrue(g.shouldTick(at: t0.addingTimeInterval(30)), "重掛後恢復 tick")
    }

    /// FIX-3:兩種停表時序並存 —— sleeping 5s(E0 硬閘)、docked 10s(計畫 §2.2)。
    func testDockTenSecondsSleepFiveSeconds() throws {
        XCTAssertEqual(IdleGovernor.sleepStopDelay, 5, "深閒置 5s 硬閘")
        XCTAssertEqual(IdleGovernor.dockStopDelay, 10, "quiet/dock 迷你路徑 10s(§2.2)")
        let t0 = Date(timeIntervalSinceReferenceDate: 8000)
        var sleeper = IdleGovernor(now: t0)
        sleeper.setPhase(.sleeping, at: t0)
        XCTAssertTrue(sleeper.shouldTick(at: t0.addingTimeInterval(4.9)))
        XCTAssertFalse(sleeper.shouldTick(at: t0.addingTimeInterval(5.0)), "sleep 5s 停表")
        var docked = IdleGovernor(now: t0)
        docked.setPhase(.docked, at: t0)
        XCTAssertTrue(docked.shouldTick(at: t0.addingTimeInterval(5.0)), "dock 5s 時仍 tick(≠sleep)")
        XCTAssertTrue(docked.shouldTick(at: t0.addingTimeInterval(9.9)))
        XCTAssertFalse(docked.shouldTick(at: t0.addingTimeInterval(10.0)), "dock 10s 停表")
        XCTAssertEqual(docked.directive(timerArmed: true, at: t0.addingTimeInterval(10.0)), .stop)
    }

    /// FIX-2:Driver 的 pack 重建配方 —— speciesPackId 變更 → 以新 pack 重建 EngineLoop,
    /// 位置保留、行為狀態重算;後續 commit 全部使用新(貓)pack 的動作與幀。
    func testPackSwitchRebuildPreservesPositionAndUsesNewFrames() throws {
        let regions = standardRegions()
        let spyDog = PoseSpy()
        let dogLoop = EngineLoop(pack: SpeciesPacks.dogPack(),
                                 position: CGPoint(x: 321, y: 0), regions: regions, seed: 4)
        dogLoop.presenter = spyDog
        for _ in 0..<30 { dogLoop.tick(dt: 1.0 / 30, regions: regions) }
        // 重建配方(與 EngineV2Driver.rebuildLoopIfPackChanged 相同):保留位置換 pack。
        let carried = dogLoop.motion.state.position
        let catLoop = EngineLoop(pack: SpeciesPacks.catPack(),
                                 position: carried, regions: regions, seed: 4)
        XCTAssertTrue(catLoop.motion.state.position == carried, "重建保留位置")
        let spyCat = PoseSpy()
        catLoop.presenter = spyCat
        for _ in 0..<60 { catLoop.tick(dt: 1.0 / 30, regions: regions) }
        XCTAssertEqual(spyCat.poses.count, 60, "重建後單一寫入者不變")
        let cat = SpeciesPacks.catPack()
        for pose in spyCat.poses {
            let frames = cat.frames[pose.action] ?? []
            XCTAssertTrue(!frames.isEmpty, "commit 動作必有貓幀:\(pose.action.rawValue)")
            XCTAssertTrue(pose.frameIndex >= 0 && pose.frameIndex < frames.count,
                          "幀索引在貓 pack 範圍內")
        }
        // 視覺確實換皮:貓/狗 idle 首幀網格不同(等價 golden 保證各自等於 legacy)。
        let dog = SpeciesPacks.dogPack()
        XCTAssertTrue(cat.frames[.idle]![0] != dog.frames[.idle]![0], "貓狗網格必須相異")
    }

    /// FIX-4:pack id override facade —— override 優先、nil 回落 enum、未知 id 解析為 dog。
    /// (AppSettings.speciesPackId / resolvedSpecies 委派這兩個 PetCore 函式。)
    func testPackIdOverrideFacadeAndUnknownResolution() throws {
        XCTAssertEqual(PetSpecies.effectivePackId(override: nil, stored: .dog), "dog", "nil → enum 後援")
        XCTAssertEqual(PetSpecies.effectivePackId(override: nil, stored: .cat), "cat")
        XCTAssertEqual(PetSpecies.effectivePackId(override: "bird", stored: .dog), "bird", "override 生效")
        XCTAssertEqual(PetSpecies.effectivePackId(override: "cat", stored: .dog), "cat")
        XCTAssertEqual(PetSpecies.resolved(fromPackId: "dog"), PetSpecies.dog)
        XCTAssertEqual(PetSpecies.resolved(fromPackId: "cat"), PetSpecies.cat)
        XCTAssertEqual(PetSpecies.resolved(fromPackId: "bird"), PetSpecies.dog, "未知 id → dog(真正可達)")
        XCTAssertEqual(PetSpecies.resolved(fromPackId: ""), PetSpecies.dog)
        // 組合語意:override "bird" 的 resolvedSpecies == .dog(legacy 渲染仍有皮可畫)。
        let effective = PetSpecies.effectivePackId(override: "bird", stored: .cat)
        XCTAssertEqual(PetSpecies.resolved(fromPackId: effective), PetSpecies.dog)
    }
}

// MARK: - 運動 glue(round-2 修正:FIX-5 地面起飛 / FIX-6 walker 巡航)

final class EngineV2LocomotionGlueTests: XCTestCase {
    private let dt = 1.0 / 30.0

    /// FIX-5(圖層):ground 區的 idle→flyFlap 邊必須可達;glide 仍限 air 區。
    func testBirdGroundEdgeAllowsFlyFlapFromIdle() throws {
        let bird = SpeciesPacks.birdPack()
        let graph = BehaviorGraph(table: bird.behavior)
        var rng: any RandomNumberGenerator = SeededRNG(seed: 3)
        let available: Set<PetActionID> = [.idle, .flyFlap, .glide, .working1]
        var pickedFlyFlap = false
        var pickedGlide = false
        for _ in 0..<300 {
            let next = graph.next(after: .idle, moodTier: 0, masks: [], available: available,
                                  region: .ground, rng: &rng)
            if next == .flyFlap { pickedFlyFlap = true }
            if next == .glide { pickedGlide = true }
        }
        XCTAssertTrue(pickedFlyFlap, "ground 區 idle→flyFlap 起飛入口必須可達(FIX-5)")
        XCTAssertFalse(pickedGlide, "glide 仍限 air 區(不得順帶開放)")
    }

    /// FIX-5(迴圈層):鳥正常著地(grounded=true,無拖曳)後,行為抽中 flyFlap
    /// 時施加起飛衝量 → 離地並重返 air 區 —— 不得地面軟鎖。
    /// 著地手法:出生於地面線並預施 -200 下墜衝量,懸停拍翅(+220)不足以抵銷,
    /// 首 tick 即軟著地(純物理路徑,無拖曳)。
    func testFlyerTakesOffFromGroundViaFlyFlap() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                              position: CGPoint(x: 400, y: 0), regions: regions, seed: 16)
        loop.presenter = spy
        loop.motion.applyImpulse(CGVector(dx: 0, dy: -200))
        var events: [MotionEvent] = []
        events.append(contentsOf: loop.tick(dt: dt, regions: regions))
        XCTAssertTrue(loop.motion.state.grounded, "前提:首 tick 應軟著地(grounded=true)")
        XCTAssertTrue(events.contains(.dropped(.soft)), "著地事件")
        XCTAssertTrue(events.contains(.enteredRegion(.ground)), "入 ground 區")
        // 著地後:行為圖(ground 邊)遲早抽中 flyFlap → 起飛 → 重返 air 區。
        var tookOffAt: Int? = nil
        for i in 0..<2000 {
            events.append(contentsOf: loop.tick(dt: dt, regions: regions))
            if !loop.motion.state.grounded {
                tookOffAt = i
                break
            }
        }
        XCTAssertNotNil(tookOffAt, "鳥不得地面軟鎖:2000 tick 內應經 flyFlap 起飛(FIX-5)")
        XCTAssertEqual(loop.currentAction, PetActionID.flyFlap, "起飛瞬間動作應為 flyFlap")
        // 起飛後應升空並發出重返 air 區事件。
        var backInAir = false
        for _ in 0..<120 {
            events.append(contentsOf: loop.tick(dt: dt, regions: regions))
            if loop.motion.state.position.y > regions.groundY + 4 { backInAir = true; break }
        }
        XCTAssertTrue(backInAir, "起飛後應實際升空(y > groundY+4)")
        let airEntries = events.filter { $0 == .enteredRegion(.air) }
        XCTAssertTrue(!airEntries.isEmpty, "應有 enteredRegion(air) 事件(著地→起飛週期)")
    }

    /// FIX-6:walk 動作 → 實際水平巡航;方向觸界前恆定,觸界後回頭;全程接地。
    /// 以互動車道每 tick 重佔 walk(決定性,不依賴 graph 抽籤)。
    func testWalkerWalkCruisesAndTurnsAtBounds() throws {
        let regions = standardRegions()
        let loop = EngineLoop(pack: SpeciesPacks.dogPack(),
                              position: CGPoint(x: 400, y: 0), regions: regions, seed: 4)
        var xs: [CGFloat] = [loop.motion.state.position.x]
        for _ in 0..<1200 {
            loop.noteInteraction(.walk)
            loop.tick(dt: dt, regions: regions)
            xs.append(loop.motion.state.position.x)
        }
        // 觸界前方向恆定(首 tick 尚在落地,自 tick 2 起檢查)。
        let early = Array(xs[2...100])
        let increasing = zip(early, early.dropFirst()).allSatisfy { $0 <= $1 }
        let decreasing = zip(early, early.dropFirst()).allSatisfy { $0 >= $1 }
        XCTAssertTrue(increasing || decreasing, "巡航方向在觸界前必須恆定")
        XCTAssertTrue(abs(xs[100] - xs[2]) > 30, "walk 必須實際位移(非原地播幀),實得 \(abs(xs[100] - xs[2]))")
        // 1200 tick 的行程足以觸及一側水平邊界。
        let hitLow = xs.min()! <= regions.bounds.minX + 0.5
        let hitHigh = xs.max()! >= regions.bounds.maxX - 0.5
        XCTAssertTrue(hitLow || hitHigh,
                      "應觸及水平邊界(min=\(xs.min()!), max=\(xs.max()!))")
        // 觸界後回頭:最終位置離觸及的邊界 ≥ 10px。
        if hitHigh {
            XCTAssertTrue(xs.last! < regions.bounds.maxX - 10, "觸右界後應回頭,實得 \(xs.last!)")
        } else {
            XCTAssertTrue(xs.last! > regions.bounds.minX + 10, "觸左界後應回頭,實得 \(xs.last!)")
        }
        XCTAssertTrue(loop.motion.state.grounded, "巡航全程接地(cruise 不得抬離地面)")
    }

    /// FIX-6:非 walk 動作(idle)無目標速度 → 零水平漂移。
    func testWalkerIdleHasNoDrift() throws {
        let regions = standardRegions()
        let loop = EngineLoop(pack: SpeciesPacks.dogPack(),
                              position: CGPoint(x: 400, y: 0), regions: regions, seed: 6)
        loop.disabledActions = [.walk, .sit]   // 圖上僅剩 idle 可達
        for _ in 0..<300 { loop.tick(dt: dt, regions: regions) }
        XCTAssertEqual(loop.currentAction, PetActionID.idle)
        XCTAssertEqual(loop.motion.state.position.x, 400, "idle 不得漂移")
        XCTAssertEqual(loop.motion.state.velocity.dx, 0, "idle 無水平速度")
        XCTAssertTrue(loop.motion.state.grounded)
    }
}

// MARK: - 遮罩/漫遊開關鎖運動(round-3 修正:FIX-8 a11y / FIX-9 petWanderEnabled)

final class EngineV2LocomotionGateTests: XCTestCase {
    private let dt = 1.0 / 30.0

    /// FIX-8:reduce-motion 下運動 glue 全停 —— 空中的 flyer 不再獲得任何向上衝量,
    /// 速度硬性歸零後僅受重力緩降,落定後位置完全穩定(靜態姿勢集,不懸浮)。
    func testReduceMotionFlyerSettlesWithoutImpulses() throws {
        let regions = standardRegions()
        let loop = EngineLoop(pack: SpeciesPacks.birdPack(),
                              position: CGPoint(x: 400, y: 350), regions: regions, seed: 7)
        loop.masks = [.reduceMotion]
        var settled = false
        for i in 0..<900 {
            loop.tick(dt: dt, regions: regions)
            XCTAssertTrue(loop.motion.state.velocity.dy <= 1e-9,
                          "reduce-motion 不得有向上衝量(tick \(i))")
            if loop.motion.state.grounded { settled = true; break }
        }
        XCTAssertTrue(settled, "reduce-motion 的懸空 flyer 應緩降落定")
        let restX = loop.motion.state.position.x
        let restY = loop.motion.state.position.y
        for _ in 0..<120 { loop.tick(dt: dt, regions: regions) }
        XCTAssertEqual(loop.motion.state.position.x, restX, "落定後 x 穩定")
        XCTAssertEqual(loop.motion.state.position.y, restY, "落定後 y 穩定")
        XCTAssertTrue(loop.motion.state.grounded, "保持接地")
        XCTAssertEqual(loop.motion.state.velocity.dx, 0)
        XCTAssertEqual(loop.motion.state.velocity.dy, 0)
    }

    /// FIX-8:quiet 下 swimmer 不再設定漂游目標 —— 水阻(300)使速度收斂 ~0,位置停住。
    func testQuietSwimmerStopsDrifting() throws {
        let regions = standardRegions()
        let loop = EngineLoop(pack: SpeciesPacks.brokenSample(),   // swimmer profile 的最小包
                              position: CGPoint(x: 400, y: 50), regions: regions, seed: 5)
        for _ in 0..<60 { loop.tick(dt: dt, regions: regions) }   // 前置:漂游中
        XCTAssertTrue(abs(loop.motion.state.velocity.dx) > 5, "前置:應有漂游速度")
        loop.masks = [.quiet]
        for _ in 0..<60 { loop.tick(dt: dt, regions: regions) }
        let v = loop.motion.state.velocity
        XCTAssertTrue((v.dx * v.dx + v.dy * v.dy).squareRoot() < 0.5,
                      "quiet 下漂游速度應收斂 ~0,實得 \(v)")
        let x1 = loop.motion.state.position.x
        for _ in 0..<60 { loop.tick(dt: dt, regions: regions) }
        XCTAssertTrue(abs(loop.motion.state.position.x - x1) < 0.5, "quiet 下不再漂移")
    }

    /// FIX-9:locomotionEnabled=false(petWanderEnabled 關)—— walk 姿勢照播但零淨位移;
    /// 開回 true 後巡航恢復。
    func testWanderDisabledStopsCruiseButKeepsPoseCycle() throws {
        let regions = standardRegions()
        let spy = PoseSpy()
        let loop = EngineLoop(pack: SpeciesPacks.dogPack(),
                              position: CGPoint(x: 400, y: 0), regions: regions, seed: 4)
        loop.presenter = spy
        loop.locomotionEnabled = false
        for _ in 0..<300 {
            loop.noteInteraction(.walk)
            loop.tick(dt: dt, regions: regions)
            XCTAssertEqual(loop.motion.state.position.x, 400, "wander 關:全程原地")
        }
        XCTAssertEqual(loop.currentAction, PetActionID.walk, "行為圖不受影響")
        XCTAssertTrue(spy.poses.suffix(10).allSatisfy { $0.action == .walk },
                      "姿勢照常播放 walk 幀")
        XCTAssertEqual(loop.motion.state.velocity.dx, 0, "無巡航速度")
        // 開回:巡航恢復(首次 walk 於啟用狀態下擲籤定向)。
        loop.locomotionEnabled = true
        for _ in 0..<120 {
            loop.noteInteraction(.walk)
            loop.tick(dt: dt, regions: regions)
        }
        XCTAssertTrue(abs(loop.motion.state.position.x - 400) > 30,
                      "wander 開:巡航應恢復位移,實得 x=\(loop.motion.state.position.x)")
    }
}
