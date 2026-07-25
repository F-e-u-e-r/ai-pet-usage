import Foundation

// MARK: - UI / 報告所需的彙整狀態(不可變值型別,跨 actor 傳遞)

public struct ProviderDaySummary: Codable, Sendable, Identifiable {
    public var providerId: String
    public var displayName: String
    public var tokens: TokenBreakdown
    public var cost: CostResult

    public var id: String { providerId }

    public init(providerId: String, displayName: String, tokens: TokenBreakdown, cost: CostResult) {
        self.providerId = providerId
        self.displayName = displayName
        self.tokens = tokens
        self.cost = cost
    }
}

public struct DashboardState: Sendable {
    public var generatedAt: Date
    public var snapshots: [UsageSnapshot]
    public var limitStates: [ProviderLimitState]
    public var todayTotals: TokenBreakdown
    public var todayCost: CostResult
    public var todayByProvider: [ProviderDaySummary]
    public var burnRateTokensPerHour: Double
    public var burnCostPerHour: Double
    public var hourly: [HourBucket]
    public var topProjects: [ProjectSummary]
    public var models: [ModelUsageSummary]
    public var dataQuality: [String]
    public var lastRefreshAt: Date?

    public static let empty = DashboardState(
        generatedAt: .distantPast, snapshots: [], limitStates: [], todayTotals: .zero,
        todayCost: .zero, todayByProvider: [], burnRateTokensPerHour: 0, burnCostPerHour: 0,
        hourly: [], topProjects: [], models: [], dataQuality: [], lastRefreshAt: nil
    )

    public init(generatedAt: Date, snapshots: [UsageSnapshot], limitStates: [ProviderLimitState],
                todayTotals: TokenBreakdown, todayCost: CostResult, todayByProvider: [ProviderDaySummary],
                burnRateTokensPerHour: Double, burnCostPerHour: Double, hourly: [HourBucket],
                topProjects: [ProjectSummary], models: [ModelUsageSummary],
                dataQuality: [String], lastRefreshAt: Date?) {
        self.generatedAt = generatedAt
        self.snapshots = snapshots
        self.limitStates = limitStates
        self.todayTotals = todayTotals
        self.todayCost = todayCost
        self.todayByProvider = todayByProvider
        self.burnRateTokensPerHour = burnRateTokensPerHour
        self.burnCostPerHour = burnCostPerHour
        self.hourly = hourly
        self.topProjects = topProjects
        self.models = models
        self.dataQuality = dataQuality
        self.lastRefreshAt = lastRefreshAt
    }
}

public struct RefreshOutcome: Sendable {
    public var transitions: [LimitTransition]
    public var dashboard: DashboardState
    public var insertedEvents: Int
    /// 另一個行程(app ↔ CLI)正持有資料鎖,本次刷新未執行寫入。
    public var skipped: Bool

    public init(transitions: [LimitTransition], dashboard: DashboardState, insertedEvents: Int, skipped: Bool = false) {
        self.transitions = transitions
        self.dashboard = dashboard
        self.insertedEvents = insertedEvents
        self.skipped = skipped
    }
}

public enum ReportKind: Sendable {
    case today
    case range(DateInterval, title: String)
}

public struct ProjectPageData: Sendable {
    public var range: DateInterval
    public var projects: [ProjectSummary]
    public var models: [ModelUsageSummary]
    public var totals: TokenBreakdown
    public var cost: CostResult
}

/// Trends 分頁 / 熱圖所需的聚合(純本機、跨 actor 傳遞的不可變值)。
public struct TrendsData: Sendable {
    public var rangeDays: Int
    public var startDay: Date          // 範圍第一天(本地日午夜)
    public var endDay: Date            // 今天(本地日午夜)
    public var daily: [DayBucket]      // 範圍內有用量的日,依日升序
    public var streak: UsageStreak
    public var thisWeekTokens: Int     // 最近 7 天
    public var lastWeekTokens: Int     // 前一個 7 天

    public init(rangeDays: Int, startDay: Date, endDay: Date, daily: [DayBucket],
                streak: UsageStreak, thisWeekTokens: Int, lastWeekTokens: Int) {
        self.rangeDays = rangeDays
        self.startDay = startDay
        self.endDay = endDay
        self.daily = daily
        self.streak = streak
        self.thisWeekTokens = thisWeekTokens
        self.lastWeekTokens = lastWeekTokens
    }
}

/// FSEvents 檔案監看計畫:要監看的目錄 + 只在變更路徑命中白名單時才觸發 refresh。
public struct WatchPlan: Sendable, Equatable {
    public var dirs: [String]       // FSEvents 監看的目錄
    public var triggers: [String]   // 變更路徑「等於或位於其下」命中才觸發 refresh
    /// 是否有任何已啟用的 provider(其「存在的」根目錄皆已納入監看)。false 僅剩「沒有任何
    /// 啟用中的 provider」一種情況,維持快速輪詢;未安裝(根目錄不存在)的啟用 provider
    /// 沒有可監看目標,不會擋下慢速 fallback——fallback 每輪重取 watchPlan,
    /// 新出現的目錄 ≤300s 內即被接手監看。
    public var allEnabledRootsWatched: Bool
    public init(dirs: [String], triggers: [String], allEnabledRootsWatched: Bool) {
        self.dirs = dirs
        self.triggers = triggers
        self.allEnabledRootsWatched = allEnabledRootsWatched
    }
}

// MARK: - 協調器

/// 串起 adapters → 帳本 → 限額引擎,對 UI/CLI 提供單一入口。
/// 每個 adapter 獨立失敗(規格要求),不會拖垮其他 provider 或寵物。
public actor UsageCoordinator {
    public let dataDir: URL
    private var settings: CoreSettings
    private let adapters: [ProviderAdapter]
    private let ledger: UsageLedger
    private let limits: LimitEngine
    private var scanStates: [String: ScanState]
    private var pricing: PricingRegistry
    private var lastRefreshAt: Date?
    private var refreshErrors: [String: String] = [:]
    private var parseErrorCounts: [String: Int] = [:]
    private var fullReindexPreservedProviderIds: Set<String> = []
    /// 非 nil 表示 scan-state 檔存在但讀不到 / 損壞;與 ledger/limits 的 loadError 一起閘住本輪寫入(#44 契約 A)。
    private var scanStateLoadError: Error?
    /// 本輪 reindex 的「誠實通知」(切片保留/累計未重建等,非 error):流入 dashboard dataQuality,兩個 sink 皆辨識。
    private var refreshQualityNotes: [String] = []
    /// 跨行程互斥:app 與 CLI 對同一資料目錄的寫入階段必須互斥。
    private let refreshLock: FileLock
    private let refreshLockTimeout: TimeInterval
    private var refreshInFlight = false

    private var scanStateURL: URL { dataDir.appendingPathComponent("scan-state.json") }
    /// 持久化 scan-state(checked;供 reindex 前置「安全排序」用——失敗即 throw,呼叫端據此不 replace)。
    private func persistScanState() throws {
        try AtomicJSON.write(scanStates, to: scanStateURL)
    }
    private var pricingOverridesURL: URL { dataDir.appendingPathComponent("pricing-overrides.json") }

    /// `readOnly`:純唯讀入口(如 `aipet diag`)不得建立資料目錄——略過 `ensureDirectory`,
    /// 使得對不存在的資料目錄執行時「零檔案系統副作用」(目錄仍不存在)。其餘讀取路徑
    /// (ledger/limits/scan-state/pricing)本就容忍缺檔並回傳空值。
    public init(dataDir: URL? = nil, settings: CoreSettings = CoreSettings(),
                adapters: [ProviderAdapter]? = nil, refreshLockTimeout: TimeInterval = 60,
                readOnly: Bool = false) {
        let dir = dataDir ?? AppPaths.dataDirectory()
        self.dataDir = dir
        self.settings = settings
        // opencode 預設**停用**(enabledProviders 預設集不含它;R1 雙審裁決:db 與 OAuth
        // 憑證同檔,保守側勝出)——註冊於此使 Settings → Providers 顯示啟用開關。
        self.adapters = adapters ?? [CodexAdapter(), ClaudeCodeAdapter(), GrokCodeAdapter(), OpenCodeAdapter()]
        self.refreshLockTimeout = refreshLockTimeout
        if !readOnly { try? AppPaths.ensureDirectory(dir) }
        self.refreshLock = FileLock(url: dir.appendingPathComponent("refresh.lock"))
        self.ledger = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
        self.limits = LimitEngine(stateURL: dir.appendingPathComponent("limits-state.json"))
        do {
            self.scanStates = try AtomicJSON.readOrThrow([String: ScanState].self, from: dir.appendingPathComponent("scan-state.json")) ?? [:]
        } catch {
            self.scanStates = [:]
            self.scanStateLoadError = error   // 存在但讀不到/損壞:刷新時據此中止寫入,不覆寫
        }
        self.pricing = PricingRegistry.loadDefault(overridesURL: dir.appendingPathComponent("pricing-overrides.json"))
        // 注意:init 必須是純讀取——壓縮(會重寫帳本檔)只能在 refresh() 持鎖後執行,
        // 否則唯讀的 CLI 指令也會寫檔,破壞跨行程安全。
    }

    public func updateSettings(_ new: CoreSettings) {
        settings = new
    }

    public func currentSettings() -> CoreSettings { settings }

    public func adapterInfos() -> [(providerId: String, displayName: String, availability: ProviderAvailability, dataSources: String, permissions: String)] {
        adapters.map { ($0.providerId, $0.displayName, $0.detectAvailability(), $0.explainDataSources(), $0.explainRequiredPermissions()) }
    }

    /// 診斷用:對每個 adapter 的候選來源做 stat,回報固定 id + 狀態 + mtime 分桶。
    /// **只 stat 根本身,不走訪子項**——故任何子路徑/專案名都不會外洩。fail-closed:
    /// 無法判定存在(EACCES/其他 errno)絕不當成 present。symlink 的根會回報其目標狀態
    /// (使用者刻意把資料目錄 symlink 出去是合法的;此處僅讀取狀態,不寫入)。唯讀。
    public func diagnosticSourceStates(now: Date = Date()) -> [DiagnosticSourceState] {
        let fm = FileManager.default
        var out: [DiagnosticSourceState] = []
        for adapter in adapters {
            for src in adapter.diagnosticSources() {
                let path = src.url.path
                var st = stat()
                let state: SourceState
                var age: AgeBucket? = nil
                if stat(path, &st) == 0 {
                    state = fm.isReadableFile(atPath: path) ? .present : .unreadable
                    let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                    age = AgeBucket(seconds: now.timeIntervalSince(mtime))
                } else {
                    switch errno {
                    case ENOENT, ENOTDIR: state = .missing
                    case EACCES: state = .unreadable
                    default: state = .unknown          // fail-closed:判定不了 → 絕不宣稱 present
                    }
                }
                out.append(DiagnosticSourceState(id: src.id, state: state, modifiedAge: age))
            }
        }
        return out
    }

    /// FSEvents 監看計畫。監看目錄 = 存在的 provider 記錄目錄 + statusline 檔的存在父目錄;
    /// 觸發白名單 = provider 目錄(整棵樹)+ statusline 檔路徑(精確)。App Support 內我方
    /// 寫入的帳本/設定雖與 statusline 同目錄而被「監看」,但不在白名單,故不會自我觸發 refresh。
    /// 每次呼叫重新取得,fallback 迴圈藉此撿到啟動後才建立的目錄/檔。
    public func watchPlan() -> WatchPlan {
        let fm = FileManager.default
        var providerDirs: Set<String> = []
        var watchDirs: Set<String> = []
        var triggerFiles: Set<String> = []
        var anyEnabled = false
        // 只監看已啟用的 provider(refresh() 亦以 enabledProviders 跳過停用者;停用即停止監看其目錄)。
        // 註:「已啟用但根目錄不存在」(未安裝該 CLI)的 provider 沒有可監看的目標,不再擋下
        // 300s fallback——否則預設啟用而未安裝的 provider(如 grok-code)會讓使用者永遠停留
        // 在快速輪詢。fallback 迴圈每輪重取 watchPlan,新出現的目錄 ≤300s 內即被接手監看。
        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            anyEnabled = true
            for root in adapter.roots {
                providerDirs.insert(root.path)
                watchDirs.insert(root.path)
            }
            for file in adapter.watchFiles {
                triggerFiles.insert(file.path)
                let parent = file.deletingLastPathComponent()
                if fm.fileExists(atPath: parent.path) { watchDirs.insert(parent.path) }
            }
        }
        return WatchPlan(dirs: watchDirs.sorted(),
                         triggers: providerDirs.union(triggerFiles).sorted(),
                         allEnabledRootsWatched: anyEnabled)
    }

    // MARK: 刷新

    public func refresh(fullReindex: Bool = false) async -> RefreshOutcome {
        let now = Date()
        if refreshInFlight {
            var dash = dashboard(now: now)
            dash.dataQuality.append("refresh skipped — a refresh is already in progress")
            return RefreshOutcome(transitions: [], dashboard: dash, insertedEvents: 0, skipped: true)
        }
        refreshInFlight = true
        defer { refreshInFlight = false }

        // 寫入階段需要跨行程互斥(首次索引可達十餘秒,逾時給足裕度)。
        guard await refreshLock.acquireAsync(timeout: refreshLockTimeout) else {
            var dash = dashboard(now: now)
            dash.dataQuality.append("refresh skipped — another AI Pet Usage process (app or CLI) holds the data lock")
            return RefreshOutcome(transitions: [], dashboard: dash, insertedEvents: 0, skipped: true)
        }
        defer { refreshLock.release() }
        refreshQualityNotes = []
        ledger.clearWriteError()   // R2-NIT:清除上一輪殘留的落盤失敗旗標,避免誤觸本輪的 break

        // 其他行程可能已推進帳本/掃描進度/限額狀態:先收斂再增量掃描,
        // 內容穩定的事件 ID + 去重保證不重複計費。
        // #44 契約 A:重載三個權威狀態檔;任一「存在但讀不到/損壞」(非「不存在」)→
        // 中止本輪寫入,絕不以空/舊資料覆寫使用者仍可救回的檔案。
        ledger.reloadIfChanged()
        limits.reloadFromDisk()
        var diskStates: [String: ScanState]? = nil
        do {
            diskStates = try AtomicJSON.readOrThrow([String: ScanState].self, from: scanStateURL)
            scanStateLoadError = nil
        } catch {
            scanStateLoadError = error
        }
        if ledger.loadError != nil || limits.loadError != nil || scanStateLoadError != nil {
            // 通知由 dashboard() 從 loadError 中央推導(C-MF8),此處不再手動 append。
            return RefreshOutcome(transitions: [], dashboard: dashboard(now: now), insertedEvents: 0, skipped: true)
        }
        // #44 契約 C:持鎖後磁碟為唯一真相——**rebuildable** provider 整份採用磁碟狀態(取代陳舊記憶體、防止復活;
        // 重讀去重安全)。**cumulativeSnapshotOnly** provider(如 OpenCode)則整段保留記憶體 scan-state、不參與此磁碟
        // 採用——磁碟缺標記或含異 db-path 標記皆不會把 baseline 清成空而 zero-baseline overcount(回到本 PR 前的安全
        // 基線;這是最小 pre-PR 回復,非新 heuristic)。cumulative 的 durable-state/recovery——mark identity、generation、
        // 合法刪除/tombstone、跨行程收斂,含 codex「disk 非空但缺 live mark」案例——為 blocking follow-up(見追蹤)。
        let cumulativeInMemory = adapters
            .filter { $0.historyModel == .cumulativeSnapshotOnly }
            .reduce(into: [String: ScanState]()) { acc, adapter in
                if let s = scanStates[adapter.providerId] { acc[adapter.providerId] = s }
            }
        scanStates = diskStates ?? [:]
        for (pid, s) in cumulativeInMemory { scanStates[pid] = s }   // cumulative 整段保留記憶體(忽略磁碟採用)
        ledger.compact(retentionDays: settings.retentionDays, now: now) // 僅在持鎖時壓縮

        if fullReindex {
            let enabled = Set(adapters.filter { settings.enabledProviders.contains($0.providerId) }.map { $0.providerId })
            let rescan = Set(adapters.filter {
                settings.enabledProviders.contains($0.providerId) && $0.detectAvailability().available
            }.map { $0.providerId })
            // 契約 F:不再「先清空再 append」(會變無操作/刪歷史);改為迴圈中「從零重掃 → 完整才切片取代」。
            fullReindexPreservedProviderIds = enabled.subtracting(rescan)   // 不可用者個別保留歷史
        }
        var transitions: [LimitTransition] = []
        var inserted = 0

        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            guard adapter.detectAvailability().available else { continue }
            let pid = adapter.providerId
            do {
                if fullReindex && adapter.historyModel == .rebuildableHistory {
                    // 契約 F:從零重掃 → 只有「完整」掃描才切片取代(set-replace);不完整則保留舊切片、
                    // 舊 scanState、不刪歷史(契約 E / codex C8)。
                    // 注意:僅 rebuildableHistory 走此路;cumulativeSnapshotOnly(OpenCode)落到 else 走增量、
                    // 保留既有切片,絕不把累計總量塌成「現在的一筆」(codex MF2)。
                    let (result, newState) = try adapter.refreshUsage(state: ScanState())
                    switch result.completeness {
                    case .complete:
                        // C-MF2 安全排序:先把此 provider 的 watermark 持久化為空,再 replace,最後才提交 newState。
                        // 崩潰/寫失敗於任一步 → 磁碟留「空 watermark」→ 下輪安全重掃(id 去重),絕不 skip-and-miss。
                        scanStates[pid] = ScanState()
                        try persistScanState()   // checked;失敗即 throw → catch → 保留舊切片(不 replace)
                        // C-MF6:重掃切片套用與 compact 同一保留期 cutoff,不重新引入超過保留期的過期事件。
                        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86400)
                        let freshKept = result.events.filter { $0.timestamp >= cutoff }
                        inserted += try ledger.replaceProviderSlice(pid, with: freshKept)   // 交易式 set-replace,回傳採納數
                        scanStates[pid] = newState
                        transitions += limits.ingest(readings: result.rateLimits, settings: settings, fullReindex: true, now: now)
                        parseErrorCounts[pid] = result.parseErrors
                        refreshErrors[pid] = nil
                    case .incomplete:
                        fullReindexPreservedProviderIds.insert(pid)   // 保留舊切片,不刪歷史
                        refreshQualityNotes.append("\(pid): reindex incomplete — history preserved")   // 誠實通知(非 error)
                    }
                } else {
                    let state = scanStates[pid] ?? ScanState()
                    let (result, newState) = try adapter.refreshUsage(state: state)
                    inserted += ledger.append(result.events)         // 交易式落盤(記憶體僅落盤成功才提交)
                    if let we = ledger.writeError { throw we }        // 落盤失敗 → 不提交下面(契約 B/M5)
                    scanStates[pid] = newState                        // 落盤成功才推進 watermark
                    transitions += limits.ingest(readings: result.rateLimits, settings: settings, fullReindex: false, now: now)
                    parseErrorCounts[pid] = result.parseErrors
                    refreshErrors[pid] = nil
                    if fullReindex {
                        // 走到 else 且 fullReindex → 必為 cumulativeSnapshotOnly(OpenCode):保留累計歷史、僅增量(不重建)。
                        refreshQualityNotes.append("\(pid): reindex kept cumulative history — not rebuildable")
                    }
                }
            } catch {
                refreshErrors[pid] = String(describing: error)
                // C-MF4:帳本落盤失敗 → 停止後續 provider 的 append,避免下一個成功寫入把指紋更新到「含半寫位元組」
                // 的磁碟、遮蔽未採用的批次(load/append 已設 expectedFingerprint=nil 強制下輪對帳)。
                if ledger.writeError != nil { break }
            }
        }

        transitions += limits.sweepExpiredWindows(now: now)

        // Claude 估算區塊的重置偵測
        if settings.enabledProviders.contains("claude-code") {
            let recent = ledger.events(in: .trailing(days: 8, now: now), providerId: "claude-code")
            let block = LimitEngine.fiveHourBlock(events: recent, now: now)
            transitions += limits.noteEstimatedBlock(providerId: "claude-code",
                                                     blockEnd: block?.end,
                                                     blockTokens: block?.tokens ?? 0,
                                                     lastEventAt: ledger.newestEvent(providerId: "claude-code")?.timestamp,
                                                     now: now)
        }
        // 官方與估算同窗撞 reset → 留官方(估算不得蓋掉官方歸因)。
        transitions = LimitEngine.preferOfficialResets(transitions)

        do {
            try AtomicJSON.write(scanStates, to: scanStateURL)   // C-MF8:寫失敗不再靜默
        } catch {
            refreshQualityNotes.append("scan-state write failed — will re-scan next refresh")
        }
        lastRefreshAt = now
        return RefreshOutcome(transitions: transitions, dashboard: dashboard(now: now), insertedEvents: inserted)
    }

    // MARK: Dashboard 組裝

    public func dashboard(now: Date = Date()) -> DashboardState {
        let today = DateInterval.today(now: now)
        let todayEvents = ledger.events(in: today)
        let todayTotals = todayEvents.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
        let todayCost = pricing.cost(of: todayEvents)

        var limitStates: [ProviderLimitState] = []
        var snapshots: [UsageSnapshot] = []
        var byProvider: [ProviderDaySummary] = []

        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            let pid = adapter.providerId
            let availability = adapter.detectAvailability()
            let limit = limits.limitState(providerId: pid, ledger: ledger, settings: settings, now: now)
            limitStates.append(limit)

            let providerEvents = todayEvents.filter { $0.providerId == pid }
            let tokens = providerEvents.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
            byProvider.append(ProviderDaySummary(providerId: pid, displayName: adapter.displayName,
                                                 tokens: tokens, cost: pricing.cost(of: providerEvents)))

            let status: ProviderStatus
            if !availability.available {
                status = .unavailable
            } else if let _ = refreshErrors[pid] {
                status = .error
            } else if ledger.newestEvent(providerId: pid) == nil {
                status = .noData
            } else {
                switch limit.warning {
                case .exhausted: status = .exhausted
                case .warning: status = .warning
                case .stale: status = .stale
                case .noData: status = .noData
                case .ok: status = .healthy
                }
            }

            snapshots.append(UsageSnapshot(
                providerId: pid,
                displayName: adapter.displayName,
                status: status,
                sessionUsagePercent: limit.fiveHour.usedPercent,
                weeklyUsagePercent: limit.weekly.usedPercent,
                resetAt: limit.fiveHour.resetAt,
                updatedAt: limit.lastReadingAt ?? limit.lastEventAt,
                tokenInput: tokens.input,
                tokenOutput: tokens.output,
                tokenCache: tokens.cacheRead + tokens.cacheWrite,
                estimatedCost: pricing.cost(of: providerEvents).knownUSD,
                sourceDescription: availability.detail,
                errorMessage: refreshErrors[pid]
            ))
        }

        let hourEvents = ledger.events(in: DateInterval(start: now.addingTimeInterval(-3600), end: now))
        let burnCost = hourEvents.isEmpty ? 0 : pricing.cost(of: hourEvents).knownUSD

        var quality: [String] = []
        // C-MF8:狀態檔 poison 由 loadError 中央推導 → report/diag/status 重算 dashboard 時也看得到
        //(不只 refresh 當下的暫時 dash);兩個 sink 皆辨識為誠實、無路徑的固定模板。
        if ledger.loadError != nil || limits.loadError != nil || scanStateLoadError != nil {
            quality.append("state read failed — refresh skipped; data preserved")
        }
        for (pid, err) in refreshErrors {
            quality.append("\(pid): refresh error — \(err)")
        }
        for (pid, count) in parseErrorCounts where count > 0 {
            quality.append("\(pid): \(count) unparsable line(s) skipped on last scan")
        }
        for pid in fullReindexPreservedProviderIds.sorted()
        where settings.enabledProviders.contains(pid)
            && adapters.first(where: { $0.providerId == pid })?.detectAvailability().available == false {
            quality.append("\(pid): history kept — provider unavailable during full reindex")
        }
        for limit in limitStates {
            // corrected 已在組裝層以 correctedAt 閘 24h(一次性事件,非永久狀態);
            // 這裡只負責把「哪個窗、為什麼、何時」講清楚。
            for (windowName, w) in [("5h", limit.fiveHour), ("weekly", limit.weekly)] where w.corrected {
                let cause = w.correctedReason == .reindex
                    ? "full reindex" : "official reading (plan change or backend recompute)"
                let at = w.correctedAt.map { " at \(LocalTime.format($0))" } ?? ""
                quality.append("\(limit.providerId): \(windowName) usage percent corrected downward — \(cause)\(at)")
            }
            if limit.fiveHour.confidence == .stale {
                quality.append("\(limit.providerId): rate-limit reading is older than 6h; percent may lag")
            }
        }
        if let claude = limitStates.first(where: { $0.providerId == "claude-code" }),
           claude.fiveHour.usedPercent == nil, !claude.fiveHour.idle {
            // idle(閒置)不是資料問題,不列入 data-quality 警告(cross-model round-2)。
            quality.append("claude-code: percent unavailable — run `aipet install-hook` for official limits (or see the README), or set a token budget in Settings for an estimate")
        }
        quality.append(contentsOf: refreshQualityNotes)   // reindex 誠實通知(#44 step 8:兩個 sink 皆辨識)

        return DashboardState(
            generatedAt: now,
            snapshots: snapshots,
            limitStates: limitStates,
            todayTotals: todayTotals,
            todayCost: todayCost,
            todayByProvider: byProvider,
            burnRateTokensPerHour: ledger.burnRatePerHour(window: 3600, now: now),
            burnCostPerHour: burnCost,
            hourly: ledger.hourlyBuckets(in: today),
            topProjects: Array(ledger.projectSummaries(in: today, pricing: pricing).prefix(8)),
            models: ledger.modelSummaries(in: today, pricing: pricing),
            dataQuality: quality,
            lastRefreshAt: lastRefreshAt
        )
    }

    public func projectPage(range: DateInterval) -> ProjectPageData {
        let events = ledger.events(in: range)
        return ProjectPageData(
            range: range,
            projects: ledger.projectSummaries(in: range, pricing: pricing),
            models: ledger.modelSummaries(in: range, pricing: pricing),
            totals: events.reduce(.zero) { $0 + $1.tokens },
            cost: pricing.cost(of: events)
        )
    }

    /// Trends 分頁資料:近 `days` 天的日聚合 + 使用連續天數 + 週對比。純本機、零新依賴。
    public func trendsData(days: Int, now: Date = Date()) -> TrendsData {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        let daily = ledger.dailyBuckets(in: DateInterval(start: start, end: now), pricing: pricing)
        let streak = ledger.usageStreak(now: now)
        let thisWeekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let lastWeekStart = cal.date(byAdding: .day, value: -13, to: today) ?? today
        let thisWeek = ledger.totals(in: DateInterval(start: thisWeekStart, end: now)).total
        let lastWeek = ledger.totals(in: DateInterval(start: lastWeekStart, end: thisWeekStart)).total
        return TrendsData(rangeDays: days, startDay: start, endDay: today, daily: daily,
                          streak: streak, thisWeekTokens: thisWeek, lastWeekTokens: lastWeek)
    }

    // MARK: 報告

    public func reportData(kind: ReportKind, now: Date = Date(), petSummary: String? = nil) -> ReportData {
        let period: DateInterval
        let title: String
        switch kind {
        case .today:
            period = .today(now: now)
            title = "Daily Usage Report"
        case let .range(r, t):
            period = r
            title = t
        }
        let events = ledger.events(in: period)
        let dash = dashboard(now: now)

        var providerRows: [ProviderDaySummary] = []
        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            let evs = events.filter { $0.providerId == adapter.providerId }
            providerRows.append(ProviderDaySummary(providerId: adapter.providerId, displayName: adapter.displayName,
                                                   tokens: evs.reduce(.zero) { $0 + $1.tokens },
                                                   cost: pricing.cost(of: evs)))
        }

        // 期間 ≤ 48 小時用小時刻度,否則用日刻度。
        var buckets: [(String, Int)] = []
        let cal = Calendar.current
        if period.duration <= 48 * 3600 {
            let df = DateFormatter(); df.dateFormat = "MM-dd HH:00"
            buckets = ledger.hourlyBuckets(in: period, calendar: cal).map { (df.string(from: $0.start), $0.tokens) }
        } else {
            var dayTotals: [Date: Int] = [:]
            for e in events {
                dayTotals[cal.startOfDay(for: e.timestamp), default: 0] += e.tokens.total
            }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            buckets = dayTotals.keys.sorted().map { (df.string(from: $0), dayTotals[$0]!) }
        }

        let models = ledger.modelSummaries(in: period, pricing: pricing)
        var pricingRows: [ModelPrice] = []
        var unknown: [(String, Int)] = []
        for m in models {
            if let p = pricing.price(providerId: m.providerId, modelId: m.modelId) {
                if !pricingRows.contains(p) { pricingRows.append(p) }
            } else if m.cost.unknownModelTokens > 0 {
                // provider 自行回報成本的模型(如 opencode/kimi:unknownModelTokens == 0、
                // providerReportedUSD > 0)不是「未定價」——不得列入 unknown 誤導讀者。
                unknown.append((m.providerId + "/" + m.modelId, m.tokens.total))
            }
        }

        return ReportData(
            title: title,
            period: period,
            generatedAt: now,
            timezoneName: TimeZone.current.identifier,
            totals: events.reduce(.zero) { $0 + $1.tokens },
            cost: pricing.cost(of: events),
            byProvider: providerRows,
            limitStates: dash.limitStates,
            projects: ledger.projectSummaries(in: period, pricing: pricing),
            models: models,
            buckets: buckets,
            pricingRows: pricingRows,
            unknownModels: unknown,
            dataQuality: dash.dataQuality,
            petSummary: petSummary,
            streak: ledger.usageStreak(now: now),
            dailyHeat: ledger.dailyBuckets(in: period)
        )
    }

    public func exportReport(kind: ReportKind, to url: URL, petSummary: String? = nil) throws {
        let data = reportData(kind: kind, petSummary: petSummary)
        let html = ReportGenerator.generateHTML(data)
        try html.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// 今日有 AI 活動的分鐘數(以 5 分鐘桶粗估),供互動引擎計算點心券。
    public func activeMinutesToday(now: Date = Date()) -> Double {
        let events = ledger.events(in: .today(now: now))
        var buckets = Set<Int>()
        for e in events {
            buckets.insert(Int(e.timestamp.timeIntervalSince1970 / 300))
        }
        return Double(buckets.count) * 5
    }

    // MARK: 計價

    public func pricingEntries() -> [ModelPrice] { pricing.entries }

    public func modelsSeenWithPricing(days: Int = 30, now: Date = Date()) -> [(model: ModelUsageSummary, price: ModelPrice?)] {
        ledger.modelSummaries(in: .trailing(days: days, now: now), pricing: pricing).map {
            ($0, pricing.price(providerId: $0.providerId, modelId: $0.modelId))
        }
    }

    public func addPricingOverride(_ price: ModelPrice) {
        var overrides = AtomicJSON.read([ModelPrice].self, from: pricingOverridesURL) ?? []
        overrides.removeAll { $0.providerId == price.providerId && $0.modelId == price.modelId }
        var p = price
        p.userOverride = true
        overrides.append(p)
        try? AtomicJSON.write(overrides, to: pricingOverridesURL)
        pricing = PricingRegistry.loadDefault(overridesURL: pricingOverridesURL)
    }
}
