import AppKit
import Observation
import PetCore

/// V2 引擎當前幀的 ready-to-render 快照(C-P2c):driver 自 `loop.pack` 解析後發佈,
/// PetView 原樣消費 —— PetView 不得用 settings 重建 pack,杜絕 pack rebuild 競態。
struct V2RenderFrame {
    var rows: [String]
    var palette: [Character: UInt32]
    var gridWidth: Int
    var gridHeight: Int
    var mirrored: Bool
}

/// EngineV2 與 AppKit 的接縫(app 層白名單:本目錄)。職責僅限:
/// NSPanel origin 寫入(PosePresenting)、30Hz timer 掛載/invalidate/重掛、
/// NSScreen visibleFrame 訂閱重算 RegionMap、模型訊號 → working1 overlay 一態接線、
/// 相位輸入(quiet/mood/pack id)的 Observation 監聽(停表期間的唯一喚醒通道)。
/// 舊 wander 迴圈由 PetPanelController 以 flag 閘停用;flag 關閉時本類別完全不被建立。
@MainActor
final class EngineV2Driver: NSObject, @preconcurrency PosePresenting {
    private weak var panel: NSPanel?
    private weak var model: AppModel?
    /// 建立本 driver 的面板控制器(FIX-7):沿用其 `isWanderMoving` 抑制旗標,
    /// 讓 30Hz setFrameOrigin 不再讓 windowDidMove 反覆取消/重排位置持久化去抖
    /// (settings.json 抖動 —— 與 legacy L5 修過的同一問題)。
    private weak var controller: PetPanelController?
    private var loop: EngineLoop?
    private var timer: Timer?
    private var regions: RegionMap
    /// pack 幀的預切列快取(commit 每 tick 消費;建 loop 時一次切好,避免 30Hz split)。
    private var rowCache: [PetActionID: [[String]]] = [:]
    /// 已發佈幀的識別鍵(packId/action/frameIndex/mirrored):內容未變不重寫 v2Frame,
    /// 免去 30Hz 的 Observation 失效重繪(codex P2)。
    private var lastPublishedKey: (packId: String, action: PetActionID, frame: Int, mirrored: Bool)?
    private var governor = IdleGovernor()
    private var lastTickAt: Date?
    private var screenObserver: NSObjectProtocol?
    /// 相位觀察是否已註冊(withObservationTracking 為一次性,觸發後須重掛)。
    private var phaseWatchArmed = false
    /// 使用者拖曳中:tick 全停(不跑物理、不 commit),讓 isMovableByWindowBackground 背景拖曳
    /// 獨佔視窗位置;放手後 endUserDrag 把落點灌回模擬,避免 30Hz commit 把視窗 snap 回舊位(回彈)。
    private var isUserDragging = false

    init(panel: NSPanel, model: AppModel?, controller: PetPanelController? = nil) {
        self.panel = panel
        self.model = model
        self.controller = controller
        regions = RegionMap(visibleFrame: (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800))
        super.init()
        // 佈局變更(螢幕/dock)重算區域幾何(§4)。
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildRegions() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func start() {
        guard EngineV2.isEnabled else { return }
        regions = currentRegions()   // A1:先以收窄帶/flyer 封套建 regions,loop 即以「有界」regions 建立
                                     //(舊碼以 init 的全幀 regions 建 loop 再 rebuild → 首幀短暫無界)。
        if loop == nil {
            let origin = panel?.frame.origin ?? .zero
            let size = panel?.frame.size ?? .zero
            loop = makeLoop(packId: currentPackId(),
                            position: CGPoint(x: origin.x + size.width / 2, y: origin.y))
        } else {
            rebuildLoopIfPackChanged()   // FIX-2:show/hide 週期間物種可能已切換
        }
        rebuildRegions()   // A1:再導出 + 一次性水平/天花板夾限
        // 首 commit 前不留 legacy 空窗(grok P2-3):立即發佈目前動作的第 0 幀。
        if let loop { publishFrame(action: loop.currentAction, frameIndex: 0, mirrored: false) }
        armTimer()
        armPhaseWatch()
    }

    /// 停表:timer 必須 invalidate(深閒置 CPU 硬性守則)。
    /// 相位觀察不在此撤銷 —— 它是停表期間的喚醒通道(FIX-1),僅訊號監聽、無動畫 tick。
    /// FIX-7:解除位置持久化抑制,並如 wander 收尾般補寫一次最終位置
    /// (引擎驅動期間 windowDidMove 全遭抑制,不補寫會遺失最後位置)。
    func stop() {
        timer?.invalidate()
        timer = nil
        lastTickAt = nil
        if controller?.isWanderMoving == true {
            controller?.isWanderMoving = false
            if let panel { model?.savePetPosition(panel.frame.origin) }
        }
    }

    // MARK: - Pack 選擇與重建(FIX-2)

    private func currentPackId() -> String {
        model?.settings.speciesPackId ?? PetSpecies.dog.packId
    }

    /// Pack 註冊點(E1):狗/貓遷移包 + 鳥佔位包(bird 無 UI 入口;
    /// 經 settings.speciesPackIdOverride 到達,屬 flag 後偵錯/前向相容通道)。
    /// 選包經 settings 的 pack id facade;未知 id → dog(flag 矩陣:未知→"dog")。
    private func makeLoop(packId: String, position: CGPoint) -> EngineLoop {
        let registry = PackRegistry()
        let dog = SpeciesPacks.dogPack()
        registry.register(dog)
        registry.register(SpeciesPacks.catPack())
        registry.register(SpeciesPacks.birdPack())
        let engineLoop = EngineLoop(pack: registry.pack(id: packId) ?? dog,
                                    registry: registry,
                                    position: position,
                                    regions: regions,
                                    seed: 0x9021_7E57_B17D)
        engineLoop.presenter = self
        rowCache = engineLoop.pack.frames.mapValues { frames in
            frames.map { $0.components(separatedBy: "\n") }
        }
        return engineLoop
    }

    /// speciesPackId 變更 → 以新 pack 重建 EngineLoop(FIX-2)。位置保留;
    /// 行為/overlay 狀態 ephemeral(flag 矩陣:重啟自訊號重算),重建即重算,無需搬移。
    private func rebuildLoopIfPackChanged() {
        guard let current = loop else { return }
        let desired = currentPackId()
        guard current.pack.id != desired else { return }
        loop = makeLoop(packId: desired, position: current.motion.state.position)
        // 立即發佈新 pack 首幀(codex P2:不得短暫殘留舊物種快照)。
        if let loop { publishFrame(action: loop.currentAction, frameIndex: 0, mirrored: false) }
    }

    // MARK: - 相位觀察(FIX-1:停表期間的唯一喚醒通道)

    /// Observation 追蹤 quiet/pack id/漫遊開關/mood(僅訊號監聽,不是動畫 tick;
    /// 深閒置 CPU 守則不受影響)。withObservationTracking 一次性,觸發後重掛。
    private func armPhaseWatch() {
        guard !phaseWatchArmed else { return }
        phaseWatchArmed = true
        withObservationTracking { [weak self] in
            guard let self, let model = self.model else { return }
            _ = model.settings.quietMode
            _ = model.settings.speciesPackId
            _ = model.settings.petWanderEnabled   // FIX-9:漫遊開關變更也喚醒重估
            _ = model.settings.petWanderRangePercent   // A1:範圍變更 → 重算收窄帶
            _ = model.mood.mood
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.phaseWatchArmed = false
                self.phaseInputsChanged()
            }
        }
    }

    /// 相位輸入(quiet/mood/pack id)變更:重估 governor 指令 —— timer 已停且
    /// 相位回到可 tick(quiet 關閉、睡醒、設定變更)則重掛(FIX-1 re-arm 路徑);
    /// 物種切換則重建 loop(FIX-2)。
    private func phaseInputsChanged() {
        defer { armPhaseWatch() }
        guard EngineV2.isEnabled else { return }
        rebuildLoopIfPackChanged()
        rebuildRegions()   // A1:範圍/home 可能已變,收窄帶重算(內含一次性 clamp)
        let now = Date()
        updateGovernorPhase(at: now)
        if governor.directive(timerArmed: timer != nil, at: now) == .arm,
           panel?.isVisible == true {
            armTimer()
        }
    }

    // MARK: - tick

    private func armTimer() {
        guard timer == nil else { return }
        // FIX-7:timer 掛載的整段期間抑制 windowDidMove 的位置持久化(引擎以 30Hz 寫 origin)。
        // 沿用 wander 的既有旗標,但改為「掛表即設、停表才解」:windowDidMove 的檢查
        // 跑在 async Task 裡,wander 式的寫入前後瞬間包夾對 30Hz 引擎路徑不可靠。
        // 純邏輯不可測(AppKit delegate + Task 時序)—— 手動驗證:flag 開、盯著
        // settings.json 的 mtime,引擎漫遊期間不得每秒改寫;停表/隱藏時恰寫一次。
        controller?.isWanderMoving = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // 使用者拖曳中:整個 tick 全停(不跑物理、不 commit)。視窗位置由 AppKit 背景拖曳獨佔;
        // timer 續跑(cadence 不變),放手後 endUserDrag 續接。governor 不在拖曳期推進 → 不會誤停表。
        if isUserDragging { return }
        let now = Date()
        updateGovernorPhase(at: now)
        // 深閒置停表(睡眠 5s / quiet‧dock 10s;§2.2):invalidate 後由
        // start() 或相位觀察(armPhaseWatch → .arm 指令)重掛(FIX-1)。
        if governor.directive(timerArmed: true, at: now) == .stop {
            // 停表前最後硬保證:飛行中的 flyer 一次性 snap 落地,絕不讓鳥在半空被凍結
            //(停表後無 tick 可再帶其落定;補睡眠 re-hop / reduce-motion 慢降剛好卡在停表瞬間的邊界)。
            if loop?.motion.profile == .flyer, loop?.motion.state.grounded == false {
                loop?.motion.snapToGround(regions.groundY)
                loop?.commitPresentedPose()   // 面板實際移到地面(commit 才 setFrameOrigin;publishFrame 只
                                              // 換 sprite);且讓隨後 stop() 存下的是地面 origin,不是半空。
            }
            stop()
            return
        }
        rebuildLoopIfPackChanged()   // FIX-2:觀察通道之外的每 tick 保險(O(1) 字串比較)
        guard let loop, panel?.isVisible == true else { return }
        let dt = lastTickAt.map { now.timeIntervalSince($0) } ?? 1.0 / 30
        lastTickAt = now

        // working1 overlay 一態接線示範(§3-D:lastEventAt ≤60s 且 burn 檔 1 → mood 重塑)。
        loop.overlay = currentWorkingTier() == 1 ? .working1 : nil
        loop.masks = quietOrReduceMotionMasks()
        // FIX-9:legacy 的 petWanderEnabled 同樣約束引擎運動(關 = 姿勢照播、原地不動;
        // timer 不停 —— mood/overlay 動畫照常)。
        loop.locomotionEnabled = model?.settings.petWanderEnabled ?? false
        // 睡眠/靜默 → flyer 循環強制下降落地(補睡眠 5s 停表前的半空凍結洞;sleeping 不在 masks 內,
        // 必須顯式傳入;quiet 已由 masks 停 glue,此為雙保險)。
        loop.flyerResting = (model?.mood.mood == .sleeping) || (model?.settings.quietMode == true)
        _ = loop.tick(dt: dt, regions: regions)
    }

    /// 全部取自既有正規化欄位(各 provider 的 lastEventAt 取最新 / 全域 burnRateTokensPerHour)。
    private func currentWorkingTier() -> Int {
        guard let dashboard = model?.dashboard,
              let lastEvent = dashboard.limitStates.compactMap(\.lastEventAt).max() else { return 0 }
        return EngineV2.workingTier(secondsSinceLastEvent: Date().timeIntervalSince(lastEvent),
                                    tokensPerHour: dashboard.burnRateTokensPerHour)
    }

    private func quietOrReduceMotionMasks() -> BehaviorMasks {
        var masks: BehaviorMasks = []
        if model?.settings.quietMode == true { masks.insert(.quiet) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { masks.insert(.reduceMotion) }
        return masks
    }

    private func updateGovernorPhase(at now: Date) {
        let phase: IdleGovernor.Phase
        if model?.settings.quietMode == true {
            phase = .docked
        } else if model?.mood.mood == .sleeping {
            phase = .sleeping
        } else {
            phase = .active
        }
        governor.setPhase(phase, at: now)
    }

    private func rebuildRegions() {
        regions = currentRegions()
        // 帶可能已變窄:對引擎位置做一次性水平 clamp(F3;避免下一 tick 的邊界瞬移)。
        loop?.motion.clampHorizontally(into: regions.bounds)
        // range 縮小 → flyer 天花板下移;鳥若在新天花板之上,一次性拉回並吸掉上行動量
        //(循環隨後自然下降落地)。僅 .flyer 套用,不動其他物種。
        if loop?.motion.profile == .flyer {
            loop?.motion.clampBelowCeiling(regions.flyer.ceiling)
        }
    }

    /// 螢幕 visibleFrame → 依漫遊範圍帶水平收窄(§4 高度公式不動;home 取面板控制器)。
    private func currentRegions() -> RegionMap {
        let vf = (panel?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let range = WanderBand.clampRangePercent(model?.settings.petWanderRangePercent ?? 100)
        // range=100 恆走全幀路徑(WanderBand.centerBand 在 100% 會多加 pet margin、位移 X;
        // flyer 封套預設 100 = 傳統無界)。僅 <100 才收窄 X 並縮放 flyer 垂直封套。
        guard range < 100, let panel else { return RegionMap(visibleFrame: vf) }
        let petW = panel.frame.width
        let home = controller?.wanderHomeCenterX ?? panel.frame.midX
        let band = WanderBand.centerBand(homeCenterX: home, rangePercent: range,
                                         screen: vf, petWidth: petW)
        // bounds = center band 本身(Motion 夾 center-x;外接半寬只屬 legacy origin)。
        // flyerRangePercent 以 ground-lerp 縮放 flyer 垂直封套;water/air/hover/bounds 不動。
        return RegionMap(visibleFrame: WanderBand.narrowedFrame(visibleFrame: vf, centerBand: band),
                         flyerRangePercent: range)
    }

    /// 漫遊帶輸入(home/range/寵物尺寸)變更時由面板控制器**同步**呼叫 —— phase watch
    /// 的 Observation 喚醒走非同步 Task,30Hz tick 可能先以舊 regions 跑一幀(grok P2-2)。
    func wanderBandDidChange() {
        guard EngineV2.isEnabled else { return }
        rebuildRegions()
    }

    // MARK: - 使用者拖曳(由 PetPanelController 的視窗移動 delegate 驅動)

    /// 拖曳開始:暫停引擎(tick 全停)→ commit 不再與背景拖曳搶視窗位置。
    /// governor 設為 active,避免拖曳期間(tick 停)累積閒置而放手後立刻停表。
    func beginUserDrag() {
        isUserDragging = true
        governor.setPhase(.active, at: Date())
    }

    /// 拖曳結束:把視窗當前 origin(使用者落點)灌回模擬位置(底部中心錨),恢復引擎。
    /// lastTickAt 清空 → 下一 tick 以預設 dt 起步,不因暫停期累積出暴衝 dt。落點的帶重錨/
    /// 夾限由控制器隨後的 reanchorWanderHome()(→ wanderBandDidChange → rebuildRegions)完成。
    func endUserDrag() {
        isUserDragging = false
        lastTickAt = nil
        governor.setPhase(.active, at: Date())
        guard let panel, let loop else { return }
        let o = panel.frame.origin
        loop.motion.teleport(to: CGPoint(x: o.x + panel.frame.width / 2, y: o.y))
    }

    // MARK: - PosePresenting(單一寫入者:每 tick 恰一次 origin 寫入)

    func commit(_ pose: ComposedPose) {
        guard let panel else { return }
        // 底部中心錨 → NSPanel origin;呈現座標已依凍結規則取整。
        let origin = NSPoint(x: pose.position.x + pose.anchorOffset.x - panel.frame.width / 2,
                             y: pose.position.y + pose.anchorOffset.y)
        panel.setFrameOrigin(origin)

        publishFrame(action: pose.action, frameIndex: pose.frameIndex, mirrored: pose.mirrored)
    }

    /// E2a 渲染接管(C-P2c):自「引擎實際使用的 pack」解析幀 → 發佈 ready-to-render
    /// 快照;PetView 原樣消費,不得用 settings 重建 pack(pack rebuild 競態)。
    /// 內容未變(同 pack/action/frame/mirrored)不重寫 —— 30Hz 下多數 tick 為同幀。
    private func publishFrame(action: PetActionID, frameIndex: Int, mirrored: Bool) {
        guard let loop, !loop.pack.palette.isEmpty else {
            // pack 未附美術(理論上 E2a 後不會發生)→ PetView 沿 legacy 渲染。
            if model?.v2Frame != nil { model?.v2Frame = nil }
            lastPublishedKey = nil
            return
        }
        let frames = rowCache[action] ?? []
        guard !frames.isEmpty else { return }
        let idx = min(max(0, frameIndex), frames.count - 1)
        let key = (loop.pack.id, action, idx, mirrored)
        if let last = lastPublishedKey,
           last.packId == key.0, last.action == key.1, last.frame == key.2, last.mirrored == key.3 {
            return
        }
        lastPublishedKey = (key.0, key.1, key.2, key.3)
        model?.v2Frame = V2RenderFrame(rows: frames[idx],
                                       palette: loop.pack.palette,
                                       gridWidth: loop.pack.gridWidth,
                                       gridHeight: loop.pack.gridHeight,
                                       mirrored: mirrored)
    }
}
