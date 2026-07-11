import AppKit
import Observation
import PetCore

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
    private var governor = IdleGovernor()
    private var lastTickAt: Date?
    private var screenObserver: NSObjectProtocol?
    /// 相位觀察是否已註冊(withObservationTracking 為一次性,觸發後須重掛)。
    private var phaseWatchArmed = false

    init(panel: NSPanel, model: AppModel?, controller: PetPanelController? = nil) {
        self.panel = panel
        self.model = model
        self.controller = controller
        regions = Self.currentRegions(for: panel)
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
        if loop == nil {
            let origin = panel?.frame.origin ?? .zero
            let size = panel?.frame.size ?? .zero
            loop = makeLoop(packId: currentPackId(),
                            position: CGPoint(x: origin.x + size.width / 2, y: origin.y))
        } else {
            rebuildLoopIfPackChanged()   // FIX-2:show/hide 週期間物種可能已切換
        }
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
        registry.register(SpeciesPacks.birdPlaceholder())
        let engineLoop = EngineLoop(pack: registry.pack(id: packId) ?? dog,
                                    registry: registry,
                                    position: position,
                                    regions: regions,
                                    seed: 0x9021_7E57_B17D)
        engineLoop.presenter = self
        return engineLoop
    }

    /// speciesPackId 變更 → 以新 pack 重建 EngineLoop(FIX-2)。位置保留;
    /// 行為/overlay 狀態 ephemeral(flag 矩陣:重啟自訊號重算),重建即重算,無需搬移。
    private func rebuildLoopIfPackChanged() {
        guard let current = loop else { return }
        let desired = currentPackId()
        guard current.pack.id != desired else { return }
        loop = makeLoop(packId: desired, position: current.motion.state.position)
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
        let now = Date()
        updateGovernorPhase(at: now)
        // 深閒置停表(睡眠 5s / quiet‧dock 10s;§2.2):invalidate 後由
        // start() 或相位觀察(armPhaseWatch → .arm 指令)重掛(FIX-1)。
        if governor.directive(timerArmed: true, at: now) == .stop {
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
        regions = Self.currentRegions(for: panel)
    }

    private static func currentRegions(for panel: NSPanel?) -> RegionMap {
        let vf = (panel?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return RegionMap(visibleFrame: vf)
    }

    // MARK: - PosePresenting(單一寫入者:每 tick 恰一次 origin 寫入)

    func commit(_ pose: ComposedPose) {
        guard let panel else { return }
        // 底部中心錨 → NSPanel origin;呈現座標已依凍結規則取整。
        // 【E2 預告 · 雙審裁定非本階段缺陷】依 E0 packet §2,Bridge 職責僅 NSPanel
        // origin 寫入 —— pose 的 action/frameIndex/mirrored 要到美術階段(E2)由
        // PetView 的 pack 渲染接管時才消費;flag 開啟期間 legacy 渲染仍畫舊皮,
        // 此為刻意分期(渲染接管與真 sheets 同批落地),非遺漏。
        let origin = NSPoint(x: pose.position.x + pose.anchorOffset.x - panel.frame.width / 2,
                             y: pose.position.y + pose.anchorOffset.y)
        panel.setFrameOrigin(origin)
    }
}
