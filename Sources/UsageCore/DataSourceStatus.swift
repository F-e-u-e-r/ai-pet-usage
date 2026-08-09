import Foundation

// F17 信任層 substrate(Phase 1 data contract v5 的直譯;契約:docs/PHASE1_DATA_CONTRACT.internal.md,
// 凍結 sha 記於 reviews/phase1-contract-v5-freeze.txt)。本檔只定義型別與純函數狀態機 ——
// **零 network、零 I/O、全部時刻由呼叫端注入**(deterministic fixtures 的前提)。
// API 源(officialAPI)的態在此完整定義並以 fixtures 驅動;真正的網路 poller 屬 F3+(boundary
// 修訂 #73 已核准、實作另行落地),不在本檔也不在任何 ProviderAdapter 內。

// MARK: - 封閉 enum(契約 §1;絕非自由字串)

/// 資料來源類別(契約 §2 taxonomy)。
public enum SourceKind: String, Codable, Sendable {
    case localLogs        // 本地日誌 scan(現行 ledger 路徑;零網路)
    case officialAPI      // opt-in 官方 API(F3+;#73 已核准、尚未實作)
    case providerCost     // provider 自報成本(opencode session.cost 型)
    case derivedEstimate  // 推導值(pace 等)
}

/// 軸 1:這個來源此刻該不該有資料。優先序 disabled > unavailable > active(契約 §1)。
public enum SourcePresence: Equatable, Codable, Sendable {
    case active
    case unavailable(UnavailableReason)
    case disabled                       // 使用者 toggle off:壓過一切(含未登入)

    public enum UnavailableReason: String, Codable, Sendable {
        case notInstalled               // CLI/來源不存在
        case notLoggedIn                // credential 檔不存在(F3+ 才會出現)
        case noSourceFiles              // 已裝但找不到任何資料檔
    }
}

/// 軸 2:有資料管道時它健不健康(僅 presence == .active 有意義)。
/// 顯示優先序(具體失敗壓過泛化 stale;契約 §3):
/// schemaKilled > authExpired > rateLimited > transientError > stale > ok。
public enum SourceHealth: String, Codable, Sendable, Comparable {
    case ok
    case stale             // 超窗未成功觀測且無具體失敗態(默認降級)
    case transientError    // timeout/DNS/TLS/5xx/invalid-body/檔案壞/未列 HTTP 態(兜底)
    case rateLimited       // 429
    case authExpired       // 401(僅 officialAPI)
    case schemaKilled      // decoder breaking mismatch / 404,410 ×3(僅 officialAPI)

    /// 顯示優先序:值越大越優先蓋台。
    public var displayPriority: Int {
        switch self {
        case .ok: return 0
        case .stale: return 1
        case .transientError: return 2
        case .rateLimited: return 3
        case .authExpired: return 4
        case .schemaKilled: return 5
        }
    }

    public static func < (a: SourceHealth, b: SourceHealth) -> Bool {
        a.displayPriority < b.displayPriority
    }
}

/// 恢復動作(契約 §1;UI 由此映射固定文案,絕不顯示原始錯誤)。
public enum RecoveryAction: Equatable, Codable, Sendable {
    case none
    case reLogin(cli: String)           // 「跑一次 <cli> 任意指令重登」
    case retryLater                     // 退避中/暫時性
    case updateApp                      // schemaKilled:等 app 更新
    case reEnableToggle                 // 使用者關閉;開回即恢復
}

/// 出處註記(契約 §2;封閉 enum,r3 ultra#9)。
public enum ProvenanceNote: String, Codable, Sendable {
    case none
    case sourceNowOff                   // folded 值的採納源事後 disabled/killed(值保留)
    case parseWarnings                  // 成功 scan 但有 unparsable 行(dataQuality 有計數)
    case clockChanged                   // 負 age(觀測或資料時戳超前):時鐘變動(不轉 stale,僅顯示)
    case conflictingSources             // 持續矛盾 flag 起(契約 §2;F1+F2 雙源時消費)
}

// MARK: - 核心狀態

/// 「provider × source」一份;F17 的原子單位(契約 §1)。provider 層只是聚合視圖。
public struct DataSourceStatus: Equatable, Codable, Sendable {
    public var providerId: String
    public var kind: SourceKind
    public var presence: SourcePresence
    public var health: SourceHealth
    public var lastObservedOk: Date?    // 上次成功「觀測」(scan 完成 / API 200);nil = 從未
    public var lastAttemptAt: Date?
    public var newestDataAt: Date?      // 資料本身最新時戳(≠ 觀測時刻;§3 兩層)
    public var attemptCount: Int        // 首次啟用判定用(attempt==0 顯 connecting)
    public var provenanceNote: ProvenanceNote
    public var recoveryAction: RecoveryAction

    public var sourceId: String { providerId + "." + kind.rawValue }

    public init(providerId: String, kind: SourceKind,
                presence: SourcePresence = .active, health: SourceHealth = .ok,
                lastObservedOk: Date? = nil, lastAttemptAt: Date? = nil,
                newestDataAt: Date? = nil, attemptCount: Int = 0,
                provenanceNote: ProvenanceNote = .none,
                recoveryAction: RecoveryAction = .none) {
        self.providerId = providerId
        self.kind = kind
        self.presence = presence
        self.health = health
        self.lastObservedOk = lastObservedOk
        self.lastAttemptAt = lastAttemptAt
        self.newestDataAt = newestDataAt
        self.attemptCount = attemptCount
        self.provenanceNote = provenanceNote
        self.recoveryAction = recoveryAction
    }
}

// MARK: - Freshness 兩層語義(契約 §3)

/// observation freshness(健康判定)與 data age(顯示)是兩個量:idle 使用者 data age 大
/// 但 observation 健康 → 不是 stale;watcher 死了才是 stale。
public enum Freshness {
    /// 遲滯帶(契約 §3):進 stale 於 age > enterFactor×window,出於 age < exitFactor×window。
    public static let staleEnterFactor = 2.2
    public static let staleExitFactor = 1.8

    /// observation age;`lastObservedOk == nil` 不參與 stale 判定(首次啟用規則)。
    /// 負 age(時鐘回撥)→ 回報 .clockChanged,health 不因此轉 stale。
    public struct Assessment: Equatable, Sendable {
        public var isStale: Bool
        public var note: ProvenanceNote   // .clockChanged 或 .none
    }

    public static func assessObservation(lastObservedOk: Date?, window: TimeInterval,
                                         currentlyStale: Bool, now: Date) -> Assessment {
        guard let last = lastObservedOk else {
            return Assessment(isStale: false, note: .none)   // nil 觀測:connecting,非 stale
        }
        let age = now.timeIntervalSince(last)
        if age < 0 { return Assessment(isStale: currentlyStale, note: .clockChanged) }
        if currentlyStale {
            return Assessment(isStale: age >= staleExitFactor * window, note: .none)
        }
        return Assessment(isStale: age > staleEnterFactor * window, note: .none)
    }
}

// MARK: - 狀態機(契約 §5 表格直譯;純函數,事件驅動)

/// 觀測事件:一輪 scan / 一次 API 呼叫的結果(呼叫端把 HTTP/IO 結果翻譯成此封閉集)。
public enum SourceObservationEvent: Equatable, Sendable {
    case success                        // 成功觀測(scan 完成 / HTTP 200 + schema 通過)
    case transportFailure               // timeout/DNS/TLS/5xx/檔壞/redirect/未列態(兜底)
    case invalidBody                    // 回應非法(JSON 壞):×3 連續 → schemaKilled(契約 §5)
    case rateLimited                    // 429
    case authRejected                   // 401
    case schemaBreaking                 // decoder 判 breaking(必要欄位缺/型別錯)→ **立即** kill
    case endpointGone                   // 404/410(×3 → schemaKilled)
}

/// 純函數狀態機:同一 ordered 事件序列 → 決定性結果(契約決定性只對 same ordered sequence)。
public enum SourceHealthMachine {
    /// 連續失敗升級門檻(契約 §5:單次 invalid body 先 transientError,連 3 次同型才 kill;
    /// 404/410 同)。
    public static let killEscalationThreshold = 3

    public struct State: Equatable, Sendable {
        public var health: SourceHealth
        public var consecutiveInvalidBodies: Int
        public var consecutiveGoneFailures: Int

        public init(health: SourceHealth = .ok,
                    consecutiveInvalidBodies: Int = 0, consecutiveGoneFailures: Int = 0) {
            self.health = health
            self.consecutiveInvalidBodies = consecutiveInvalidBodies
            self.consecutiveGoneFailures = consecutiveGoneFailures
        }
    }

    /// 一步轉換(契約 §5;xcheck f17-r1 修正升級路徑):
    /// - `.schemaBreaking`(必要欄位缺/型別錯)→ **立即** schemaKilled(decoder 判定即證據);
    /// - `.invalidBody`(JSON 壞)→ 先 transientError,連續 3 次 → schemaKilled;
    /// - `.endpointGone`(404/410)→ 同 3 連升級。
    /// schemaKilled 是吸收態:離開只經 reactivate()(app 版本變更自動一次 / 手動 re-enable,
    /// 呼叫端負責 toggle-on gate)。
    public static func step(_ s: State, _ e: SourceObservationEvent) -> State {
        var s = s
        if s.health == .schemaKilled { return s }   // 吸收:重試由 reactivate() 顯式發起
        switch e {
        case .success:
            s = State()                              // 任何非吸收態成功 → ok,計數歸零
        case .transportFailure:
            s.health = .transientError
            s.consecutiveInvalidBodies = 0
            s.consecutiveGoneFailures = 0
        case .invalidBody:
            s.consecutiveInvalidBodies += 1
            s.consecutiveGoneFailures = 0
            s.health = s.consecutiveInvalidBodies >= killEscalationThreshold ? .schemaKilled : .transientError
        case .rateLimited:
            s.health = .rateLimited
            s.consecutiveInvalidBodies = 0
            s.consecutiveGoneFailures = 0
        case .authRejected:
            s.health = .authExpired
            s.consecutiveInvalidBodies = 0
            s.consecutiveGoneFailures = 0
        case .schemaBreaking:
            s = State(health: .schemaKilled)         // breaking = 立即 kill(契約 §5)
        case .endpointGone:
            s.consecutiveGoneFailures += 1
            s.consecutiveInvalidBodies = 0
            s.health = s.consecutiveGoneFailures >= killEscalationThreshold ? .schemaKilled : .transientError
        }
        return s
    }

    /// schemaKilled 的顯式重試門(app 版本變更自動一次 / 手動 re-enable;呼叫端負責
    /// toggle-on gate)。契約 §5:「重試一次,再 mismatch 再 kill」—— 探測若仍是
    /// schema 級失敗(breaking / invalid-body / gone)→ **直接回吸收態**(不重新累積);
    /// 其他失敗 → 進對應暫態。
    public static func reactivate(_ s: State, probeResult e: SourceObservationEvent) -> State {
        guard s.health == .schemaKilled else { return step(s, e) }
        switch e {
        case .success:
            return State()
        case .schemaBreaking, .invalidBody:
            return State(health: .schemaKilled,
                         consecutiveInvalidBodies: killEscalationThreshold,
                         consecutiveGoneFailures: 0)
        case .endpointGone:
            return State(health: .schemaKilled,
                         consecutiveInvalidBodies: 0,
                         consecutiveGoneFailures: killEscalationThreshold)
        case .transportFailure, .rateLimited, .authRejected:
            return step(State(), e)
        }
    }
}

/// stale 疊加規則(契約 §3):stale 只在「無具體失敗態」時成立;呼叫端以此合成顯示 health。
public enum HealthDisplay {
    public static func effective(machine: SourceHealth, isStale: Bool) -> SourceHealth {
        if machine != .ok { return machine }        // 具體失敗態壓過 stale
        return isStale ? .stale : .ok
    }

    /// 恢復動作映射(封閉;契約 §1/§5)。
    public static func recovery(for health: SourceHealth, presence: SourcePresence,
                                cli: String) -> RecoveryAction {
        switch presence {
        case .disabled: return .reEnableToggle
        case .unavailable(let r):
            return r == .notLoggedIn ? .reLogin(cli: cli) : .none
        case .active: break
        }
        switch health {
        case .ok, .stale: return .none
        case .transientError, .rateLimited: return .retryLater
        case .authExpired: return .reLogin(cli: cli)
        case .schemaKilled: return .updateApp
        }
    }
}

// MARK: - Conflict flag substrate(契約 §2;雙源持續矛盾)

/// 持續矛盾追蹤(per provider × window)。純值語義、時刻注入;F1+F2 前無真雙源,
/// 邏輯先以 fixtures 釘死。閾值與生命週期照契約 §2:
/// 可比 = 兩源各自最新讀數且 observedAt 相差 ≤30min;pair identity = observedAt 組(去重);
/// 連續 ≥3 輪可比且差 >10pt → 升起;清除 = 3 輪收斂 / 單源撤回 / 兩段式時間過期。
public struct ConflictTracker: Equatable, Codable, Sendable {
    public static let comparabilityWindow: TimeInterval = 30 * 60
    public static let divergencePoints: Double = 10
    public static let roundsToRaise = 3
    public static let roundsToClear = 3

    public private(set) var isRaised: Bool = false
    public private(set) var consecutiveDivergent: Int = 0
    public private(set) var consecutiveConvergent: Int = 0
    public private(set) var lastComparablePairAt: Date?
    /// 已處理配對的高水位(per 邊;xcheck f17-r1:只記上一組會讓 P1→P2→P1 重計,
    /// 且過期 reset 後老 pair 復算)。「新的一輪」= 至少一邊的 observedAt 嚴格前進;
    /// 高水位**永不因 reset 而回退**(舊證據不得復用)。
    private var seenLocalHighwater: Date = .distantPast
    private var seenApiHighwater: Date = .distantPast

    public init() {}

    /// 餵入兩源各自的最新讀數(任一為 nil = 無可比對)。回傳是否構成「新的一輪」。
    @discardableResult
    public mutating func observe(localPercent: Double?, localObservedAt: Date?,
                                 apiPercent: Double?, apiObservedAt: Date?) -> Bool {
        guard let lp = localPercent, let la = localObservedAt,
              let ap = apiPercent, let aa = apiObservedAt,
              abs(la.timeIntervalSince(aa)) <= Self.comparabilityWindow else { return false }
        // pair identity 去重(高水位版;xcheck f17-r2 收緊):**兩邊皆不得回退**且
        // **至少一邊嚴格前進**才構成新一輪 —— 只擋「兩邊都舊」會讓撤回源的老讀數
        // 配上另一邊新讀數重新入證(ultra/sol 反例:withdrawn API@A1 + 新 local)。
        guard la >= seenLocalHighwater, aa >= seenApiHighwater,
              (la > seenLocalHighwater || aa > seenApiHighwater) else { return false }
        seenLocalHighwater = la
        seenApiHighwater = aa
        lastComparablePairAt = max(la, aa)
        if abs(lp - ap) > Self.divergencePoints {
            consecutiveDivergent += 1
            consecutiveConvergent = 0
            if consecutiveDivergent >= Self.roundsToRaise { isRaised = true }
        } else {
            consecutiveConvergent += 1
            consecutiveDivergent = 0
            if isRaised && consecutiveConvergent >= Self.roundsToClear { reset() }
        }
        return true
    }

    /// 單源撤回(presence ≠ .active)→ 清除(單源無矛盾)。
    public mutating func sourceWithdrawn() { reset() }

    /// 兩段式時間過期(契約 §2 + owner 修法):elapsed < 0(時鐘異常)→ 直接 expired;
    /// elapsed ≥ 0 → 與 TTL 比較。**絕不 clamp 成 0 再比**(回撥會偽裝成「剛剛發生」)。
    public mutating func expireIfDue(now: Date, ttl: TimeInterval) {
        guard isRaised || consecutiveDivergent > 0 else { return }
        guard let last = lastComparablePairAt else { return }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 0 { reset(); return }          // 時鐘異常 → 保守清除
        if elapsed > ttl { reset() }
    }

    private mutating func reset() {
        // 高水位刻意**不**清(xcheck f17-r1 sol#3):過期/撤回後,未前進的老 pair
        // 不得作為新證據重新計數。
        isRaised = false
        consecutiveDivergent = 0
        consecutiveConvergent = 0
        lastComparablePairAt = nil
    }
}

// MARK: - planLabel fallback 決策樹(契約 §2;純函數)

/// 契約 §2 planLabel 列的直譯。兩條全域鐵則先行:(0a) schemaKilled 源的直接值不可用;
/// (0b) disabled 源的值一律不用(使用者意志勝)。然後 local 逐級,不行才 API 同規則。
public enum PlanLabelResolver {
    public struct Source: Sendable {
        public var value: String?
        public var health: SourceHealth
        public var presence: SourcePresence
        public var everHadValue: Bool

        public init(value: String?, health: SourceHealth, presence: SourcePresence, everHadValue: Bool) {
            self.value = value
            self.health = health
            self.presence = presence
            self.everHadValue = everHadValue
        }
    }

    public struct Resolution: Equatable, Sendable {
        public enum Origin: Equatable, Sendable { case local, localLastGood, api, apiLastGood }
        public var value: String
        public var origin: Origin
        public var staleMark: Bool

        public init(value: String, origin: Origin, staleMark: Bool) {
            self.value = value
            self.origin = origin
            self.staleMark = staleMark
        }
    }

    public static func resolve(local: Source, api: Source) -> Resolution? {
        candidate(local, direct: .local, lastGood: .localLastGood)
            ?? candidate(api, direct: .api, lastGood: .apiLastGood)
    }

    private static func candidate(_ s: Source, direct: Resolution.Origin,
                                  lastGood: Resolution.Origin) -> Resolution? {
        if s.presence == .disabled { return nil }        // 鐵則 0b:disabled 源之值一律不用
        if s.health == .schemaKilled { return nil }      // 鐵則 0a:killed 直接值不可用
        guard let v = s.value else { return nil }
        switch s.presence {
        case .active:
            switch s.health {
            case .ok: return Resolution(value: v, origin: direct, staleMark: false)
            case .stale: return Resolution(value: v, origin: direct, staleMark: true)
            default:   // 其他失敗態:曾有值 → last-good(不跳源)
                return s.everHadValue ? Resolution(value: v, origin: lastGood, staleMark: true) : nil
            }
        case .unavailable:   // 登出等:曾有值 → last-good
            return s.everHadValue ? Resolution(value: v, origin: lastGood, staleMark: true) : nil
        case .disabled:
            return nil
        }
    }
}

// MARK: - Folded-value provenance 接點(契約 §2)

/// 引擎折疊值的出處:最後造成 folded 值變更那筆 reading 的 (sourceId, observedAt)。
/// LimitEngine 是既有元件;此型別是 F17 的顯示接點,folded 值本身的語義不變
/// (「引擎折疊值」與「源直接值」是兩類;源撤回不隱藏、不降值)。
public struct FoldProvenance: Equatable, Codable, Sendable {
    public var sourceId: String
    public var observedAt: Date
    public var sourceNowOff: Bool       // 採納源事後 disabled/killed → 顯示註記(值保留)

    public init(sourceId: String, observedAt: Date, sourceNowOff: Bool = false) {
        self.sourceId = sourceId
        self.observedAt = observedAt
        self.sourceNowOff = sourceNowOff
    }
}
