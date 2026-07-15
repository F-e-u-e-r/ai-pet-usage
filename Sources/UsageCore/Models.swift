import Foundation

// MARK: - Token accounting

/// 正規化的 token 分類。`input` 一律指「非快取」輸入;快取讀寫分開計,方便逐類計價。
public struct TokenBreakdown: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    public var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    public static func + (a: TokenBreakdown, b: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h
        )
    }

    public static let zero = TokenBreakdown()
}

// MARK: - Usage events (ledger rows)

public struct UsageEvent: Codable, Hashable, Sendable, Identifiable {
    /// 穩定去重鍵(provider 前綴 + 來源內固有識別碼)。
    public var id: String
    public var providerId: String
    public var accountId: String?
    /// 專案的穩定識別(通常是 cwd 路徑字串);報告預設只顯示 `projectName`。
    public var projectId: String?
    public var projectName: String?
    public var modelId: String?
    public var timestamp: Date
    public var tokens: TokenBreakdown
    public var sourceKind: String
    public var sourcePath: String?

    public init(id: String, providerId: String, accountId: String? = nil, projectId: String? = nil,
                projectName: String? = nil, modelId: String? = nil, timestamp: Date,
                tokens: TokenBreakdown, sourceKind: String, sourcePath: String? = nil) {
        self.id = id
        self.providerId = providerId
        self.accountId = accountId
        self.projectId = projectId
        self.projectName = projectName
        self.modelId = modelId
        self.timestamp = timestamp
        self.tokens = tokens
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
    }
}

// MARK: - Provider-reported rate limits (source events, not final truth)

public struct RateLimitWindowReading: Codable, Hashable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

/// 單一時點的 rate-limit 讀值。契約:`primary` = **正規化後的 5 小時窗**、`secondary` =
/// **正規化後的週窗**——與各 adapter 的 JSON 原始欄位位置無關(尤其 Codex 的 primary/
/// secondary 位置不保證窗型;CodexAdapter 以 window_minutes 分類後才填入此處)。
public struct RateLimitReading: Codable, Hashable, Sendable {
    public var providerId: String
    public var observedAt: Date
    /// 正規化後的 5 小時(短)窗;無則 nil。
    public var primary: RateLimitWindowReading?
    /// 正規化後的週(長)窗;無則 nil。
    public var secondary: RateLimitWindowReading?
    public var planType: String?
    public var sourcePath: String?

    public init(providerId: String, observedAt: Date, primary: RateLimitWindowReading?,
                secondary: RateLimitWindowReading?, planType: String? = nil, sourcePath: String? = nil) {
        self.providerId = providerId
        self.observedAt = observedAt
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.sourcePath = sourcePath
    }
}

// MARK: - Normalized provider snapshot (what the pet & UI consume)

public enum ProviderStatus: String, Codable, Sendable {
    case unavailable
    case noData
    case stale
    case healthy
    case warning
    case exhausted
    case error
}

public struct UsageSnapshot: Codable, Sendable, Identifiable {
    public var providerId: String
    public var displayName: String
    public var status: ProviderStatus
    public var sessionUsagePercent: Double?
    public var weeklyUsagePercent: Double?
    public var resetAt: Date?
    public var updatedAt: Date?
    public var tokenInput: Int?
    public var tokenOutput: Int?
    public var tokenCache: Int?
    public var estimatedCost: Double?
    public var sourceDescription: String
    public var errorMessage: String?

    public var id: String { providerId }

    public init(providerId: String, displayName: String, status: ProviderStatus,
                sessionUsagePercent: Double? = nil, weeklyUsagePercent: Double? = nil,
                resetAt: Date? = nil, updatedAt: Date? = nil,
                tokenInput: Int? = nil, tokenOutput: Int? = nil, tokenCache: Int? = nil,
                estimatedCost: Double? = nil, sourceDescription: String, errorMessage: String? = nil) {
        self.providerId = providerId
        self.displayName = displayName
        self.status = status
        self.sessionUsagePercent = sessionUsagePercent
        self.weeklyUsagePercent = weeklyUsagePercent
        self.resetAt = resetAt
        self.updatedAt = updatedAt
        self.tokenInput = tokenInput
        self.tokenOutput = tokenOutput
        self.tokenCache = tokenCache
        self.estimatedCost = estimatedCost
        self.sourceDescription = sourceDescription
        self.errorMessage = errorMessage
    }
}

// MARK: - Limit state

public enum Confidence: String, Codable, Sendable {
    case high
    case estimated
    case stale
    case unknown
}

public enum WarningState: String, Codable, Sendable {
    case ok
    case warning
    case exhausted
    case stale
    case noData
}

/// 同窗向下修正的合法通道(政策見 docs/DATA_SOURCES.md「Limit calculation policy」)。
public enum CorrectionReason: String, Codable, Sendable {
    /// 連續 ≥2 筆 observedAt 嚴格遞增、降幅 >0.5pt 的較新官方讀數確認(方案升級/後端重算)。
    case official
    /// 使用者觸發的全量重建索引。
    case reindex
}

public struct LimitWindowState: Codable, Sendable, Hashable {
    public var usedPercent: Double?
    public var usedTokens: Int?
    public var budgetTokens: Int?
    public var resetAt: Date?
    public var windowMinutes: Int
    public var confidence: Confidence
    /// 有近期活動(本週用量 > 0)但當前無 active 5h 區塊 → **idle(閒置)**,與「從未使用/無資料」
    /// 明確區分。idle 時 usedPercent 恆為 nil(絕不造假 0%),各面板顯示「idle / no active 5h window」。
    public var idle: Bool
    /// 同一窗口內「最近 24h 內」發生過向下修正(Full Reindex 或二筆確認的官方下修),
    /// UI/報告/CLI 據此標示。組裝層統一以 correctedAt 閘 24h — 修正是一次性事件,
    /// 不是永久狀態;超過 24h 或缺 correctedAt(舊 state)一律不 surface。
    public var corrected: Bool
    public var correctedAt: Date?
    public var correctedReason: CorrectionReason?

    public init(usedPercent: Double? = nil, usedTokens: Int? = nil, budgetTokens: Int? = nil,
                resetAt: Date? = nil, windowMinutes: Int, confidence: Confidence, idle: Bool = false,
                corrected: Bool = false,
                correctedAt: Date? = nil, correctedReason: CorrectionReason? = nil) {
        // 使用率天花板 100%:官方讀值或預算估算(tokens/budget×100)可能回報 >100,
        // 對外一律夾到 [0, 100],避免 UI 出現 101% / 103%。
        self.usedPercent = usedPercent.map { min(100, max(0, $0)) }
        self.usedTokens = usedTokens
        self.budgetTokens = budgetTokens
        self.resetAt = resetAt
        self.windowMinutes = windowMinutes
        self.confidence = confidence
        self.idle = idle
        self.corrected = corrected
        self.correctedAt = correctedAt
        self.correctedReason = correctedReason
    }
}

public struct ProviderLimitState: Codable, Sendable, Identifiable {
    public var providerId: String
    public var fiveHour: LimitWindowState
    public var weekly: LimitWindowState
    public var burnRateTokensPerHour: Double
    public var projectedExhaustionAt: Date?
    public var lastEventAt: Date?
    public var lastReadingAt: Date?
    public var warning: WarningState
    public var planType: String?
    public var lastSourceDescription: String?

    public var id: String { providerId }

    public init(providerId: String, fiveHour: LimitWindowState, weekly: LimitWindowState,
                burnRateTokensPerHour: Double = 0, projectedExhaustionAt: Date? = nil,
                lastEventAt: Date? = nil, lastReadingAt: Date? = nil,
                warning: WarningState = .ok, planType: String? = nil, lastSourceDescription: String? = nil) {
        self.providerId = providerId
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.burnRateTokensPerHour = burnRateTokensPerHour
        self.projectedExhaustionAt = projectedExhaustionAt
        self.lastEventAt = lastEventAt
        self.lastReadingAt = lastReadingAt
        self.warning = warning
        self.planType = planType
        self.lastSourceDescription = lastSourceDescription
    }
}

/// 限額引擎在單次刷新中偵測到的重要轉變(供寵物/通知使用)。
public enum LimitTransition: Sendable, Hashable {
    case reset(providerId: String, window: String)
    case crossedThreshold(providerId: String, window: String, percent: Double, threshold: Double)
    case exhausted(providerId: String, window: String)
}

// MARK: - Aggregates for pages & reports

public struct ProjectSummary: Codable, Sendable, Identifiable {
    public var projectId: String
    public var projectName: String
    public var tokens: TokenBreakdown
    public var cost: CostResult
    public var providers: [String]
    public var topModel: String?
    public var lastActive: Date?
    public var shareOfPeriod: Double

    public var id: String { projectId }

    public init(projectId: String, projectName: String, tokens: TokenBreakdown, cost: CostResult,
                providers: [String], topModel: String?, lastActive: Date?, shareOfPeriod: Double) {
        self.projectId = projectId
        self.projectName = projectName
        self.tokens = tokens
        self.cost = cost
        self.providers = providers
        self.topModel = topModel
        self.lastActive = lastActive
        self.shareOfPeriod = shareOfPeriod
    }
}

public struct ModelUsageSummary: Codable, Sendable, Identifiable {
    public var providerId: String
    public var modelId: String
    public var tokens: TokenBreakdown
    public var cost: CostResult

    public var id: String { providerId + "/" + modelId }

    public init(providerId: String, modelId: String, tokens: TokenBreakdown, cost: CostResult) {
        self.providerId = providerId
        self.modelId = modelId
        self.tokens = tokens
        self.cost = cost
    }
}

public struct HourBucket: Codable, Sendable, Identifiable {
    public var start: Date
    public var tokens: Int
    public var byProvider: [String: Int]
    public var breakdown: TokenBreakdown
    public var topProject: String?

    public var id: Date { start }

    public init(start: Date, tokens: Int, byProvider: [String: Int],
                breakdown: TokenBreakdown = .zero, topProject: String? = nil) {
        self.start = start
        self.tokens = tokens
        self.byProvider = byProvider
        self.breakdown = breakdown
        self.topProject = topProject
    }
}

/// 單日用量聚合(Trends 曲線與日曆熱圖共用)。`day` 為行事曆本地日的起點(午夜)。
public struct DayBucket: Codable, Sendable, Identifiable {
    public var day: Date
    public var tokens: Int
    public var byProvider: [String: Int]
    /// 當日用量最多的 project / model(依 tokens);Trends hover 顯示用。
    public var topProject: String?
    public var topModel: String?
    /// 當日估算成本(含 unknownModelTokens/isEstimated,避免未定價用量顯示成 $0);
    /// 需傳入 pricing 才計算,否則 .zero。
    public var cost: CostResult

    public var id: Date { day }

    public init(day: Date, tokens: Int, byProvider: [String: Int] = [:],
                topProject: String? = nil, topModel: String? = nil, cost: CostResult = .zero) {
        self.day = day
        self.tokens = tokens
        self.byProvider = byProvider
        self.topProject = topProject
        self.topModel = topModel
        self.cost = cost
    }
}

/// 使用連續天數:current = 以今天(或今天尚無用量時以昨天)結尾的連續活躍日;
/// longest = 整段紀錄中最長的連續活躍日。
public struct UsageStreak: Codable, Sendable, Hashable {
    public var current: Int
    public var longest: Int

    public init(current: Int, longest: Int) {
        self.current = current
        self.longest = longest
    }
}

/// 成本計算結果:`known` 為有定價依據的部分;缺定價的 token 歸入 `unknownModelTokens`。
public struct CostResult: Codable, Sendable, Hashable {
    public var knownUSD: Double
    public var unknownModelTokens: Int
    public var isEstimated: Bool

    public init(knownUSD: Double = 0, unknownModelTokens: Int = 0, isEstimated: Bool = false) {
        self.knownUSD = knownUSD
        self.unknownModelTokens = unknownModelTokens
        self.isEstimated = isEstimated
    }

    public static func + (a: CostResult, b: CostResult) -> CostResult {
        CostResult(knownUSD: a.knownUSD + b.knownUSD,
                   unknownModelTokens: a.unknownModelTokens + b.unknownModelTokens,
                   isEstimated: a.isEstimated || b.isEstimated)
    }

    public static let zero = CostResult()
}

// MARK: - Provider adapter contract

public struct ProviderAvailability: Sendable {
    public var available: Bool
    public var detail: String

    public init(available: Bool, detail: String) {
        self.available = available
        self.detail = detail
    }
}

public struct FileScanMark: Codable, Sendable, Hashable {
    public var offset: Int64
    public var size: Int64
    /// 續讀所需的小型解析上下文(如 Codex 的目前 model/cwd/累計 totals)。
    public var context: [String: String]?

    public init(offset: Int64, size: Int64, context: [String: String]? = nil) {
        self.offset = offset
        self.size = size
        self.context = context
    }
}

/// 每個 adapter 的掃描進度(檔案 path → 已處理位移),持久化以支援增量刷新。
public struct ScanState: Codable, Sendable {
    public var files: [String: FileScanMark]

    public init(files: [String: FileScanMark] = [:]) {
        self.files = files
    }
}

public struct AdapterRefreshResult: Sendable {
    public var events: [UsageEvent]
    public var rateLimits: [RateLimitReading]
    public var scannedFiles: Int
    public var parseErrors: Int

    public init(events: [UsageEvent] = [], rateLimits: [RateLimitReading] = [],
                scannedFiles: Int = 0, parseErrors: Int = 0) {
        self.events = events
        self.rateLimits = rateLimits
        self.scannedFiles = scannedFiles
        self.parseErrors = parseErrors
    }
}

public protocol ProviderAdapter: Sendable {
    var providerId: String { get }
    var displayName: String { get }
    /// 本機資料來源目錄(已即時存在性過濾);供 FSEvents 檔案監看列出要看的路徑。
    var roots: [URL] { get }
    /// 額外要監看的獨立檔(如 Claude statusline 落地檔):其父目錄會被監看,
    /// 檔路徑本身作為「觸發白名單」——同目錄下我方寫入的檔(帳本/設定)不會誤觸 refresh。
    var watchFiles: [URL] { get }
    func detectAvailability() -> ProviderAvailability
    /// 從 `state` 記錄的位移續讀;回傳新事件與更新後的掃描進度。實作必須只讀。
    func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState)
    func explainDataSources() -> String
    func explainRequiredPermissions() -> String
    /// 診斷用的候選來源(未經存在性過濾),供 `aipet diag` 回報每個來源的
    /// 存在/可讀/mtime——只回報固定 id + 狀態,絕不外洩實際 URL/路徑。預設空。
    /// **必須**列為 protocol 要求(而非僅 extension),否則對 existential 會靜態派發到預設空實作。
    func diagnosticSources() -> [DiagnosticSourceDescriptor]
}

public extension ProviderAdapter {
    var watchFiles: [URL] { [] }
    func diagnosticSources() -> [DiagnosticSourceDescriptor] { [] }
}

/// 診斷來源的**固定**識別碼。標籤(如 `~/.codex/sessions`)由 DiagnosticReport 的固定查表
/// 產生,不使用實際解析後的 URL——即使 CODEX_HOME/CLAUDE_CONFIG_DIR/GROK_HOME 指向家目錄外,
/// 報告也只呈現正規預設標籤,永不回顯真實路徑。
public enum DiagnosticSourceID: String, Codable, Sendable, CaseIterable {
    case codexSessions
    case codexArchived
    case claudeProjects
    case claudeStatuslineOurHook
    case claudeStatuslineShared
    case grokSessions
}

/// adapter 回報的候選來源:固定 id + 實際 URL。URL 只在蒐集階段用來 stat,
/// **絕不**寫入診斷報告(報告只留 id/狀態/mtime 分桶)。
public struct DiagnosticSourceDescriptor: Sendable {
    public var id: DiagnosticSourceID
    public var url: URL
    public init(id: DiagnosticSourceID, url: URL) {
        self.id = id
        self.url = url
    }
}
