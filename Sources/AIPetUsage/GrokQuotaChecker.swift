import Foundation
import Observation
import UsageCore

/// F3 Grok 官方額度監控的 GUI 接線層(opt-in,預設關;純邏輯在 UsageCore.GrokQuota*)。
/// 複刻 OpenRouterCreditsChecker 既審模式;差異只在:credential 門檻(401 後外呼唯一
/// 門檻 = auth 檔 mtime/size/存在性變更或手動 Refresh —— GrokQuotaPolicy)與 F17 狀態機。
/// 邊界(#73 修訂;契約 v5 §4 Grok 列):
///   - 停用 ⇒ 不開檔、不排程、清空狀態、取消進行中請求、丟棄晚到回應(世代守衛)。
///   - token 於**每次抓取時**才從 `~/.grok/auth.json`(`GROK_HOME` 尊重)讀出,narrow
///     decode 僅 `key` 欄;只存在於 fetch 區域範疇。**永不 refresh/寫回**(輪替會弄掉
///     使用者 CLI 登入)。env(`XAI_API_KEY` 等)刻意忽略。
///   - 專用 ephemeral session、拒絕所有 redirect;錯誤映射封閉詞彙,不 log
///     request/response/token。
///   - 15 分鐘輪詢 + 啟用當下 + 手動 Refresh;不掛 FSEvents;sleep/wake 不追補
///     missed polls(loop 醒來走正常節奏,無 burst)。
@MainActor
@Observable
final class GrokQuotaChecker {
    struct Status: Equatable {
        var snapshot: GrokQuotaSnapshot?
        var lastAttemptAt: Date?
        var lastOutcome: GrokQuotaOutcome?
        var health: SourceHealth = .ok
    }

    /// schemaKilled 持久化(契約 §5:kill 記 app 版本;版本變更後自動 probe 一次)。
    /// 由 AppModel 注入 get/set(落 AppSettings);nil = 未 kill。
    var killedAtVersion: (get: () -> String?, set: (String?) -> Void) = ({ nil }, { _ in })

    private(set) var status = Status()

    private var enabled = false
    private var policy = GrokQuotaPolicy()
    private var wasStale = false
    /// toggle off→on = 契約「手動 re-enable」:對 persisted kill 允許一次 probe
    /// (與「重啟後自動凍結」區分;r2 P7)。
    private var pendingManualReenable = false
    /// 429 退避(契約 §5:Retry-After 有效才 honor,cap 4h;無效 → 預設下輪)。
    private var rateLimitedUntil: Date?
    /// 單流 + 世代守衛(shipped 泛用純件;R2/R3 語義沿用:bump 釋放佔用、晚寫丟棄)。
    private var gate = OpenRouterFetchGate()
    private var loopTask: Task<Void, Never>?
    private var manualFetchTask: Task<Void, Never>?
    private static let pollInterval: TimeInterval = 15 * 60

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config, delegate: GrokRedirectBlocker(), delegateQueue: nil)
    }()

    /// 開關唯一入口。`isUserAction = false` 表示 app 啟動 bootstrap(r3 三鏡:啟動也是
    /// off→on,不得誤標成契約的「手動 re-enable」—— 否則 same-version 重啟會 probe 一次
    /// 而非凍結零外呼)。使用者按 toggle 走預設 true。冪等。
    func setEnabled(_ on: Bool, isUserAction: Bool = true) {
        guard on != enabled else { return }
        enabled = on
        gate.bumpGeneration()
        loopTask?.cancel()
        loopTask = nil
        manualFetchTask?.cancel()
        manualFetchTask = nil
        if on {
            pendingManualReenable = isUserAction && killedAtVersion.get() != nil   // 僅使用者 toggle(r3)
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.fetchNow(isManual: false)
                    try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                }
            }
        } else {
            status = Status()          // 清空:停用後 UI 不得殘留額度
            policy = GrokQuotaPolicy() // 門檻/狀態機一併重置(off→on 從乾淨態開始)
        }
    }

    /// 手動 Refresh(僅啟用時;單流:進行中則跳過,不取消 in-flight)。
    func refreshNow() {
        guard enabled, let token = gate.tryBegin() else { return }
        manualFetchTask = Task { await self.fetchNow(isManual: true, claimed: token) }
    }

    /// F17 曝露:Grok 官方額度源的 DataSourceStatus(與 grok-code 的 localLogs 源
    /// **分列**;同 provider、health/freshness/auth 各自獨立 —— owner UI 語義裁示)。
    func dataSourceStatus(now: Date = Date()) -> DataSourceStatus {
        let presence: SourcePresence
        if !enabled {
            presence = .disabled
        } else if case .noKey = status.lastOutcome {
            presence = .unavailable(.notLoggedIn)   // 只有「檔案不存在」= 未登入
        } else {
            presence = .active                       // credentialUnreadable 是 active 軸的暫時失敗
        }
        let window = Self.pollInterval
        let lastOk = status.snapshot?.fetchedAt
        let stale = Freshness.assessObservation(lastObservedOk: lastOk, window: window,
                                                currentlyStale: wasStale, now: now)
        wasStale = stale.isStale   // 遲滯記憶(r1 三鏡:恆 false 會讓帶內回彈)
        let health = HealthDisplay.effective(machine: policy.machine.health, isStale: stale.isStale)
        var note: ProvenanceNote = stale.note
        if note == .none, status.snapshot?.reportedPercentOverflow == true { note = .parseWarnings }
        return DataSourceStatus(
            providerId: "grok-code", kind: .officialAPI,
            presence: presence, health: health,
            lastObservedOk: lastOk, lastAttemptAt: status.lastAttemptAt,
            newestDataAt: lastOk,   // API 源:資料時刻 = 觀測時刻
            attemptCount: status.lastAttemptAt == nil ? 0 : 1,
            provenanceNote: note,
            recoveryAction: HealthDisplay.recovery(for: health, presence: presence, cli: "grok"))
    }

    // MARK: - 抓取

    private func fetchNow(isManual: Bool, claimed: Int? = nil) async {
        let token: Int
        if let claimed {
            token = claimed
        } else {
            guard enabled, let t = gate.tryBegin() else { return }
            token = t
        }
        defer { gate.end(token) }
        guard enabled, gate.shouldCommit(token), !Task.isCancelled else { return }

        // schemaKilled gate(r1 三鏡:kill 後常規 tick 零外呼;離開只經 reactivate ——
        // app 版本變更後自動 probe 一次,或 toggle off→on 的手動 re-enable[policy 已重置])。
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var reactivationProbe = false
        // 重啟 hydrate(r2 P7):persisted kill + in-memory 未 killed(新 policy)——
        // 手動 re-enable(off→on)→ probe 一次;同版本且非手動 → 恢復凍結零外呼;
        // 版本已變 → 自動 probe 一次。
        if policy.machine.health != .schemaKilled, let kv = killedAtVersion.get() {
            if pendingManualReenable {
                reactivationProbe = true
                policy.restoreKilled()          // 讓 reactivate 走吸收態語義
                pendingManualReenable = false
            } else if kv == currentVersion {
                policy.restoreKilled()
                status.health = .schemaKilled   // UI 可見(row 顯 format changed,非 connecting)
                return                          // 同版本:凍結,零外呼
            } else {
                reactivationProbe = true        // 版本變 → 自動一次
                policy.restoreKilled()
            }
        } else if policy.machine.health == .schemaKilled {
            guard killedAtVersion.get() != currentVersion else { return }   // 同版本:凍結,零外呼
            reactivationProbe = true                                        // 版本變 → 自動一次
        }
        // 429 退避 honor(r1 三鏡:恆 15min 不 honor 是違約;手動不 bypass 伺服器意志)
        if let until = rateLimitedUntil, Date() < until { return }

        // 身分捕捉(r1 sol#6 + r2 P6):read 前後各 stat 一次,**一致才確定身分**;
        // 不一致(read 期間輪替)→ statAtFetch = nil → 401 不上門檻,下輪以新檔重試。
        let statBefore = await Task.detached(priority: .utility) { Self.statAuthFile() }.value
        let load = await Task.detached(priority: .utility) { Self.loadKeyResult() }.value
        let statAfter = await Task.detached(priority: .utility) { Self.statAuthFile() }.value
        let stat = statAfter
        let identityStable = statBefore == statAfter
        guard enabled, gate.shouldCommit(token), !Task.isCancelled else { return }
        guard policy.decision(enabled: enabled, currentStat: stat, isManual: isManual || reactivationProbe) == .proceed else { return }
        let attemptAt = Date()

        let outcome: GrokQuotaOutcome?
        switch load {
        case .key(let key): outcome = await performFetch(key: key)
        case .fileMissing:  outcome = .noKey
        case .unreadable:   outcome = .credentialUnreadable
        }

        guard let outcome, !Task.isCancelled, enabled, gate.shouldCommit(token) else { return }
        if reactivationProbe {
            policy.reactivate(probeOutcome: outcome, statAtFetch: identityStable ? stat : nil)
            if policy.machine.health == .schemaKilled {
                killedAtVersion.set(currentVersion)   // 再 mismatch → 以現版本重新凍結
            } else {
                killedAtVersion.set(nil)
            }
        } else {
            policy.apply(outcome: outcome, statAtFetch: identityStable ? stat : nil)
            if policy.machine.health == .schemaKilled {
                killedAtVersion.set(currentVersion)   // 首次 kill:持久化凍結版本
            }
        }
        if case .rateLimited(let ra) = outcome {
            // 驗證:>0 且有限才 honor,cap 4h;無效/缺 → 預設下輪(15min poll 即退避)
            if let ra, ra.isFinite, ra > 0 {
                rateLimitedUntil = Date().addingTimeInterval(min(ra, 4 * 3600))
            } else {
                // 無效/缺 Retry-After → 契約預設退避(r2 P10:清 gate 會讓手動立即重打)
                rateLimitedUntil = Date().addingTimeInterval(Self.pollInterval)
            }
        } else {
            rateLimitedUntil = nil
        }
        var next = status
        next.lastAttemptAt = attemptAt
        next.lastOutcome = outcome
        next.health = policy.machine.health
        switch outcome {
        case .success(let snap):
            next.snapshot = snap
        case .keyRejected, .noKey:
            break   // 契約 §5(r1 三鏡):authExpired / notLoggedIn 曾成功 → 保留 last-good
                    // + as-of + 提示;絕不清掉真實觀測過的值
        case .schemaBreaking:
            next.snapshot = nil   // killed:直接值不顯(契約 §5)
        case .credentialUnreadable, .rateLimited, .invalidBody, .endpointGone,
             .serverError, .badReply, .networkError:
            break                 // 保留舊快照;UI 標示失敗 + as-of
        }
        if policy.machine.health == .schemaKilled { next.snapshot = nil }   // ×3 升級到 kill 也清
        status = next
    }

    private func performFetch(key: String) async -> GrokQuotaOutcome? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let request = GrokQuotaEngine.request(key: key, appVersion: version)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  GrokQuotaEngine.isTrustedResponse(url: http.url) else {
                bytes.task.cancel()
                return .badReply
            }
            // 非 200:status 語義優先,不讀 body(r1 max/sol:>cap 的 401 曾繞過
            // keyRejected → 永不進入 credential block)。
            if http.statusCode != 200 {
                bytes.task.cancel()
                var outcome = GrokQuotaEngine.parseResponse(statusCode: http.statusCode, data: Data(), now: Date())
                if case .rateLimited = outcome {
                    let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    outcome = .rateLimited(retryAfterSeconds: ra)
                }
                return outcome
            }
            var data = Data()
            data.reserveCapacity(1024)
            for try await byte in bytes {
                data.append(byte)
                if data.count > GrokQuotaEngine.maxResponseBytes {
                    bytes.task.cancel()
                    return .badReply
                }
            }
            var outcome = GrokQuotaEngine.parseResponse(statusCode: http.statusCode, data: data, now: Date())
            if case .rateLimited = outcome {
                // Retry-After 有效才帶值(無效/缺 → nil,退避用預設;契約 §5)
                let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                outcome = .rateLimited(retryAfterSeconds: ra)
            }
            return outcome
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return Task.isCancelled ? nil : .networkError   // 非本意的取消是異常,不是無事
        } catch {
            return Task.isCancelled ? nil : .networkError   // 錯誤內文刻意不保留(封閉詞彙)
        }
    }

    // MARK: - auth 檔(每次抓取時 stat/讀;不監看、不快取、永不寫)

    nonisolated static func authFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    nonisolated private static func statAuthFile() -> CredentialChangeGate.FileStat {
        let url = authFileURL()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return CredentialChangeGate.FileStat(mtime: nil, size: nil, exists: false)
        }
        return CredentialChangeGate.FileStat(mtime: attrs[.modificationDate] as? Date,
                                             size: (attrs[.size] as? NSNumber)?.int64Value,
                                             exists: true)
    }

    nonisolated private static func loadKeyResult() -> KeyLoadResult {
        let url = authFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return .fileMissing }
        // 檔在:任何讀取/解碼失敗都是 unreadable(transientError,絕不顯重登;契約 §4)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: GrokKeyParser.maxAuthFileBytes + 1),
              data.count <= GrokKeyParser.maxAuthFileBytes,
              let key = GrokKeyParser.parse(data: data) else { return .unreadable }
        return .key(key)
    }
}

private final class GrokRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        GrokQuotaEngine.redirectDecision()
    }
}
