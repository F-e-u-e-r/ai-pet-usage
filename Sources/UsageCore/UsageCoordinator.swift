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
    /// 是否「所有已啟用的 provider」都已監看到記錄目錄。false 時(全新安裝尚無目錄、只監看到
    /// statusline 父目錄,或某個啟用的 provider 目錄還沒出現)維持快速輪詢以儘快發現新目錄;
    /// 全部鎖定後才切到慢速 fallback,避免第二個 provider 的新目錄要等 fallback 才被發現。
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
    /// 跨行程互斥:app 與 CLI 對同一資料目錄的寫入階段必須互斥。
    private let refreshLock: FileLock
    private let refreshLockTimeout: TimeInterval
    private var refreshInFlight = false

    private var scanStateURL: URL { dataDir.appendingPathComponent("scan-state.json") }
    private var pricingOverridesURL: URL { dataDir.appendingPathComponent("pricing-overrides.json") }

    public init(dataDir: URL? = nil, settings: CoreSettings = CoreSettings(),
                adapters: [ProviderAdapter]? = nil, refreshLockTimeout: TimeInterval = 60) {
        let dir = dataDir ?? AppPaths.dataDirectory()
        self.dataDir = dir
        self.settings = settings
        self.adapters = adapters ?? [CodexAdapter(), ClaudeCodeAdapter()]
        self.refreshLockTimeout = refreshLockTimeout
        try? AppPaths.ensureDirectory(dir)
        self.refreshLock = FileLock(url: dir.appendingPathComponent("refresh.lock"))
        self.ledger = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
        self.limits = LimitEngine(stateURL: dir.appendingPathComponent("limits-state.json"))
        self.scanStates = AtomicJSON.read([String: ScanState].self, from: dir.appendingPathComponent("scan-state.json")) ?? [:]
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
        var allEnabledRootsWatched = true
        // 只監看已啟用的 provider(refresh() 亦以 enabledProviders 跳過停用者;停用即停止監看其目錄)。
        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            anyEnabled = true
            let roots = adapter.roots
            if roots.isEmpty { allEnabledRootsWatched = false }   // 該 provider 的記錄目錄尚未出現
            for root in roots {
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
                         allEnabledRootsWatched: anyEnabled && allEnabledRootsWatched)
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

        // 其他行程可能已推進帳本/掃描進度/限額狀態:先收斂再增量掃描,
        // 內容穩定的事件 ID + 去重保證不重複計費。
        ledger.reloadIfChanged()
        if let diskStates = AtomicJSON.read([String: ScanState].self, from: scanStateURL) {
            for (provider, diskState) in diskStates {
                var merged = scanStates[provider] ?? ScanState()
                for (file, diskMark) in diskState.files {
                    if let ours = merged.files[file], ours.offset >= diskMark.offset { continue }
                    merged.files[file] = diskMark
                }
                scanStates[provider] = merged
            }
        }
        limits.reloadFromDisk()
        ledger.compact(retentionDays: settings.retentionDays, now: now) // 僅在持鎖時壓縮

        if fullReindex {
            let enabled = Set(adapters.filter { settings.enabledProviders.contains($0.providerId) }.map { $0.providerId })
            let rescan = Set(adapters.filter {
                settings.enabledProviders.contains($0.providerId) && $0.detectAvailability().available
            }.map { $0.providerId })
            fullReindexPreservedProviderIds = enabled.subtracting(rescan)
            ledger.clearProviders(rescan)
            for pid in rescan { scanStates[pid] = ScanState() }
        }
        var transitions: [LimitTransition] = []
        var inserted = 0

        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            guard adapter.detectAvailability().available else { continue }
            do {
                let state = scanStates[adapter.providerId] ?? ScanState()
                let (result, newState) = try adapter.refreshUsage(state: state)
                scanStates[adapter.providerId] = newState
                inserted += ledger.append(result.events)
                transitions += limits.ingest(readings: result.rateLimits, settings: settings, fullReindex: fullReindex)
                parseErrorCounts[adapter.providerId] = result.parseErrors
                refreshErrors[adapter.providerId] = nil
            } catch {
                refreshErrors[adapter.providerId] = String(describing: error)
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
                                                     now: now)
        }

        try? AtomicJSON.write(scanStates, to: scanStateURL)
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
            if limit.fiveHour.corrected || limit.weekly.corrected {
                quality.append("\(limit.providerId): usage percent was corrected downward after a full reindex")
            }
            if limit.fiveHour.confidence == .stale {
                quality.append("\(limit.providerId): rate-limit reading is older than 6h; percent may lag")
            }
        }
        if let claude = limitStates.first(where: { $0.providerId == "claude-code" }),
           claude.fiveHour.usedPercent == nil {
            quality.append("claude-code: percent unavailable — install the statusline hook (Scripts/claude-statusline-hook.sh) for official limits, or set a token budget in Settings for an estimate")
        }

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
        let daily = ledger.dailyBuckets(in: DateInterval(start: start, end: now))
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
            } else {
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
