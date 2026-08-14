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

    /// 分享安全:GUI「Data quality」清單顯示用。每則過 fail-closed allowlist(`safeDataQuality`),
    /// 絕不外洩路徑/原始錯誤/絕對時間。原文 `dataQuality` 保留給 CLI `aipet status --full` 與報告 sink。
    public var shareSafeDataQuality: [String] {
        dataQuality.map(PrivacyRedaction.safeDataQuality)
    }

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

/// #48 pivot §7:per-provider data action(fullReindex 時逐 provider 如實揭示)。
/// counts 僅供固定 count-only 呈現——絕不攜帶 event ID、unknown key、path 或 payload。
public enum ProviderDataAction: Equatable, Sendable {
    case replaced
    case appendedCumulative
    case preservedHistoryMismatch(retained: Int, missing: Int, changed: Int,
                                  duplicates: Int, canonicalizationErrors: Int)
    case preservedIncomplete
    case preservedUnavailable
    case notAttempted
    case failedBeforeCommit
}

public struct RefreshOutcome: Sendable {
    public var transitions: [LimitTransition]
    public var dashboard: DashboardState
    public var insertedEvents: Int
    /// 另一個行程(app ↔ CLI)正持有資料鎖,本次刷新未執行寫入。
    public var skipped: Bool
    /// #48 §7:fullReindex 時逐 requested provider 的 data action(增量刷新為空)。
    public var providerOutcomes: [String: ProviderDataAction]

    public init(transitions: [LimitTransition], dashboard: DashboardState, insertedEvents: Int,
                skipped: Bool = false, providerOutcomes: [String: ProviderDataAction] = [:]) {
        self.transitions = transitions
        self.dashboard = dashboard
        self.insertedEvents = insertedEvents
        self.skipped = skipped
        self.providerOutcomes = providerOutcomes
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
    /// 聚合快取(2026-08-08 效能修正):鍵 = 帳本世代 + 價目世代 + 範圍。FSEvents 觸發的
    /// 高頻 refresh 會在事件集完全未變時重算 All-time 專案頁/趨勢(實測 92 天 12.4s),
    /// 快取讓「無新事件的刷新」變 O(1)。世代任一推進即失效,絕不回傳過期聚合。
    private var cachedProjectPage: (revision: UInt64, pricingStamp: UInt64, start: Date, end: Date, data: ProjectPageData)?
    private var cachedTrends: (revision: UInt64, pricingStamp: UInt64, days: Int, day: Date,
                               computedAt: Date, timeZoneID: String, data: TrendsData)?
    /// 價目世代:使用者覆寫寫入時 +1(價目影響所有成本聚合)。
    private var pricingStamp: UInt64 = 0
    /// F17 信任層(契約 v5 §1/§3):per-provider local 源的觀測記錄與遲滯 stale 旗標。
    /// attempt/lastAttempt 必須 per-provider 真實記錄(xcheck f17-r1:用全域時刻偽造會讓
    /// 「被跳過的 provider」顯示成已嘗試,connecting 態判定失真)。
    private var providerLastOkAt: [String: Date] = [:]
    private var providerLastAttemptAt: [String: Date] = [:]
    private var providerAttemptCounts: [String: Int] = [:]
    private var providerStaleFlags: [String: Bool] = [:]

    private var scanStateURL: URL { dataDir.appendingPathComponent("scan-state.json") }
    private var ledgerURL: URL { dataDir.appendingPathComponent("ledger.jsonl") }
    /// #48 §7:本次 refresh 的逐 provider data action(每輪 refresh 重置;僅 fullReindex 填寫)。
    private var providerOutcomes: [String: ProviderDataAction] = [:]

    /// #83 A′ restart 判定(PLAN-v2 §3.4)。取代 proto-I4 的 absence→full 推導與 process-local
    /// pending-fullReindex set:full 續跑意圖由 R7(amended)顯式 durable intent 欄位
    ///(`ScanState.pendingFullReconcile`)承載,absence 單獨不再授權 full-fold 語義
    ///(owner row-7 verdict:full source scan ≠ full-reindex fold semantics)。
    private enum ProviderStartDisposition: Equatable {
        case ordinary
        /// row 2:R7(amended)顯式 durable intent(`pendingFullReconcile`)→ 續跑 full。
        case resumeFull
        /// row 6:first authoritative construction(gen∧ack 皆缺、wm 缺,rebuildable)→
        /// full fold 語義(#83 U4:「空 state 下 ordinary 等價」被 [60@t1,45@t2] 反證——
        /// decrease-ending 歷史下 ordinary 得 60+pendingDecrease、full 得 45)。
        /// historical rescan of already-established provider(gen 存在)仍一律 ordinary。
        case firstContact
        /// row 5/8:ack 超前 limits(gen<ack,或 gen 缺席∧ack 存在)= invariant violation →
        /// loud fail-closed:本輪該 provider 完全 skip(不 scan、不落帳、不 ingest、watermark 不動,
        /// **派生 pass 亦排除**,U2),絕不自動 identity-reset(owner row-8 POISON verdict)。
        case poison(String)
    }

    /// #83 W1(clearing-2):poison 判定的**唯一**真相來源——pre-pass 與 classify 共用,
    /// 不在不同 phase 各自重算(owner contract)。
    private func poisonReason(_ pid: String) -> String? {
        let gen = limits.reconcileGeneration(for: pid)
        guard let ack = scanStates[pid]?.ackGeneration else { return nil }
        guard let g = gen else {
            return "scan-state acks generation \(ack) but limits has no reconciliation identity (row 8) — fail closed; explicit reindex required"
        }
        if g < ack {
            return "scan-state acks generation \(ack) ahead of limits generation \(g) (row 5) — fail closed; limits store appears rolled back"
        }
        return nil
    }

    private func classifyProviderStart(_ pid: String, historyModel: ProviderHistoryModel) -> ProviderStartDisposition {
        let gen = limits.reconcileGeneration(for: pid)
        let scan = scanStates[pid]
        if let why = poisonReason(pid) { return .poison(why) }
        // row 2(R7 amended):顯式 durable intent;ack==gen(或首次 requested-full:皆 nil)= full
        // 未 commit → 續跑。intent 在 ∧ gen>ack = full 已 commit、tail 丟 → ordinary(R6,
        // generation evidence 優先於 intent bit),成功 adopt 順手清 flag。
        if historyModel == .rebuildableHistory, scan?.pendingFullReconcile == true,
           gen == scan?.ackGeneration {
            return .resumeFull
        }
        if historyModel == .rebuildableHistory, gen == nil, scan?.ackGeneration == nil,
           scan?.files.isEmpty ?? true {
            return .firstContact   // row 6(U4)
        }
        if gen != nil, scan?.ackGeneration == nil {
            // row 7(U1):limits 歷史存在而 scan acknowledgement 遺失——ordinary 重掃(零重發),
            // 但必須 loud;ack 於本輪首個成功 reconciliation 重建。
            refreshQualityNotes.append("\(pid): scan-state acknowledgement missing while limits history exists (row 7) — ordinary rescan; acknowledgement will be re-established")
        }
        // rows 1/3/4/6′/7:ordinary(gen>ack 或 wm absent 一律 ordinary replay,R6;legacy 由
        // ingest 於首個 reconciliation 建立 identity)。fold 的 fullReindex flag 三源:
        // requested、row-2 resume、row-6 first contact。
        return .ordinary
    }

    /// #83 U1(#48 §7):providerOutcomes 只在 **requested** fullReindex 輪填寫;row-2 resume
    /// 輪(fullReindex=false)不得污染「增量刷新為空」contract——resume 的揭示走 quality note。
    private func recordReindexOutcome(_ pid: String, requested: Bool, _ action: ProviderDataAction) {
        if requested { providerOutcomes[pid] = action }
    }

    /// R5:成功腿統一經此 adopt——ack 寫入「此刻已 durable committed/confirmed」的 generation;
    /// full intent(若在)一併清除(reconciliation 完成 = intent 履行,R7 amended)。
    private func adoptScanState(_ pid: String, _ newState: ScanState) {
        var adopted = newState
        adopted.ackGeneration = limits.reconcileGeneration(for: pid)
        adopted.pendingFullReconcile = nil
        scanStates[pid] = adopted
    }

    /// #48 gate 判定(純函式,可測):whole-file raw canonicalization → per-provider baseline 切片 →
    /// candidate 以實際持久化 bytes canonicalize → compareMonotonic。任一 raw/canonicalization
    /// failure ⇒ preserve(count-only;檔級失敗無法歸屬 provider,對本 provider 一律 fail closed)。
    public enum MonotonicGateDecision: Equatable, Sendable {
        case pass
        case preserve(retained: Int, missing: Int, changed: Int, duplicates: Int, canonicalizationErrors: Int)
    }
    public static func monotonicGateDecision(baselineRaw: Data, providerId: String,
                                      candidate: [UsageEvent]) -> MonotonicGateDecision {
        func canonErrors(_ f: CanonicalLedgerV1.FailureSummary) -> Int {
            f.malformedLines + f.missingRequiredKeys + f.unknownTopLevelKeys + f.unknownTokenKeys
                + f.duplicateJSONMembers + f.escapedKeyNames + f.bomCount + f.nulByteCount
                + f.invalidEncodingCount + f.invalidTypes
        }
        switch CanonicalLedgerV1.canonicalizeRawLines(baselineRaw) {
        case .failure(let f):
            return .preserve(retained: 0, missing: 0, changed: 0,
                             duplicates: f.duplicateIDs, canonicalizationErrors: canonErrors(f))
        case .success(let whole):
            let b = CanonicalLedgerV1.Slice(events: whole.events.filter {
                $0.value.fields["providerId"] == .string(providerId)
            })
            // gate-r1 luna L4:candidate 只准含本 provider 的事件——壞 adapter 夾帶他 provider
            // 事件會在 replace 時被整批注入(污染而非遺失,但同屬未授權寫入)⇒ fail closed。
            guard candidate.allSatisfy({ $0.providerId == providerId }) else {
                return .preserve(retained: b.count, missing: 0, changed: 0,
                                 duplicates: 0, canonicalizationErrors: 1)
            }
            switch CanonicalLedgerV1.canonicalizePersistedBytes(of: candidate) {
            case .failure(let f):
                return .preserve(retained: b.count, missing: 0, changed: 0,
                                 duplicates: f.duplicateIDs, canonicalizationErrors: canonErrors(f))
            case .success(let c):
                switch CanonicalLedgerV1.compareMonotonic(baseline: b, candidate: c) {
                case .pass:
                    return .pass
                case .fail(let missing, let changed):
                    return .preserve(retained: b.count, missing: missing, changed: changed,
                                     duplicates: 0, canonicalizationErrors: 0)
                }
            }
        }
    }
    /// 持久化 scan-state(checked;供 reindex 前置「安全排序」用——失敗即 throw,呼叫端據此不 replace)。
    ///
    /// #64 P3(owner-locked、刻意的 asymmetry,勿「補強」):**A scan watermark is never a commit
    /// record. It may lag durable ledger state, but it must never lead it.**
    /// scan-state 是 rebuildable progress hint,**刻意不做 durability barrier**(帳本才是 authoritative
    /// accounting state,由 #64 P1/P2 的 F_FULLFSYNC+dir-fsync commit boundary 保護)。
    /// never-lead 由順序保證:記憶體 watermark 只在 ledger mutation durable ack 之後推進,本函數
    /// 又只寫當下記憶體 —— 任何 durable watermark 都蘊含一個更早完成的 ledger barrier。
    /// 丟失方向恆 safe:watermark 丟/舊 → 重掃 + id 去重(C-MF2);絕不因此把它做成雙檔 transaction
    ///(那不增 correctness、徒增 I/O,並誤導 maintainer 以為兩檔必須原子)。
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
        self.init(dataDir: dataDir, settings: settings, adapters: adapters,
                  refreshLockTimeout: refreshLockTimeout, readOnly: readOnly,
                  limitsDurabilityOps: .production)
    }

    /// internal(tests-only via `@testable`,mirror #64 DP-3):注入 LimitEngine barrier 失敗排程;
    /// production 一律經 public init(針 .production,無注入面)。
    init(dataDir: URL? = nil, settings: CoreSettings = CoreSettings(),
         adapters: [ProviderAdapter]? = nil, refreshLockTimeout: TimeInterval = 60,
         readOnly: Bool = false, limitsDurabilityOps: DurabilityOps) {
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
        self.limits = LimitEngine(stateURL: dir.appendingPathComponent("limits-state.json"), durabilityOps: limitsDurabilityOps)
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

    /// #48 gate-r1 luna L6:run-level skip(in-flight/lock/state-poison)時,fullReindex 的
    /// requested providers 如實標 not-attempted(增量刷新維持空 map)。
    private func notAttemptedOutcomes(fullReindex: Bool) -> [String: ProviderDataAction] {
        guard fullReindex else { return [:] }
        var m: [String: ProviderDataAction] = [:]
        for a in adapters where settings.enabledProviders.contains(a.providerId) {
            m[a.providerId] = .notAttempted
        }
        return m
    }

    // MARK: 刷新

    public func refresh(fullReindex: Bool = false) async -> RefreshOutcome {
        let now = Date()
        if refreshInFlight {
            var dash = dashboard(now: now)
            dash.dataQuality.append("refresh skipped — a refresh is already in progress")
            return RefreshOutcome(transitions: [], dashboard: dash, insertedEvents: 0, skipped: true,
                                  providerOutcomes: notAttemptedOutcomes(fullReindex: fullReindex))
        }
        refreshInFlight = true
        defer { refreshInFlight = false }

        // 寫入階段需要跨行程互斥(首次索引可達十餘秒,逾時給足裕度)。
        guard await refreshLock.acquireAsync(timeout: refreshLockTimeout) else {
            var dash = dashboard(now: now)
            dash.dataQuality.append("refresh skipped — another AI Pet Usage process (app or CLI) holds the data lock")
            return RefreshOutcome(transitions: [], dashboard: dash, insertedEvents: 0, skipped: true,
                                  providerOutcomes: notAttemptedOutcomes(fullReindex: fullReindex))
        }
        defer { refreshLock.release() }
        refreshQualityNotes = []
        providerOutcomes = [:]
        limits.clearDerivedFailure()   // #49 AM-8:derived loud-error 的明確 cycle reset(讀取在 refresh 尾)
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
            return RefreshOutcome(transitions: [], dashboard: dashboard(now: now), insertedEvents: 0, skipped: true,
                                  providerOutcomes: notAttemptedOutcomes(fullReindex: fullReindex))
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
        // #48 gate-r1(luna L1/L2):compact 前的 raw 完整性 precheck + 失敗訊號。
        // (a) typed 重寫會消滅 malformed/duplicate/unknown-key raw 行——compact「將動作」且 raw 層
        //     可疑時跳過本輪 compact(證據保留;destructive gate 稍後對同一 raw 自然 fail closed)。
        // (b) compact 落盤失敗 ⇒ 契約 step 4:本輪不得比較或 replacement(旗標令 gate 短路 preserve)。
        var compactBlockedReason: String? = nil   // nil = compact 正常(applied/noop);非 nil = gate 必須 preserve
        if ledger.compactWouldAct(retentionDays: settings.retentionDays, now: now) {
            // gate-r2 luna L1-殘餘:讀不到 raw 或 canonicalization 失敗**一律**跳過 compact(fail closed)
            // ——typed 重寫會消滅 malformed/duplicate/unknown-key raw 證據,不得在可疑/不可驗檔上發生。
            if let raw = try? Data(contentsOf: ledgerURL),
               case .success = CanonicalLedgerV1.canonicalizeRawLines(raw) {
                // sol r3 MF3:raw 保存式 compact——只丟可解析且確定過期的行,其餘逐位元組保留
                // (不經 typed round-trip,不改寫任何 provider 的 raw 表示)。
                switch ledger.compactRawPreserving(retentionDays: settings.retentionDays, now: now, raw: raw) {
                case .noop, .applied: break
                case .failed, .poisoned, .skippedSuspectRaw: compactBlockedReason = "compact-failed"
                }
            } else {
                compactBlockedReason = "raw-suspect"
            }
        } else {
            switch ledger.compact(retentionDays: settings.retentionDays, now: now) {   // no-op 快速路徑(保留 poisoned 回報)
            case .noop, .applied: break
            case .failed, .poisoned, .skippedSuspectRaw: compactBlockedReason = "compact-failed"
            }
        }

        if fullReindex {
            let enabled = Set(adapters.filter { settings.enabledProviders.contains($0.providerId) }.map { $0.providerId })
            let rescan = Set(adapters.filter {
                settings.enabledProviders.contains($0.providerId) && $0.detectAvailability().available
            }.map { $0.providerId })
            // 契約 F:不再「先清空再 append」(會變無操作/刪歷史);改為迴圈中「從零重掃 → 完整才切片取代」。
            fullReindexPreservedProviderIds = enabled.subtracting(rescan)   // 不可用者個別保留歷史
            for pid in fullReindexPreservedProviderIds { providerOutcomes[pid] = .preservedUnavailable }   // #48 §7
        }
        var transitions: [LimitTransition] = []
        var inserted = 0
        var attemptedThisRound: Set<String> = []    // #83 W5:真正進行 adapter work 的 providers(notAttempted 填補的排除依據)
        // #83 U2 + W1(clearing-2):poison pre-pass **先於 availability**——enabled ∧ poisoned 的
        // provider 無論 adapter 是否暫時 unavailable 都必須整輪 fail-closed;之後所有
        // sweep / estimated / marker / delivery 一律查同一個集合,不各自重算(owner contract)。
        var poisonedThisRefresh: Set<String> = []
        // #83 X2(final correction):poison 判定域 = **enabledProviders 全體**(非現存 adapters)——
        // enabled ∧ poisoned persisted state ∧ adapter 缺席(設定殘留/版本偏差)仍必須整輪
        // fail-closed(sweep / estimated / marker / delivery 全部禁止;W1 domain closure)。
        for pid in settings.enabledProviders.sorted() {
            if let why = poisonReason(pid) {
                poisonedThisRefresh.insert(pid)
                refreshErrors[pid] = why
                refreshQualityNotes.append("\(pid): \(why)")
            }
        }

        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            guard adapter.detectAvailability().available else { continue }
            let pid = adapter.providerId
            providerLastAttemptAt[pid] = now                          // F17:per-provider 真實嘗試記錄
            providerAttemptCounts[pid] = (providerAttemptCounts[pid] ?? 0) + 1
            if poisonedThisRefresh.contains(pid) {
                continue   // row 5/8:loud fail-closed(pre-pass 已記 error/note)——skip 全部(lastOk 不記,#74 語義)
            }
            // #83 A′:restart 判定先於一切讀寫(PLAN-v2 §3.4;poison 已由 pre-pass 擋,此處必非 poison)。
            let disposition = classifyProviderStart(pid, historyModel: adapter.historyModel)
            // #83 X1(final correction):真正開始 attempt ⇒ 清除 preflight 以第一次 availability
            // 探測 prefill 的 `.preservedUnavailable`(availability flap 下為 stale)。此後只有
            // work 成功才寫 truthful outcome;失敗 = 無 success/preserved outcome + loud(W5 contract)。
            providerOutcomes.removeValue(forKey: pid)
            attemptedThisRound.insert(pid)
            do {
                if (fullReindex || disposition == .resumeFull) && adapter.historyModel == .rebuildableHistory {
                    // 契約 F:從零重掃 → 只有「完整」掃描才切片取代(set-replace);不完整則保留舊切片、
                    // 舊 scanState、不刪歷史(契約 E / codex C8)。
                    // 注意:僅 rebuildableHistory 走此路;cumulativeSnapshotOnly(OpenCode)落到 else 走增量、
                    // 保留既有切片,絕不把累計總量塌成「現在的一筆」(codex MF2)。
                    let (result, newState) = try adapter.refreshUsage(state: ScanState())
                    switch result.completeness {
                    case .complete:
                        // #48 Option C gate(pivot §1/§3,owner 交易順序):
                        // candidate 已於 final 判定區「外」由 adapter scan 建立(上一行);
                        // 單一 retention cutoff——與 refresh 起點的 compact 用同一 `now`(C-MF6);
                        // 以下為 final 判定區:重讀最新 raw baseline → 兩側 CanonicalLedgerV1 →
                        // compareMonotonic → 同一 revision 邊界內 CAS replace;任何不通過/漂移/不可讀
                        // ⇒ 全量 preserve(不 partial、不覆寫較新帳本)。UI 呈現一律在鎖外(回傳後)。
                        // F17:scan 完整回讀 = 成功「觀測」(契約 §3 observation freshness)——
                        // gate 稍後 preserve 與否是帳本側保護決策,不改變源觀測成功的事實
                        //(源故障走 .incomplete / catch,該兩路不記 lastOk,維持 #74 語義)。
                        providerLastOkAt[pid] = now
                        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86400)
                        let freshKept = result.events.filter { $0.timestamp >= cutoff }
                        if let reason = compactBlockedReason {
                            // 契約 step 4(luna L2)/luna L1:compact 失敗或 raw 可疑 ⇒ 不得比較,全量 preserve。
                            fullReindexPreservedProviderIds.insert(pid)
                            recordReindexOutcome(pid, requested: fullReindex, reason == "compact-failed"
                                ? .failedBeforeCommit
                                : .preservedHistoryMismatch(retained: 0, missing: 0, changed: 0,
                                                            duplicates: 0, canonicalizationErrors: 1))
                            refreshQualityNotes.append("\(pid): reindex blocked — compaction unavailable; history preserved")
                            continue
                        }
                        ledger.reloadIfChanged()
                        if ledger.hasUnreconciledSnapshot {
                            // gate-r2 luna L3b-殘餘:unstable snapshot ⇒ 記憶體不可信,fail closed preserve。
                            fullReindexPreservedProviderIds.insert(pid)
                            recordReindexOutcome(pid, requested: fullReindex, .preservedHistoryMismatch(
                                retained: 0, missing: 0, changed: 0, duplicates: 0, canonicalizationErrors: 0))
                            refreshQualityNotes.append("\(pid): reindex blocked — history mismatch (retained 0, missing 0, changed 0, duplicate 0, canonicalization 0)")
                            continue
                        }
                        // luna L3(b):expected revision = 記憶體「載入時」指紋(loadedRevision),
                        // 使「typed 記憶體 == revision」為不變量;reload 後任何他人落盤都會令 CAS 失敗。
                        let revision = ledger.loadedRevision()
                        let baselineRaw: Data
                        if let d = try? Data(contentsOf: ledgerURL) {
                            baselineRaw = d
                        } else if AtomicJSON.pathIsGenuinelyMissing(ledgerURL.path) {
                            baselineRaw = Data()   // 合法空 baseline(初始化情境,pivot §5)
                        } else {
                            // 檔存在但不可讀 ⇒ fail closed preserve(count-only)。
                            fullReindexPreservedProviderIds.insert(pid)
                            recordReindexOutcome(pid, requested: fullReindex, .preservedHistoryMismatch(
                                retained: 0, missing: 0, changed: 0, duplicates: 0, canonicalizationErrors: 1))
                            refreshQualityNotes.append("\(pid): reindex blocked — history mismatch (retained 0, missing 0, changed 0, duplicate 0, canonicalization 1)")
                            continue
                        }
                        guard ledger.currentRevision().fp == revision.fp else {
                            // 讀取與 stat 之間 baseline 已漂移 ⇒ 放棄並 preserve(owner §3:不覆寫,v1 不 retry)。
                            fullReindexPreservedProviderIds.insert(pid)
                            recordReindexOutcome(pid, requested: fullReindex, .preservedHistoryMismatch(
                                retained: 0, missing: 0, changed: 0, duplicates: 0, canonicalizationErrors: 0))
                            refreshQualityNotes.append("\(pid): reindex blocked — history mismatch (retained 0, missing 0, changed 0, duplicate 0, canonicalization 0)")
                            continue
                        }
                        switch Self.monotonicGateDecision(baselineRaw: baselineRaw, providerId: pid, candidate: freshKept) {
                        case .pass:
                            // C-MF2 安全排序:先把此 provider 的 watermark 持久化為空,再 replace,最後才提交 newState。
                            // #83 R4:pre-clear 保留 acknowledged generation(寫入當下 gen——該 gen 已 durable
                            // committed,R5 允許)並豎起顯式 durable full intent(R7 amended:唯一寫出點在此);
                            // crash 後 restart 由 row 2(intent ∧ ack==gen)續跑,絕不落入 absence 歧義。
                            scanStates[pid] = ScanState(files: [:], ackGeneration: limits.reconcileGeneration(for: pid),
                                                        pendingFullReconcile: true)
                            try persistScanState()   // checked;失敗即 throw → catch → 保留舊切片(不 replace)
                            do {
                                inserted += try ledger.replaceProviderSlice(pid, with: freshKept, expectedRevision: revision,
                                                                            preservingRaw: baselineRaw)
                                // #49 R2 commit chain:durable ledger(上一行)→ durable limits(ingest 內
                                // saveDurably)→ 才 adopt watermark。invariant:provider scan watermark
                                // may lag durable LimitEngine state, but must never lead it.
                                // #83 W5(clearing-2,owner contract + twin):requested-full 失敗不得產生
                                // 看似成功的 provider outcome——limits fold 失敗時 **omit** 該 provider 的
                                // outcome(ledger durable truth 保留;failure 由 error/note 承載)。
                                // rebuildable 的 `.replaced`-on-fail 是 cumulative `.appendedCumulative` 的
                                // twin(同一 contract 條文),一併收斂。
                                switch limits.ingest(readings: result.rateLimits, settings: settings, fullReindex: true, now: now, reconcilingProvider: pid) {
                                case .unchanged:
                                    adoptScanState(pid, newState)
                                    refreshErrors[pid] = nil
                                    if !fullReindex { refreshQualityNotes.append("\(pid): resumed full reconciliation completed (row 2)") }   // U1
                                    recordReindexOutcome(pid, requested: fullReindex, .replaced)
                                case .committed(let t):
                                    adoptScanState(pid, newState)
                                    transitions += t
                                    refreshErrors[pid] = nil
                                    if !fullReindex { refreshQualityNotes.append("\(pid): resumed full reconciliation completed (row 2)") }   // U1
                                    recordReindexOutcome(pid, requested: fullReindex, .replaced)
                                case .failed(let err):
                                    // limits durable commit 未成立 ⇒ watermark 不推、outcome 缺席(W5)。
                                    // durable intent 已在(pre-clear)⇒ 下輪 row 2 續跑 full。
                                    refreshQualityNotes.append("\(pid): limits durable save failed — full reconciliation will resume next refresh (row 2)")
                                    refreshErrors[pid] = String(describing: err)
                                }
                                parseErrorCounts[pid] = result.parseErrors
                            } catch UsageLedger.CASError.revisionChanged {
                                // compare 後、replace 前另一寫入落盤 ⇒ CAS 放棄,全量 preserve。
                                fullReindexPreservedProviderIds.insert(pid)
                                recordReindexOutcome(pid, requested: fullReindex, .preservedHistoryMismatch(
                                    retained: 0, missing: 0, changed: 0, duplicates: 0, canonicalizationErrors: 0))
                                refreshQualityNotes.append("\(pid): reindex blocked — history mismatch (retained 0, missing 0, changed 0, duplicate 0, canonicalization 0)")
                            }
                        case .preserve(let r, let m, let c, let d, let e):
                            fullReindexPreservedProviderIds.insert(pid)   // 保留舊切片,不刪歷史
                            recordReindexOutcome(pid, requested: fullReindex, .preservedHistoryMismatch(
                                retained: r, missing: m, changed: c, duplicates: d, canonicalizationErrors: e))
                            refreshQualityNotes.append("\(pid): reindex blocked — history mismatch (retained \(r), missing \(m), changed \(c), duplicate \(d), canonicalization \(e))")
                            parseErrorCounts[pid] = result.parseErrors
                            refreshErrors[pid] = nil
                        }
                    case .incomplete:
                        fullReindexPreservedProviderIds.insert(pid)   // 保留舊切片,不刪歷史
                        recordReindexOutcome(pid, requested: fullReindex, .preservedIncomplete)
                        refreshQualityNotes.append("\(pid): reindex incomplete — history preserved")   // 誠實通知(非 error)
                    }
                } else {
                    let state = scanStates[pid] ?? ScanState()
                    let (result, newState) = try adapter.refreshUsage(state: state)
                    inserted += ledger.append(result.events)         // 交易式落盤(記憶體僅落盤成功才提交)
                    if let we = ledger.writeError { throw we }        // 落盤失敗 → 不提交下面(契約 B/M5)
                    // #49 R2 commit chain:durable ledger(append 已 barrier)→ durable limits →
                    // 才 adopt watermark(invariant:watermark may lag durable limits, never lead)。
                    // #83 A′:full-fold 語義三源——requested 同輪(此處 = cumulative 的 requested
                    // full)、row-2 續跑(rebuildable,上方分支)、row-6 first contact(U4:first
                    // authoritative construction 用 full fold;established provider 的重掃恆 ordinary)。
                    // absence/pending 推導已廢(R6)。cumulative 的 requested full .failed 不自動重試
                    //(owner D1 verdict:loud、explicit rerun required)。
                    let effFull = fullReindex || disposition == .firstContact
                    var limitsCommitted = true   // #83 W5
                    switch limits.ingest(readings: result.rateLimits, settings: settings, fullReindex: effFull, now: now, reconcilingProvider: pid) {
                    case .unchanged:
                        adoptScanState(pid, newState)
                        refreshErrors[pid] = nil
                    case .committed(let t):
                        adoptScanState(pid, newState)
                        transitions += t
                        refreshErrors[pid] = nil
                    case .failed(let err):
                        limitsCommitted = false
                        if fullReindex {
                            refreshQualityNotes.append("\(pid): limits durable save failed — requested full fold not committed; re-run reindex to reapply")
                        } else {
                            refreshQualityNotes.append("\(pid): limits durable save failed — watermark held, will re-ingest next refresh")
                        }
                        refreshErrors[pid] = String(describing: err)
                    }
                    parseErrorCounts[pid] = result.parseErrors
                    providerLastOkAt[pid] = now   // F17:成功觀測
                    if fullReindex {
                        // 走到 else 且 fullReindex → 必為 cumulativeSnapshotOnly(OpenCode):保留累計歷史、僅增量(不重建)。
                        // #83 W5(owner contract):ledger append 成功 ∧ limits fold 失敗 ⇒ **omit** 該
                        // provider 的 outcome——不得以 .appendedCumulative 把 partial failure 表示成
                        // 成功(failure 由 error/note 承載;attemptedThisRound 防 notAttempted 誤標)。
                        if limitsCommitted {
                            providerOutcomes[pid] = .appendedCumulative   // #48 §7:成功 append + fold 成立
                            refreshQualityNotes.append("\(pid): reindex kept cumulative history — not rebuildable")
                        }
                    }
                }
            } catch {
                refreshErrors[pid] = String(describing: error)
                if fullReindex { providerOutcomes[pid] = .failedBeforeCommit }   // #48 §7:commit 前失敗如實
                // C-MF4:帳本落盤失敗 → 停止後續 provider 的 append,避免下一個成功寫入把指紋更新到「含半寫位元組」
                // 的磁碟、遮蔽未採用的批次(load/append 已設 expectedFingerprint=nil 強制下輪對帳)。
                if ledger.writeError != nil { break }
            }
        }
        if fullReindex {
            // #48 §7:mid-loop 中斷後未嘗試(或被 skip)的 requested provider 如實標 not-attempted。
            // #83 W5:真正嘗試過(進行了 adapter work)但 limits fold 失敗而 omit outcome 的
            // provider 不得被誤標 notAttempted——以 attemptedThisRound 排除。
            let requested = Set(adapters.filter { settings.enabledProviders.contains($0.providerId) }.map(\.providerId))
            for pid in requested where providerOutcomes[pid] == nil && !attemptedThisRound.contains(pid) {
                providerOutcomes[pid] = .notAttempted
            }
        }

        transitions += limits.sweepExpiredWindows(now: now, excluding: poisonedThisRefresh)   // U2

        // Claude 估算區塊的重置偵測(U2:poisoned 亦排除)
        if settings.enabledProviders.contains("claude-code"), !poisonedThisRefresh.contains("claude-code") {
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

        // #49 R3:derived-state(sweep/estimatedBlock)持久化失敗 = loud-but-nonblocking——
        // 可自 durable ledger/limits 重算,下輪即補;絕不因此否定已 durable 的 ingest、不撤 watermark。
        if let derr = limits.derivedSaveError {
            refreshQualityNotes.append("limits derived-state save failed (recomputed next refresh): \(derr)")
        }

        do {
            try AtomicJSON.write(scanStates, to: scanStateURL)   // C-MF8:寫失敗不再靜默
        } catch {
            refreshQualityNotes.append("scan-state write failed — will re-scan next refresh")
        }
        lastRefreshAt = now
        return RefreshOutcome(transitions: transitions, dashboard: dashboard(now: now),
                              insertedEvents: inserted, providerOutcomes: providerOutcomes)
    }

    // MARK: Dashboard 組裝

    public func dashboard(now: Date = Date()) -> DashboardState {
        let today = DateInterval.today(now: now)
        // 單趟累加今日總量 / 成本 / 逐 provider 分量(原本 materialize 全日事件陣列後
        // 再逐 provider filter + 重複計價;成本逐筆累加 ≡ cost(of: [events]))。
        struct ProviderAcc { var tokens = TokenBreakdown.zero; var cost = CostResult.zero }
        var todayTotals = TokenBreakdown.zero
        var todayCost = CostResult.zero
        var todayByProviderAcc: [String: ProviderAcc] = [:]
        ledger.forEachEvent(in: today) { e in
            let c = self.pricing.cost(of: e)
            todayTotals = todayTotals + e.tokens
            todayCost = todayCost + c
            var acc = todayByProviderAcc[e.providerId] ?? ProviderAcc()
            acc.tokens = acc.tokens + e.tokens
            acc.cost = acc.cost + c
            todayByProviderAcc[e.providerId] = acc
        }

        var limitStates: [ProviderLimitState] = []
        var snapshots: [UsageSnapshot] = []
        var byProvider: [ProviderDaySummary] = []

        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            let pid = adapter.providerId
            let availability = adapter.detectAvailability()
            let limit = limits.limitState(providerId: pid, ledger: ledger, settings: settings, now: now)
            limitStates.append(limit)

            let acc = todayByProviderAcc[pid] ?? ProviderAcc()
            let tokens = acc.tokens
            byProvider.append(ProviderDaySummary(providerId: pid, displayName: adapter.displayName,
                                                 tokens: tokens, cost: acc.cost))

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
                estimatedCost: acc.cost.knownUSD,
                sourceDescription: availability.detail,
                errorMessage: refreshErrors[pid]
            ))
        }

        var burnCostAcc = CostResult.zero
        ledger.forEachEvent(in: DateInterval(start: now.addingTimeInterval(-3600), end: now)) {
            burnCostAcc = burnCostAcc + self.pricing.cost(of: $0)
        }
        let burnCost = burnCostAcc.knownUSD

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
        // 快取命中:世代未變 + 同起點 + 終點等價(兩終點都嚴格晚於最新事件 ⇒ 事件集相同;
        // events(in:) 對終點半開)。today/All-time 的 end=now 每次呼叫都不同,故不能只比 end。
        let rev = ledger.revision
        let newest = ledger.newestEvent()?.timestamp
        if let c = cachedProjectPage, c.revision == rev, c.pricingStamp == pricingStamp,
           c.start == range.start,
           c.end == range.end || (newest.map { c.end > $0 && range.end > $0 } ?? true) {
            var data = c.data
            data.range = range
            return data
        }
        var totals = TokenBreakdown.zero
        var cost = CostResult.zero
        ledger.forEachEvent(in: range) { e in
            totals = totals + e.tokens
            cost = cost + self.pricing.cost(of: e)
        }
        let data = ProjectPageData(
            range: range,
            projects: ledger.projectSummaries(in: range, pricing: pricing),
            models: ledger.modelSummaries(in: range, pricing: pricing),
            totals: totals,
            cost: cost
        )
        cachedProjectPage = (rev, pricingStamp, range.start, range.end, data)
        return data
    }

    /// Trends 分頁資料:近 `days` 天的日聚合 + 使用連續天數 + 週對比。純本機、零新依賴。
    public func trendsData(days: Int, now: Date = Date()) -> TrendsData {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        // 快取:世代 + 天數 + 本地日未變 ⇒ 事件集與日界皆相同(end=now 前移但無新事件)。
        // xcheck r1(三鏡收斂)再加三個維度,任何一個不成立就重算:
        // (1) newest **嚴格早於** computedAt:帳本若含「時間戳 ≥ 上次計算時刻」的事件
        //     (來源日誌時鐘偏移),end=now 前移會把它納入 —— revision 不變也必須失效
        //     (projectPage 的 newest 條件同思想)。等號不可命中:區間半開,ts == end
        //     的事件被當時的計算排除,等號命中會讓它同日內永遠隱形(xcheck r2 三鏡)。
        // (2) computedAt ≤ now:系統時鐘回撥後,舊快取的 end 反而比現在寬 —— 不得沿用;
        // (3) 時區身分:同一 `today` 瞬間在歷史 offset 不同的時區下,日桶邊界不同。
        if let c = cachedTrends, c.revision == ledger.revision, c.pricingStamp == pricingStamp,
           c.days == days, c.day == today,
           c.computedAt <= now,
           (ledger.newestEvent()?.timestamp ?? .distantPast) < c.computedAt,
           c.timeZoneID == TimeZone.current.identifier {
            return c.data
        }
        let start = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        let daily = ledger.dailyBuckets(in: DateInterval(start: start, end: now), pricing: pricing)
        let streak = ledger.usageStreak(now: now)
        let thisWeekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let lastWeekStart = cal.date(byAdding: .day, value: -13, to: today) ?? today
        let thisWeek = ledger.totals(in: DateInterval(start: thisWeekStart, end: now)).total
        let lastWeek = ledger.totals(in: DateInterval(start: lastWeekStart, end: thisWeekStart)).total
        let data = TrendsData(rangeDays: days, startDay: start, endDay: today, daily: daily,
                              streak: streak, thisWeekTokens: thisWeek, lastWeekTokens: lastWeek)
        cachedTrends = (ledger.revision, pricingStamp, days, today, now, TimeZone.current.identifier, data)
        return data
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
        let dash = dashboard(now: now)

        // 單趟累加期間總量 / 成本 / 逐 provider 分量 / 日總量(原本 materialize 期間事件
        // 陣列後做多趟 filter+reduce;92 天期間為實測熱點)。
        struct ProviderAcc { var tokens = TokenBreakdown.zero; var cost = CostResult.zero }
        let cal = Calendar.current
        var totals = TokenBreakdown.zero
        var cost = CostResult.zero
        var perProvider: [String: ProviderAcc] = [:]
        var dayTotals: [Date: Int] = [:]
        let wantsDayBuckets = period.duration > 48 * 3600
        ledger.forEachEvent(in: period) { e in
            let c = self.pricing.cost(of: e)
            totals = totals + e.tokens
            cost = cost + c
            var acc = perProvider[e.providerId] ?? ProviderAcc()
            acc.tokens = acc.tokens + e.tokens
            acc.cost = acc.cost + c
            perProvider[e.providerId] = acc
            if wantsDayBuckets {
                dayTotals[cal.startOfDay(for: e.timestamp), default: 0] += e.tokens.total
            }
        }

        var providerRows: [ProviderDaySummary] = []
        for adapter in adapters where settings.enabledProviders.contains(adapter.providerId) {
            let acc = perProvider[adapter.providerId] ?? ProviderAcc()
            providerRows.append(ProviderDaySummary(providerId: adapter.providerId, displayName: adapter.displayName,
                                                   tokens: acc.tokens, cost: acc.cost))
        }

        // 期間 ≤ 48 小時用小時刻度,否則用日刻度。
        var buckets: [(String, Int)] = []
        if !wantsDayBuckets {
            let df = DateFormatter(); df.dateFormat = "MM-dd HH:00"
            buckets = ledger.hourlyBuckets(in: period, calendar: cal).map { (df.string(from: $0.start), $0.tokens) }
        } else {
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
            totals: totals,
            cost: cost,
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
        var buckets = Set<Int>()
        ledger.forEachEvent(in: .today(now: now)) {
            buckets.insert(Int($0.timestamp.timeIntervalSince1970 / 300))
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

    // MARK: F17 信任層

    /// 現有 local 源的 DataSourceStatus(契約 v5 §1:per-source 原子單位;officialAPI 源
    /// 屬 F3+,#73 boundary 已核准、實作另行落地 —— 本方法零網路)。
    /// local 源 health 只有 ok / stale / transientError 三態(契約 §5)。
    public func dataSourceStatuses(now: Date = Date()) -> [DataSourceStatus] {
        adapters.map { adapter in
            let pid = adapter.providerId
            let enabled = settings.enabledProviders.contains(pid)
            let avail = adapter.detectAvailability()
            // presence 優先序:disabled > unavailable > active(契約 §1)。
            // unavailable 細分(xcheck f17-r1):adapter.roots 是 existence-filtered ——
            // roots 非空表示來源目錄存在(裝了)→ noSourceFiles;全空 → notInstalled。
            let presence: SourcePresence
            if !enabled {
                presence = .disabled
            } else if avail.available {
                presence = .active
            } else {
                presence = .unavailable(adapter.roots.isEmpty ? .notInstalled : .noSourceFiles)
            }
            let lastOk = providerLastOkAt[pid]
            // local scan 的 observation window:app 的 refresh tick 為分鐘級,取 5 分鐘上限
            // (契約 §3:「window = refresh 週期上限(預設 tick 分鐘級)」)。
            let window: TimeInterval = 300
            let assess = Freshness.assessObservation(lastObservedOk: lastOk, window: window,
                                                     currentlyStale: providerStaleFlags[pid] ?? false,
                                                     now: now)
            providerStaleFlags[pid] = assess.isStale   // 遲滯記憶
            let machine: SourceHealth = refreshErrors[pid] != nil ? .transientError : .ok
            let health = HealthDisplay.effective(machine: machine, isStale: assess.isStale)
            var note = assess.note
            let newest = ledger.newestEvent(providerId: pid)?.timestamp
            // 資料時戳超前(future event)也是時鐘異常(契約 §3「檔案時戳超前」;xcheck f17-r1)
            if note == .none, let n = newest, n > now { note = .clockChanged }
            if note == .none, (parseErrorCounts[pid] ?? 0) > 0 { note = .parseWarnings }
            return DataSourceStatus(
                providerId: pid, kind: .localLogs,
                presence: presence, health: health,
                lastObservedOk: lastOk, lastAttemptAt: providerLastAttemptAt[pid],
                newestDataAt: newest,
                attemptCount: providerAttemptCounts[pid] ?? 0,
                provenanceNote: note,
                recoveryAction: HealthDisplay.recovery(for: health, presence: presence, cli: pid))
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
        pricingStamp &+= 1   // 價目變動 → 聚合快取全部失效
    }
}
