import Foundation
import AppKit
import Observation
import UsageCore
import PetCore

// `RangePreset` / `RangeSelection`(分頁時間範圍選擇)自 Usage-M3 B 起住在 UsageCore(DashboardRange.swift):
// Projects 與 Models 各持一份 `RangeSelection`,區間構造只有 `RangeSelection.interval(now:)` 一份實作。

@MainActor
@Observable
final class AppModel {
    // 對 UI 暴露的狀態
    private(set) var dashboard: DashboardState = .empty
    /// F17 信任層:各 provider local 源的健康狀態(Data Health 面板消費;refresh 後更新)。
    private(set) var sourceStatuses: [DataSourceStatus] = []
    private(set) var settings: AppSettings
    private(set) var petState: PetStateData
    private(set) var mood = MoodEngine.Result(mood: .idle, animationSpeed: 1, summary: "starting…", reason: "Starting up…")
    private(set) var treatsAvailable = 0
    private(set) var refreshing = false
    private(set) var reindexing = false

    // Projects 頁狀態(Usage-M3 B:區間選擇為值型別 `RangeSelection`;Projects 與 Models **各持一份**,互不共享)
    var projectsRange = RangeSelection()
    private(set) var projectPage: ProjectPageData?

    // Models 頁狀態(Usage-M3 B):自有 range + 自有 page 槽(序號守門在 `SequencedSlot` 內),與 Projects 的
    // `projectsRange` / `projectPage` / `projectPageLoadSeq` 三層完全分離 —— Models 換 range 不動 Projects,
    // 較舊的 Models 重載完成也不可能蓋掉較新者。
    var modelsRange = RangeSelection()
    private var modelPageSlot = SequencedSlot<ModelPageData>()
    var modelPage: ModelPageData? { modelPageSlot.value }

    // Trends 頁狀態(7 / 30 / 90 天)
    var trendsRangeDays: Int = 30
    private(set) var trends: TrendsData?

    /// Dashboard 視窗是否開啟(DashboardRoot onAppear/onDisappear 維護)。
    /// 關閉時 refreshNow 不重算 Projects/Trends 聚合 —— FSEvents 高頻刷新下,
    /// 沒人看的 All-time 聚合是 CPU / RSS 高水位的主要來源(2026-08-08 效能修正)。
    private(set) var dashboardWindowOpen = false

    // 內部
    let coordinator: UsageCoordinator
    /// OpenRouter credits 監控(opt-in;獨立 15 分鐘節奏,刻意不掛 FSEvents 刷新風暴)。
    let orCredits = OpenRouterCreditsChecker()
    let grokQuota = GrokQuotaChecker()
    private let settingsStore: SettingsStore
    private let dataDir: URL
    /// monitor-only(低 RAM)模式下完全不建立;只在 full 模式第一次用到時載入。
    private var feeding: FeedingEngine?
    private var petPanel: PetPanelController?
    private var refreshLoop: Task<Void, Never>?
    private var activeMinutesToday: Double = 0
    /// 設定推送到 coordinator 的序列化尾巴:每次推送先 await 前一個,保證按呼叫順序落地
    /// (fire-and-forget Task 不保證順序,舊 core 可能覆蓋新 core)。
    private var settingsPushTask: Task<Void, Never>?
    /// FSEvents 檔案監看:provider 記錄變更即 refresh(取代 45s 輪詢);nil = 未啟用/建立失敗。
    private var fileWatcher: FileWatcher?
    /// refresh 進行中又有新變更 → 記錄待處理,跑完再補一次(coalesce 檔案事件突發)。
    private var refreshPending = false
    /// 是否所有已啟用的 provider 都已監看到記錄目錄。false 時維持快速輪詢以儘快發現新目錄,
    /// 全部鎖定後才切到 300s 慢速 fallback。
    private var allProviderRootsWatched = false
    /// Codex Source B(app-server)官方額度抓取的 guardrail 閘(owner 2026-10-09):single-flight +
    /// ~60s 最小間隔。活動(startup / FSEvents / 300s safety-net,皆經 refreshNow)可立即請求,
    /// 但實際 spawn `codex app-server` 不超過 ~每 60s 一次;純決策在 UsageCore(已測)。
    private var codexFetchGate = CodexAppServerLimits.FetchGate(minInterval: 60)
    private var codexFetchTask: Task<Void, Never>?
    /// stop() 後 fence:進行中的背景抓取(Task.detached 不受父 cancel 影響)完成時,據此不得再
    /// setCodexOfficialReadings / refreshNow(避免 teardown 後復活一次刷新)。
    private var codexStopped = false

    init() {
        dataDir = AppPaths.dataDirectory()
        settingsStore = SettingsStore(dataDir: dataDir)
        settings = settingsStore.settings
        coordinator = UsageCoordinator(dataDir: dataDir, settings: settingsStore.settings.core)
        petState = PetStateData()
    }

    /// full 模式限定的餵食引擎存取(延遲建立並載回持久化狀態)。
    private var feedingEngine: FeedingEngine {
        if let feeding { return feeding }
        let engine = FeedingEngine(stateURL: dataDir.appendingPathComponent("pet-state.json"))
        feeding = engine
        petState = engine.state
        return engine
    }

    // MARK: - 生命週期

    func start() {
        // 持久化的 Appearance 偏好在任何視窗/面板建立前先套到 NSApp(整 app 一體繼承)。
        applyAppearancePreference()
        // EngineV2 flag 必須在 petPanel 建立前映射(PetPanelController.show() 據此掛 driver)。
        EngineV2.isEnabled = settings.petEngineV2Enabled
        if LaunchAtLogin.available {
            let enabled = LaunchAtLogin.isEnabled
            if settings.launchAtLogin != enabled {
                updateSettings { $0.launchAtLogin = enabled }
            }
        }
        if settings.notificationsEnabled { Notifier.requestAuthorization() }
        orCredits.setEnabled(settings.openRouterCreditsEnabled)
        grokQuota.killedAtVersion = (
            get: { [weak self] in self?.settings.grokQuotaKilledAtVersion },
            set: { [weak self] v in self?.updateSettings { $0.grokQuotaKilledAtVersion = v } })
        grokQuota.setEnabled(settings.grokQuotaEnabled, isUserAction: false)   // bootstrap ≠ 手動 re-enable(r3)
        applyModeSideEffects()
        observeAppearanceChanges()
        // 排程匯出:啟動時重套(修正 app 被移動後 plist 內失效的絕對路徑);僅 bundle 版有效。
        if ScheduledReportManager.available { applyScheduledExport() }
        // 初次刷新 → 啟動 FSEvents 檔案監看 → 慢速 fallback 迴圈(補漏事件 + 撿後來出現的目錄)。
        refreshLoop = Task { [weak self] in
            await self?.refreshNow()
            await self?.startFileWatching()
            while !Task.isCancelled {
                // 慢速 fallback 只在「FSEvents 已鎖定至少一個 provider 記錄目錄」時採用;
                // 只監看 statusline 父目錄(尚無 provider 目錄)時維持快速輪詢以儘快發現新目錄。
                let watching = (self?.fileWatcher?.isActive ?? false) && (self?.allProviderRootsWatched ?? false)
                let poll = max(15, self?.settings.refreshIntervalSeconds ?? 45)
                let delay = watching ? 300.0 : poll
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.startFileWatching()   // rebuild roots:撿啟動後才建立的目錄
                await self?.refreshNow()
            }
        }
    }

    /// (重)啟動 FSEvents 監看目前存在的 provider 記錄目錄。變更 → 跳 MainActor 觸發 refresh。
    private func startFileWatching() async {
        let plan = await coordinator.watchPlan()
        allProviderRootsWatched = plan.allEnabledRootsWatched
        if fileWatcher == nil {
            fileWatcher = FileWatcher(debounce: 1.0) { [weak self] in
                Task { @MainActor in await self?.refreshNow() }
            }
        }
        fileWatcher?.start(dirs: plan.dirs, triggers: plan.triggers)
    }

    /// 停止背景活動(app 終止時呼叫)。
    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
        fileWatcher?.stop()
        fileWatcher = nil
        settingsPushTask?.cancel()
        codexStopped = true           // fence:in-flight 抓取完成後不得再 apply/refresh
        codexFetchTask?.cancel()      // Source B:停止背景抓取(ProcessTransport 以 bounded timeout + teardown 自清)
        orCredits.setEnabled(false)
        grokQuota.setEnabled(false)   // r1 三鏡:stop 漏停 grok 會讓輪詢在 teardown 後殘留
    }

    /// 系統深/淺色切換時選單列徽章需重烤(NSImage 顏色是預先算好的)。
    /// 與手動 Appearance 偏好變更(`applyAppearancePreference()`)共用同一個 `appearanceTick`。
    private func observeAppearanceChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appearanceTick += 1 }
        }
    }

    /// 把 app 外觀偏好套到 NSApp —— 整 app 唯一一處指派,Dashboard / Settings / A1 hover panel /
    /// menu-bar panel / pet panel / NSSavePanel 全部繼承(`.system` → nil = 回到跟隨系統)。
    /// 隨後走**同一條** `appearanceTick` 重烤路徑:手動偏好變更與系統外觀通知只有一個 refresh authority。
    private func applyAppearancePreference() {
        NSApp.appearance = settings.appearance.nsAppearanceName.flatMap { NSAppearance(named: $0) }
        appearanceTick += 1
    }

    /// 使用者手動刷新(⌘R / Refresh 鈕專用):credits/grok 的 manual 語義**只**綁真
    /// 使用者動作 —— refreshNow() 也被啟動/輪詢/FSEvents 自動呼叫,在那裡冒用 manual
    /// 會 bypass 401/kill 門檻(r4 ultra;與 bootstrap≠manual 同構)。
    func userRefresh() async {
        orCredits.refreshNow()
        if settings.grokQuotaEnabled { grokQuota.refreshNow() }
        requestCodexOfficialFetch()   // ⌘R 亦受統一 60s 閘 + 單流(owner:B spawn 不超過 ~每 60s 一次)
        await refreshNow()
    }

    // MARK: - Codex Source B(app-server)官方額度 — off-hot-path 抓取(owner 2026-10-09)

    /// 請求一次 Source B 抓取。預設開啟(偵測到 codex 即整合;非 opt-in):codex 未啟用 → 清空
    /// stash(→ fallback 回 Source A);gate 以**單調時鐘**擋下 single-flight 與 ~60s 最小間隔
    /// (含手動,無例外)。絕不阻塞:實際 spawn 在 detached 背景執行。
    func requestCodexOfficialFetch() {
        guard !codexStopped else { return }   // stop() 後不得再發動(擋 teardown 期間 queued 的 refreshNow)
        guard settings.core.enabledProviders.contains("codex") else {
            // codex 停用:清空 stash,確保不殘留 B 影響(下輪 refresh 以純 Source A 規則治理)。
            Task { [weak self] in await self?.coordinator.setCodexOfficialReadings([]) }
            return
        }
        guard codexFetchGate.decide(now: ProcessInfo.processInfo.systemUptime) == .proceed else { return }
        codexFetchGate.begin()
        codexFetchTask = Task { [weak self] in await self?.performCodexOfficialFetch() }
    }

    private func performCodexOfficialFetch() async {
        // 探路 + spawn 皆在背景(spawn ~0.8–2.5s;不得阻塞 MainActor 或 coordinator actor)。
        // nil = 未偵測到 codex;[] = codex 在但抓取失敗;[reading] = 成功。三者都收斂成「寫 stash
        // (nil→[])」→ 失敗/消失時清掉舊 B,改由 Source A 既有 freshness/expiry 規則治理(fail soft)。
        let readings: [RateLimitReading] = await Task.detached(priority: .utility) {
            guard let binary = CodexAppServerLimits.discoverCodexBinary() else { return [] } // 未安裝 → fail-soft
            let transport = CodexAppServerLimits.ProcessTransport(binary: binary)
            return CodexAppServerLimits.fetchReadings(transport: transport, timeout: 10)  // observedAt 於完成時蓋章
        }.value
        codexFetchGate.finish(at: ProcessInfo.processInfo.systemUptime)   // 解除單流 + 記錄抓取時刻
        // fence:抓取期間 app 已 stop 或 codex 已被停用 → 不得 apply/refresh(Task.detached 不受父 cancel)。
        guard !codexStopped, settings.core.enabledProviders.contains("codex") else { return }
        await coordinator.setCodexOfficialReadings(readings)   // 成功 = fresh 讀值;失敗/消失 = [] → fallback A
        // 跨 await 重 check:setCodexOfficialReadings 期間若 stop/停用,不得再 resurrect 一次 refresh。
        guard !codexStopped, settings.core.enabledProviders.contains("codex") else { return }
        await refreshNow()                          // 經既有單一權威把 B 併入顯示(此輪 min-interval 自然跳過)
    }

    func refreshNow() async {
        // Codex Source B hybrid(owner 2026-10-09):startup / FSEvents / 300s safety-net 全部匯流到此,
        // 故在此請求一次 off-hot-path 的 app-server 抓取(gate 做 single-flight + 60s 最小間隔,防 spawn
        // storm;抓取結束後自身會再呼叫一次 refreshNow 把 fresh B 併入顯示,屆時 min-interval 自然跳過)。
        requestCodexOfficialFetch()
        // 進行中又被要求 → 記錄待處理,由目前這輪跑完後補一次(coalesce 檔案事件突發)。
        guard !refreshing else { refreshPending = true; return }
        refreshing = true
        defer { refreshing = false }

        repeat {
            refreshPending = false

            let outcome = await coordinator.refresh()
            dashboard = outcome.dashboard
            activeMinutesToday = await coordinator.activeMinutesToday()
            sourceStatuses = await assembleSourceStatuses()   // F17 信任層(local + API 分列)

            handleTransitions(outcome.transitions)

            syncPetAfterDashboard()

            // 任何範圍(含 custom)都要跟著刷新,否則專案表會停留在舊資料。
            // 視窗關閉時跳過(重開時 dashboardOpened() + 各分頁 .task 會補載)。
            if dashboardWindowOpen {
                await reloadProjectPage()
                await reloadModelPage()   // Usage-M3 B:Models 分頁自有投影(1 walk;無新事件時 O(1) 快取命中)
                await reloadTrends()
            }
        } while refreshPending
    }

    /// 重載寫回競態防護(xcheck r2 luna-ultra 提出、r3 luna-ultra 補強):任何兩條
    /// in-flight 重載鏈(close→reopen 的越代殘鏈、refresh 鏈 vs reopen 鏈、range 快速
    /// 切換)在 MainActor 上的 continuation **resume 順序不保證等於 actor 完成順序**,
    /// 舊結果可能後寫覆蓋新結果並 stale 到下一輪 refresh。防護:每個 surface 一個單調
    /// 發起序號,寫回時「只有最新發起者」落地 —— 舊 continuation 無論何時 resume,
    /// 序號必不匹配而被丟棄(比 r2 的 per-generation 方案強:同代交錯也涵蓋)。
    private var projectPageLoadSeq: UInt64 = 0
    private var trendsLoadSeq: UInt64 = 0

    /// DashboardRoot onAppear:恢復分頁聚合並立即補一次(關窗期間的變更)。
    func dashboardOpened() {
        dashboardWindowOpen = true
        Task { [weak self] in
            await self?.reloadProjectPage()
            await self?.reloadModelPage()
            await self?.reloadTrends()
        }
    }

    func dashboardClosed() {
        dashboardWindowOpen = false
    }

    /// F17:Data Health 面板開啟時主動拉一次(不等下一輪 refresh)。
    func refreshSourceStatuses() async {
        sourceStatuses = await assembleSourceStatuses()
    }

    /// F17 組裝:coordinator 的 local 源列 + GUI 層 API 源列(owner UI 語義:同 provider
    /// 的 local 與 API 源**分列**,health/freshness/auth 各自獨立 —— API 的 401 絕不
    /// 污染 local 列)。順序:依 provider 分組、local 在前。
    private func assembleSourceStatuses() async -> [DataSourceStatus] {
        var rows = await coordinator.dataSourceStatuses()
        let api = grokQuota.dataSourceStatus()   // 恆列示(disabled 即顯 Disabled 態)
        if let i = rows.lastIndex(where: { $0.providerId == "grok-code" }) {
            rows.insert(api, at: rows.index(after: i))
        } else {
            rows.append(api)
        }
        return rows
    }

    func fullReindex() async {
        reindexing = true
        defer { reindexing = false }
        let outcome = await coordinator.refresh(fullReindex: true)
        dashboard = outcome.dashboard
        activeMinutesToday = await coordinator.activeMinutesToday()
        sourceStatuses = await assembleSourceStatuses()   // F17:reindex 也要刷新健康態(xcheck f17-r1)
        // 重建後同步寵物側,否則 Pet 卡/a11y/匯出的 mood(含 reason 裡的百分比)沿用
        // 重建前的舊值直到下次排程刷新(codex SEV2 round-2)。轉變(transitions)刻意
        // 不處理:重建是重放,不該觸發慶祝/通知。
        syncPetAfterDashboard()
        if dashboardWindowOpen {
            await reloadProjectPage()
            await reloadModelPage()
            await reloadTrends()
        }
    }

    /// dashboard 更新後同步寵物側(tick / warning / treats / mood)。monitor-only 無寵物 → no-op。
    private func syncPetAfterDashboard() {
        guard settings.appMode == .full else { return }
        let engine = feedingEngine
        engine.tick(activeMinutesToday: activeMinutesToday, tokensToday: dashboard.todayTotals.total)
        if dashboard.limitStates.contains(where: { $0.warning == .warning || $0.warning == .exhausted }) {
            engine.noteWarningSeen()
        }
        petState = engine.state
        treatsAvailable = engine.treatsAvailable(activeMinutesToday: activeMinutesToday)
        mood = MoodEngine.evaluate(dashboard: dashboard, pet: petState,
                                   warnThreshold: settings.core.warnThresholdPercent)
    }

    private func handleTransitions(_ transitions: [LimitTransition]) {
        for transition in transitions {
            switch transition {
            case let .reset(providerId, window, estimated):
                if settings.appMode == .full {
                    // 歸因傳給寵物:慶祝訊息要能說出「誰的哪個窗、是否估算」(使用者實測:
                    // 無歸因的慶祝被誤認成別家 provider 的官方重置)。
                    feedingEngine.celebrate(until: Date().addingTimeInterval(120),
                                            providerId: providerId, window: window, estimated: estimated)
                    petState = feedingEngine.state
                }
                // 標題是通知最顯眼的表面 —— 估算邊界連標題都不得是無修飾的事實句(codex SEV1 round-2)。
                notify(title: estimated ? "Quota likely reset 🎉" : "Quota reset 🎉",
                       body: estimated
                           ? "\(providerName(providerId)) \(window) block has likely reset (estimated from local activity)."
                           : "\(providerName(providerId)) \(window) window has reset.")
            case let .crossedThreshold(providerId, window, percent, threshold):
                notify(title: "Usage warning",
                       body: "\(providerName(providerId)) \(window) window at \(Int(min(100, percent)))% (threshold \(Int(threshold))%).")
            case let .exhausted(providerId, window):
                notify(title: "Quota exhausted",
                       body: "\(providerName(providerId)) \(window) window is fully used.")
            }
        }
    }

    private func notify(title: String, body: String) {
        guard settings.notificationsEnabled, !settings.quietMode else { return }
        // Snooze Alerts:期限內靜音通知;追蹤與 UI 照常更新
        if let until = settings.alertsSnoozedUntil, until > Date() { return }
        Notifier.post(title: title, body: body)
    }

    // MARK: - Snooze Alerts

    /// 目前有效的 snooze 期限(過期視同未 snooze)。
    var activeSnoozeUntil: Date? {
        guard let until = settings.alertsSnoozedUntil, until > Date() else { return nil }
        return until
    }

    func snoozeAlerts(for duration: TimeInterval) {
        updateSettings { $0.alertsSnoozedUntil = Date().addingTimeInterval(duration) }
    }

    func snoozeAlertsUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        updateSettings { $0.alertsSnoozedUntil = tomorrow }
    }

    func cancelSnooze() {
        updateSettings { $0.alertsSnoozedUntil = nil }
    }

    func providerName(_ id: String) -> String {
        dashboard.snapshots.first { $0.providerId == id }?.displayName ?? id
    }

    // MARK: - 設定

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let oldMode = settings.appMode
        let oldProviders = settings.core.enabledProviders
        let oldEngineV2 = settings.petEngineV2Enabled
        let oldRange = settings.petWanderRangePercent
        let oldORCredits = settings.openRouterCreditsEnabled
        let oldGrokQuota = settings.grokQuotaEnabled
        let oldAppearance = settings.appearance
        settingsStore.update(mutate)
        settings = settingsStore.settings
        // Appearance 偏好變更 → 與啟動套用同一條 apply/refresh 路徑(NSApp.appearance + appearanceTick)。
        if oldAppearance != settings.appearance {
            applyAppearancePreference()
        }
        // OpenRouter credits 開關:啟用即抓一次 + 開始 15 分鐘輪詢;停用即取消並清空狀態。
        if oldGrokQuota != settings.grokQuotaEnabled {
            grokQuota.setEnabled(settings.grokQuotaEnabled)
            Task { [weak self] in await self?.refreshSourceStatuses() }   // Data Health 立即反映
        }
        if oldORCredits != settings.openRouterCreditsEnabled {
            orCredits.setEnabled(settings.openRouterCreditsEnabled)
        }
        // Pet Engine V2 切換:flag 先映射;面板重建整合進下方的單一分派
        //(避免重建後又走一次 apply 的雙重 restart;grok P2-6)。
        let v2Toggled = oldEngineV2 != settings.petEngineV2Enabled
        if v2Toggled {
            EngineV2.isEnabled = settings.petEngineV2Enabled
            if !settings.petEngineV2Enabled { v2Frame = nil }
        }
        // 串接成序列:第 N 次推送先 await 第 N-1 次,coordinator 收斂到最後寫入的值。
        let core = settings.core
        let previousPush = settingsPushTask
        settingsPushTask = Task { [weak self] in
            _ = await previousPush?.value
            await self?.coordinator.updateSettings(core)
        }
        if oldMode != settings.appMode {
            applyModeSideEffects()
        } else if v2Toggled, settings.appMode == .full {
            // V2 切換 → 整座重建 petPanel(driver 掛在 show()、舊 wander 閘在建立期讀
            // flag);destroy() 無條件補寫位置、restoreOrigin() 讀回,切換不丟位置。
            petPanel?.destroy()
            petPanel = PetPanelController(model: self)
            petPanel?.apply(settings: settings)
        } else {
            petPanel?.apply(settings: settings)
        }
        // 範圍變更 → 統一重錨 + 帶內夾限 + V2 同步重算(計畫 A1 觸發 (d))。
        if oldRange != settings.petWanderRangePercent {
            petPanel?.reanchorWanderHome()
        }
        // 啟用的 provider 變更 → 等設定推送到 coordinator 後立即重建 FSEvents 監看,
        // 不必等 300s fallback 才開始監看新啟用 provider 的目錄(watchPlan 依 coordinator 設定)。
        if oldProviders != settings.core.enabledProviders {
            let push = settingsPushTask
            Task { [weak self] in
                _ = await push?.value
                await self?.startFileWatching()
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        updateSettings { $0.launchAtLogin = on }
        LaunchAtLogin.setEnabled(on)
    }

    /// 套用目前的每日排程匯出設定到 launchd(啟用/停用/改時間或資料夾後呼叫)。
    func applyScheduledExport() {
        ScheduledReportManager.apply(settings: settings)
    }

    /// 模式切換的核心:monitor-only 完全銷毀寵物視窗與動畫(省 RAM),
    /// 而不是單純隱藏。
    private func applyModeSideEffects() {
        switch settings.appMode {
        case .full:
            _ = feedingEngine // 載回持久化的寵物狀態(getter 副作用設 petState)
            // 立即以現有 dashboard + 載回的 petState 重算 mood —— 否則 tooltip/caption/a11y/export
            // 會顯示切回 full 之前的陳舊心情(含陳舊 provenance)直到下次刷新(codex SEV2)。
            mood = MoodEngine.evaluate(dashboard: dashboard, pet: petState,
                                       warnThreshold: settings.core.warnThresholdPercent)
            if petPanel == nil { petPanel = PetPanelController(model: self) }
            petPanel?.apply(settings: settings)
            if settings.petVisible { petPanel?.show() }
        case .monitorOnly:
            petPanel?.destroy()
            petPanel = nil
            feeding = nil // 釋放互動引擎;寵物狀態已持久化,切回 full 會載回
        }
    }

    func savePetPosition(_ origin: CGPoint) {
        settingsStore.update {
            $0.petPositionX = origin.x
            $0.petPositionY = origin.y
        }
        settings = settingsStore.settings
    }

    // MARK: - 餵食

    /// 餵食失敗的原因說明(寵物泡泡顯示;寵物隱藏時退回系統通知)。
    private(set) var feedNotice: (text: String, at: Date)?

    @discardableResult
    func feed(_ food: FoodItem) -> FeedingEngine.FeedResult {
        guard settings.appMode == .full else { return .notHungry }
        let engine = feedingEngine
        let result = engine.feed(food, activeMinutesToday: activeMinutesToday)
        petState = engine.state
        treatsAvailable = engine.treatsAvailable(activeMinutesToday: activeMinutesToday)
        switch result {
        case .ok:
            mood = MoodEngine.evaluate(dashboard: dashboard, pet: petState,
                                       warnThreshold: settings.core.warnThresholdPercent)
        case .notHungry:
            postFeedNotice("I'm full! (fullness \(Int(petState.hunger))%)")
        case .noTreats:
            postFeedNotice("no treats — earn 1 per 25 min of real work")
        case .kibbleLimitReached:
            postFeedNotice("kibble cap reached for today")
        }
        return result
    }

    private func postFeedNotice(_ text: String) {
        feedNotice = (text, Date())
        if !settings.petVisible {
            notify(title: "Feeding", body: text)
        }
    }

    // MARK: - Projects / Models 頁範圍(Usage-M3 B:各自一份 RangeSelection,同一份 interval 實作)

    /// Projects 分頁的查詢區間(= `projectsRange.interval`;唯一實作在 UsageCore `RangeSelection`)。
    func currentRange(now: Date = Date()) -> DateInterval { projectsRange.interval(now: now) }

    /// Models 分頁的查詢區間(= `modelsRange.interval`;與 Projects 的選擇值無關)。
    func currentModelsRange(now: Date = Date()) -> DateInterval { modelsRange.interval(now: now) }

    func reloadProjectPage() async {
        projectPageLoadSeq &+= 1
        let seq = projectPageLoadSeq
        let data = await coordinator.projectPage(range: currentRange())
        if seq == projectPageLoadSeq { projectPage = data }   // 只有最新發起者可寫(見 seq 註解)
    }

    /// Usage-M3 B:Models 分頁重載(鏡射 reloadProjectPage;自有序號 —— 守門在 `SequencedSlot.publish` 內,
    /// 較舊發起者的完成無論何時 resume 都被丟棄,不可能蓋掉較新結果)。
    func reloadModelPage() async {
        let ticket = modelPageSlot.begin()
        let data = await coordinator.modelPage(range: currentModelsRange())
        modelPageSlot.publish(ticket, data)
    }

    func reloadTrends() async {
        trendsLoadSeq &+= 1
        let seq = trendsLoadSeq
        let data = await coordinator.trendsData(days: trendsRangeDays)
        if seq == trendsLoadSeq { trends = data }
    }

    // MARK: - 匯出

    func exportReport(kind: ReportKind, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.title = "Export HTML Report"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let summary = settings.appMode == .full
            ? "\(settings.resolvedSpecies.displayName) mood: \(mood.mood.rawValue) · level \(petState.level) · \(mood.reason) · \(mood.summary)"
            : nil
        Task {
            do {
                try await coordinator.exportReport(kind: kind, to: url, petSummary: summary)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                notifyExportFailure(error)
            }
        }
    }

    private func notifyExportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = String(describing: error)
        alert.runModal()
    }

    func exportToday() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        exportReport(kind: .today, suggestedName: "AIPetUsage-Report-\(df.string(from: Date())).html")
    }

    /// Projects 分頁的 Export(Projects 自己的 range)。
    func exportCurrentRange() { exportRange(projectsRange) }

    /// Models 分頁的 Export(Usage-M3 B:Models **自己的** range,與 Projects 的選擇無關)。
    func exportModelsRange() { exportRange(modelsRange) }

    private func exportRange(_ selection: RangeSelection) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let range = selection.interval()
        let name = "AIPetUsage-Report-\(df.string(from: range.start))-to-\(df.string(from: range.end)).html"
        exportReport(kind: .range(range, title: "Usage Report — \(selection.preset.displayName)"), suggestedName: name)
    }
    func exportTrends() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(max(1, trendsRangeDays) - 1), to: today) ?? today
        let range = DateInterval(start: start, end: Date())
        let name = "AIPetUsage-Trends-\(trendsRangeDays)d-\(df.string(from: Date())).html"
        exportReport(kind: .range(range, title: "Usage Trends — last \(trendsRangeDays) days"), suggestedName: name)
    }

    // MARK: - 選單列

    /// 外觀切換計數(唯一的 refresh authority):系統深/淺色通知與手動 Appearance 偏好變更都 +1,
    /// label 讀取它以觸發重烤。
    private(set) var appearanceTick = 0

    /// macOS **全域**外觀讀取器(badge exception):選單列徽章跟隨系統外觀,不隨 app 偏好。
    /// production = CFPreferences 全域域;不是 NSApp.effectiveAppearance(會被偏好覆寫)。
    private let systemAppearance = SystemAppearanceProvider.live

    /// 目前系統選單列是否深色 —— 每次讀取即時解析,label 在 appearanceTick 變動時重讀。
    var systemIsDark: Bool { systemAppearance.systemIsDark }

    /// 選單列徽章(UIUX spec P0):物種 emoji 開頭、依顯示名稱字母序、
    /// 略過無資料 provider、identity dot 恆定、severity 只上在百分比。
    var menuBarBadges: [MenuBadge] {
        guard settings.menuBarDisplayMode != .petOnly else { return [] }
        let states = dashboard.limitStates.map { st in
            (id: st.providerId,
             displayName: dashboard.snapshots.first { $0.providerId == st.providerId }?.displayName,
             fiveHour: st.fiveHour.usedPercent,
             weekly: st.weekly.usedPercent,
             idle: st.fiveHour.idle)
        }
        return MenuBadgeBuilder.badges(from: states,
                                       warn: settings.core.warnThresholdPercent,
                                       danger: settings.core.dangerThresholdPercent,
                                       onlyWarnings: settings.menuBarDisplayMode == .compact)
    }

    /// 選單列開頭標記:full 模式用所選物種,monitor-only 用 🐾。
    /// pack id 先查 displayInfo(bird 無 enum case,resolvedSpecies 會錯落到 dog)。
    var menuBarPetEmoji: String {
        guard settings.appMode == .full else { return "🐾" }
        return SpeciesPacks.displayInfo(packId: settings.speciesPackId)?.emoji
            ?? settings.resolvedSpecies.emoji
    }

    /// 物種顯示名(面板 header / Today Pet tile);同上,pack 表優先。
    var speciesDisplayName: String {
        SpeciesPacks.displayInfo(packId: settings.speciesPackId)?.name
            ?? settings.resolvedSpecies.displayName
    }

    // MARK: - EngineV2 渲染快照(C-P2c:driver 每 commit 發佈,PetView 原樣消費)

    /// V2 引擎當前幀的 ready-to-render 快照;flag 關恆為 nil(PetView 走 legacy)。
    var v2Frame: V2RenderFrame?

    /// Full 模式且完全無資料時顯示「—」佔位;Compact/PetOnly 留空是語意本身。
    var menuBarShowsPlaceholder: Bool {
        settings.menuBarDisplayMode == .full && menuBarBadges.isEmpty
    }

    /// 輔助功能全句(spec §11):全名 + severity,不得只給短代號。
    var menuBarAccessibilityLabel: String {
        let base = MenuBadgeBuilder.accessibilitySummary(
            petName: settings.appMode == .full ? settings.resolvedSpecies.displayName : "AI Pet Usage",
            badges: menuBarBadges)
        // 心情原因只在全模式附上(monitor-only 不建立寵物、mood 不更新)。
        guard settings.appMode == .full else { return base }
        return "\(base) Pet mood: \(mood.mood.rawValue) — \(mood.reason)"
    }

    /// 純文字後備(NSImage 烤製失敗時);不再夾帶心情/警示 emoji(spec P0)。
    var menuBarTitle: String {
        let parts = menuBarBadges.map { badge -> String in
            if badge.idle { return "\(badge.code) idle" }
            let a = badge.fiveHour.map { "\($0.percent)%" } ?? "-"
            let b = badge.weekly.map { "\($0.percent)%" } ?? "-"
            return "\(badge.code)\(a)/\(b)"
        }
        let usage = parts.isEmpty ? (menuBarShowsPlaceholder ? "—" : "") : parts.joined(separator: " ")
        return usage.isEmpty ? menuBarPetEmoji : "\(menuBarPetEmoji) \(usage)"
    }

    /// 依顯示名稱字母序的穩定排序(選單列、面板、儀表板一致;spec §5)。
    var orderedLimitStates: [ProviderLimitState] {
        dashboard.limitStates.sorted {
            ProviderBrands.brand(for: $0.providerId).displayName.lowercased() <
            ProviderBrands.brand(for: $1.providerId).displayName.lowercased()
        }
    }

    var orderedSnapshots: [UsageSnapshot] {
        dashboard.snapshots.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    /// 面板 header 的警示摘要(spec §8):取最嚴重的一條,一句話、不加 emoji。
    var alertSummary: (text: String, isDanger: Bool)? {
        var worst: (name: String, window: String, percent: Double, reset: Date?)?
        for st in orderedLimitStates {
            for (label, w) in [("5h", st.fiveHour), ("weekly", st.weekly)] {
                guard let p = w.usedPercent, p >= settings.core.warnThresholdPercent else { continue }
                if worst == nil || p > worst!.percent {
                    worst = (providerName(st.providerId), label, p, w.resetAt)
                }
            }
        }
        guard let w = worst else { return nil }
        let verb = w.percent >= 100 ? "exceeded" : "nearing"
        var text = "\(w.name) \(verb) \(w.window) limit"
        if let reset = w.reset { text += " · resets in \(countdown(to: reset))" }
        return (text, w.percent >= settings.core.dangerThresholdPercent)
    }

    // MARK: - 螢幕漫遊(pixel pet)

    /// -1 左行 / 0 靜止 / 1 右行;由 PetPanelController 的漫遊迴圈驅動,PetView 據此切換走路動畫。
    private(set) var wanderDirection: Int = 0

    /// 朝向(與移動解耦;R3):停下(direction=0,含點擊觸發的拖曳暫停)時保留
    /// 最後行進方向 —— 向左走時被點擊,寵物面朝左彈泡泡,不再瞬間轉回預設右向。
    private(set) var petFacingDirection: Int = 1

    func setWanderDirection(_ direction: Int) {
        if wanderDirection != direction { wanderDirection = direction }
        if direction != 0, petFacingDirection != direction { petFacingDirection = direction }
    }
}
