import Foundation

/// 核心層設定(app 設定的子集,CLI 也能使用)。
public struct CoreSettings: Codable, Sendable {
    public var enabledProviders: Set<String>
    public var warnThresholdPercent: Double
    public var dangerThresholdPercent: Double
    public var staleAfterMinutes: Int
    public var retentionDays: Int
    /// Claude Code 的限額是估算:本機紀錄只有 token 數,百分比需要使用者設定預算基準。
    public var claudeFiveHourTokenBudget: Int?
    public var claudeWeeklyTokenBudget: Int?

    /// App 與 CLI 共用的設定來源:app 寫入的 settings.json 內含 `core` 欄位。
    /// CLI 一律經由此函式讀取,確保預算/閾值/啟用清單與 GUI 一致。
    public static func loadShared(dataDir: URL) -> CoreSettings {
        struct SettingsFile: Codable { var core: CoreSettings? }
        let url = dataDir.appendingPathComponent("settings.json")
        if let file = AtomicJSON.read(SettingsFile.self, from: url), let core = file.core {
            return core
        }
        return CoreSettings()
    }

    // grok-code 預設啟用:未安裝 grok 時 adapter 回報 unavailable,
    // 由既有的 OnboardingCard 呈現「未偵測到」;已存檔的使用者設定不受預設值影響。
    public init(enabledProviders: Set<String> = ["codex", "claude-code", "grok-code"],
                warnThresholdPercent: Double = 80,
                dangerThresholdPercent: Double = 95,
                staleAfterMinutes: Int = 30,
                retentionDays: Int = 92,
                claudeFiveHourTokenBudget: Int? = nil,
                claudeWeeklyTokenBudget: Int? = nil) {
        self.enabledProviders = enabledProviders
        self.warnThresholdPercent = warnThresholdPercent
        self.dangerThresholdPercent = dangerThresholdPercent
        self.staleAfterMinutes = staleAfterMinutes
        self.retentionDays = retentionDays
        self.claudeFiveHourTokenBudget = claudeFiveHourTokenBudget
        self.claudeWeeklyTokenBudget = claudeWeeklyTokenBudget
    }
}

/// 限額引擎:把 provider 回報的 rate-limit 讀值折疊成「provider 全域」狀態。
/// 規則(政策 = docs/DATA_SOURCES.md「Limit calculation policy」):同一限額窗口內,
/// 較舊/較低的來源事件不得拉低已知百分比;向下修正只有三條合法通道 —
/// (a) 窗口翻轉、(b) 全量重建索引、(c) 連續兩筆 observedAt 嚴格遞增且各低於現值
/// 0.5pt 以上的官方讀數(方案升級/後端重算)。(b)(c) 標 `corrected`,僅 surface 24h。
/// **#49 I2 修訂(owner,2026-08-13;supersede 舊「同窗無條件 max」措辭)**:committed
/// observedAt 之前(含 equal)的觀測對 committed value 完全 inert——timestamp 是唯一
/// mutation authority,任何方向皆然;fullReindex 為重建授權例外。此使 crash/watermark-loss
/// 後的 replay 冪等(不重抬、不重發 crossings)。
public final class LimitEngine {

    struct PercentSample: Codable, Equatable {
        var at: Date
        var percent: Double
    }

    /// 換窗候選:窗口翻轉需連續兩筆同窗讀數確認(見 fold);跨批次/重啟持久化。
    struct PendingWindow: Codable, Equatable {
        var percent: Double
        var resetsAt: Date?
        var observedAt: Date
        var windowMinutes: Int
        var count: Int
    }

    /// 同窗「向下修正」候選(與換窗候選 `pending` 各司其職,互不相涉):
    /// 官方同窗讀數持續走低(方案升級/後端重算)需連續兩筆 observedAt 嚴格遞增確認,
    /// 單筆抖低不得下修(重放同樣被 observedAt 規則擋下)。
    struct PendingDecrease: Codable, Equatable {
        var percent: Double
        var observedAt: Date
        var count: Int
    }

    struct PersistedWindow: Codable, Equatable {
        var percent: Double
        var resetsAt: Date?
        var observedAt: Date
        var windowMinutes: Int
        var corrected: Bool
        var expiryHandled: Bool
        var history: [PercentSample]
        /// 舊版 state 檔沒有此欄位 → 解碼為 nil。
        var pending: PendingWindow? = nil
        /// 同窗下修候選/時點/原因(v0.1 alpha 後新增;舊 state 檔解碼為 nil)。
        var pendingDecrease: PendingDecrease? = nil
        var correctedAt: Date? = nil
        var correctedReason: CorrectionReason? = nil
    }

    struct PersistedProvider: Codable, Equatable {
        var primary: PersistedWindow?
        var secondary: PersistedWindow?
        var planType: String?
        // Claude 估算窗口的重置偵測狀態
        var estimatedBlockEnd: Date?
        var estimatedBlockTokens: Int?
        var estimatedResetHandled: Bool?
        /// #83 G2(r3 ACCEPT):estimated reset 實際**交付**時的 boundary(blockEnd)。與
        /// `estimatedResetHandled`(處理 marker——閘壓下也會設)區分:同一 logical boundary 的
        /// 單一 delivery identity 需要「已交付」證據,handled 不足以判別。sweep 讀側據此抑制
        /// 同 boundary 的遲到 official 重發;suppressed(handled 而未交付)不抑制。舊檔解碼 nil。
        var estimatedResetDeliveredAt: Date? = nil
        /// Codex 5h「消失」時點(週-only 快照的 observedAt)。不新於此的殘留 5h 讀數(如封存
        /// session 檔以新路徑被重掃重放)不得復活已凍結的 5h 槽。舊 state 檔解碼為 nil。
        var codexFiveHourAbsentSince: Date? = nil
        /// #83 A′ R1/R2:本 provider 的 reconciliation generation——只隨「該 provider 一次成功
        /// durable commit 的 scan-consuming reconciliation」推進(R2);derived write 與他 provider
        /// 的 commit 不得推進(R1)。full reconciliation 即使 logical unchanged 也建立新 generation
        ///(R3,failed-full 與 succeeded-unchanged-full 的 durable 判別)。舊 state 檔解碼為 nil
        /// = unestablished reconciliation identity(migration:首個 reconciliation 建立)。
        var reconcileGeneration: UInt64? = nil
    }

    private var store: [String: PersistedProvider]
    private let stateURL: URL?
    /// #83 A′:讀取 provider 的 reconciliation generation(coordinator restart 判定 + 測試觀察)。
    func reconcileGeneration(for providerId: String) -> UInt64? {
        store[providerId]?.reconcileGeneration
    }
    /// 非 nil 表示 limits-state 檔存在但讀不到 / 損壞;coordinator 見此中止本輪寫入,不覆寫(#44 契約 A)。
    public private(set) var loadError: Error?
    /// #49 R3:derived-state(sweep/estimatedBlock)持久化失敗的可觀測旗標——loud-but-nonblocking,
    /// coordinator 讀後入 refreshQualityNotes;絕不 retroactively 否定已 durable 的 provider ingest,
    /// 絕不擋 watermark(derived 可由 durable ledger/limits 重算)。每次 derived 寫入起始清空。
    public private(set) var derivedSaveError: Error?
    /// #49 R5/P5:durability syscalls(同 #64 DP-3:per-instance 不可變、public init 針 production、
    /// internal init 供 @testable 注入;直接 reuse #64 的 DurabilityOps —— 不抽泛型 persistence)。
    private let durabilityOps: DurabilityOps
    /// #49 I1(durability provenance):本 process 內經**成功完整 barrier** 寫出的 store bytes 身分。
    /// load/reload 讀到相同 bytes ⇒ 維持 confirmed;不同/缺席(含 process 起始)⇒ UNCONFIRMED;
    /// C7c(post-rename outcome-unknown)⇒ 清 nil。invariant:UNCONFIRMED generation 的 .unchanged
    /// 必須先補一次 durable no-op save,成功才得回 .unchanged(watermark 才可據以前進)——
    /// 這是 LimitEngine 版的 #64 reconciliation,身分比對用「我們自己 encode 的內容」,不需指紋架構。
    private var confirmedStateBlob: Data?

    public convenience init(stateURL: URL?) {
        self.init(stateURL: stateURL, durabilityOps: .production)
    }

    /// internal(tests-only via `@testable`):注入 barrier 失敗排程用。
    init(stateURL: URL?, durabilityOps: DurabilityOps) {
        self.durabilityOps = durabilityOps
        self.stateURL = stateURL
        if let stateURL {
            do {
                store = try AtomicJSON.readOrThrow([String: PersistedProvider].self, from: stateURL) ?? [:]
            } catch {
                store = [:]
                loadError = error
            }
        } else {
            store = [:]
        }
        // I1:process 起始一律 UNCONFIRMED(confirmedStateBlob 初始 nil)——載入的檔可邏輯使用,
        // 但其 durability 未在本 process 證實,首個 .unchanged 前必先 no-op durable confirm。
        // 載入即清理「窗型錯置」的持久化窗口(見 sanitizeCrossTypedWindows)。init 只在記憶體
        // 清理、不寫檔——維持 aipet status/report 唯讀契約;清淨值於下次 ingest 才落地。
        sanitizeCrossTypedWindows()
    }

    /// #49 amendment(owner R3 修訂):**同一 authoritative state file 只允許一種 durable
    /// replacement primitive** —— derived 與 scan-consuming 的差異只留在 failure CONSEQUENCE
    ///(derived 失敗:不倒退 watermark、不 retroactively 否定已 durable 的 ingest、loud、下輪重算),
    /// 寫檔強度不再 asymmetry(弱寫會把 scan path 剛建立的 durability 重新抹掉)。
    /// cycle-accumulate:first error 保留至 coordinator 明確 cycle reset,不被後續成功寫清除。
    func clearDerivedFailure() { derivedSaveError = nil }

    private func recordDerivedFailure(_ error: Error) {
        if derivedSaveError == nil { derivedSaveError = error }
    }

    /// #49 R5:scan-consuming durable commit——temp(O_EXCL,write-all)→ F_FULLFSYNC → rename →
    /// parent-dir fsync;任何 barrier 失敗(含 ENOTSUP)= throw,不降級(#64 DP-1 verbatim)。
    /// 本地最小實作:#64 的 UsageLedger helper 綁著 fingerprint 捕捉語義,limits 無指紋機制,
    /// 故只 reuse `DurabilityOps` syscall contract,不搬 helper、不抽 DurableStore(owner 界線)。
    private func saveDurably() throws {
        guard let stateURL else { return }
        guard loadError == nil else { throw StateReadError.unreadable(underlying: loadError!) }
        let blob = try AtomicJSON.encoder().encode(store)
        let parent = stateURL.deletingLastPathComponent()
        try AppPaths.ensureDirectory(parent)
        let tempURL = parent.appendingPathComponent(".\(stateURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var wrote = 0
        let total = blob.count
        var writeErrno: Int32 = 0
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while wrote < total {
                let n = write(fd, raw.baseAddress!.advanced(by: wrote), total - wrote)
                if n > 0 { wrote += n; continue }
                if n < 0 && errno == EINTR { continue }
                writeErrno = (n < 0) ? errno : EIO
                return
            }
        }
        guard wrote == total else {
            close(fd); unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(writeErrno))
        }
        guard durabilityOps.syncFile(fd) == 0 else {
            let err = errno; close(fd); unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        close(fd)
        guard durabilityOps.renameFile(tempURL.path, stateURL.path) == 0 else {
            let err = errno; unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        // post-rename dir-fsync 失敗 = durability outcome unknown({old|new} 皆可能 durable):
        // 不 unlink、不回滾;throw 令 ingest 回 .failed ⇒ watermark 不推;I1:confirmed 身分清空
        //(下一個 would-be-.unchanged 會被迫補 barrier,S1 的 laundering 路徑就此關閉)。
        guard durabilityOps.syncDirectory(parent.path) == 0 else {
            confirmedStateBlob = nil
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        confirmedStateBlob = blob   // I1:完整 barrier 成功 ⇒ 此內容在本 process 為 durability-confirmed
    }

    /// 其他行程可能已寫入較新的限額狀態;寫入階段開始前重新載入以收斂。
    /// 非破壞式:讀不到/損壞時保留現有記憶體並設 loadError(coordinator 中止本輪,不覆寫)。
    public func reloadFromDisk() {
        guard let stateURL else { return }
        // I1:以 raw bytes 做 durability-provenance 身分比對(decode 前);與本 process 上次成功
        // barrier 寫出的 blob 相同 ⇒ 維持 confirmed,否則(他方寫入/未知來源)⇒ UNCONFIRMED。
        let raw: Data
        do {
            raw = try Data(contentsOf: stateURL)
        } catch {
            if AtomicJSON.pathIsGenuinelyMissing(stateURL.path) {
                store = [:]        // R2-MF7:檔案不存在 → 磁碟真相為空,整份採用
                loadError = nil
                confirmedStateBlob = nil
            } else {
                loadError = error   // 讀不到 → 不動記憶體(#44 契約 A)
            }
            return
        }
        do {
            let loaded = try AtomicJSON.decoder().decode([String: PersistedProvider].self, from: raw)
            store = loaded
            loadError = nil
            if raw != confirmedStateBlob { confirmedStateBlob = nil }
            // #83 G1(r3 ACCEPT):sanitize 改動 store ⇒ 記憶體已偏離磁碟 bytes,durability
            // confirmation 必須一併失效——否則後續 would-be-.unchanged 不補 barrier,sanitized
            // 內容未 durable 而 watermark 前進(watermark-never-leads violation)。
            if sanitizeCrossTypedWindows() { confirmedStateBlob = nil }   // 清淨值於接續的 ingest→save 落地(此處不獨立寫檔)
        } catch {
            loadError = error   // 損壞 → 不動記憶體
        }
    }

    /// 清理「窗型錯置」的持久化窗口:primary 槽存的必是「正規化 5h 窗」(window_minutes=300)、
    /// secondary 槽必是「正規化週窗」(=10080)——此為所有 adapter 共用的 RateLimitReading 契約
    /// (見 Models.RateLimitReading)。舊版 CodexAdapter 曾以 JSON 位置(而非 window_minutes)
    /// 歸位,把週窗口(10080)寫進 5h 槽 → UI 顯示「5-hour window resets in Nd Nh」。以「精確窗長」
    /// (fail-closed,與 CodexAdapter.classifyWindows 一致)丟棄任何非 300 的 primary、非 10080 的
    /// secondary:一次性治癒既有污染,並防止未來未知/新窗長(0/60/1440/43200…)被塞進寫死
    /// 「5h/weekly」標籤的槽位而誤標。只在記憶體修改、不在此寫檔(下一次 ingest 才落地)——保住
    /// CLI 唯讀。Claude(300/10080)天然保留;Grok(無窗)不受影響。
    @discardableResult
    private func sanitizeCrossTypedWindows() -> Bool {
        var anyChanged = false
        for (id, var provider) in store {
            var changed = false
            if let p = provider.primary, p.windowMinutes != 300 {
                // 對 Codex 一併記錄消失時點(= 被丟棄的錯置 5h 之 observedAt),與 ingest tombstone 一致,
                // 使遷移後被重掃重放的舊 5h(observedAt ≤ 該時點)不得復活已凍結的 5h 槽。
                if id == "codex" {
                    provider.codexFiveHourAbsentSince = max(provider.codexFiveHourAbsentSince ?? .distantPast, p.observedAt)
                }
                provider.primary = nil; changed = true
            }
            if let s = provider.secondary, s.windowMinutes != 10080 { provider.secondary = nil; changed = true }
            if changed { store[id] = provider; anyChanged = true }
        }
        return anyChanged
    }

    // MARK: - 讀值折疊

    /// 併入新的 rate-limit 讀值,回傳觸發的轉變(重置/跨閾值/耗盡)。
    ///
    /// `now`:重置「慶祝/通知」新鮮度閘(resetRecency)所比對的當下時刻。**正式呼叫端
    /// (UsageCoordinator)一律傳真實 now**;nil(測試/重放便利)= 以本批最新讀數的
    /// observedAt+1s 視為當下 —— 即「讀數被即時處理」的語義,fold 邏輯本身照常受測。
    /// app 關閉跨過翻轉、重開後才掃到的舊翻轉證據(observedAt 距 now 太遠)只默默採納
    /// 新窗,不得再說「剛剛重置」(grok SEV1 round-2:ingest 先於 sweep,重開時新讀數
    /// 已在磁碟上 → fold 是補發陳舊慶祝的主要路徑,不是罕見邊角)。
    /// #49 owner contract:scan-consuming ingest 的三態結果——watermark 推進與否由此定,
    /// 比裸 throws 更能釘死 join contract(「全 replay duplicate」不因未寫檔而被當 failure)。
    public enum IngestResult {
        /// replay/no-op 未改變 durable logical state → 無需重寫 → watermark 可前進。
        case unchanged
        /// state 已變且 durable save 成功 → watermark 可前進 → transitions 可交付。
        case committed([LimitTransition])
        /// durable commit 未成立 / outcome unknown → watermark 不可前進 → provider error 可觀測。
        /// 顯式決策(reviewable):本輪已生成的 transitions **不交付**——寧丟一次通知,不發
        /// 「durable 未記」的假一致;replay 收斂後(fold 單調)該 crossing 不再重發。
        case failed(Error)
    }

    /// `reconcilingProvider`:#83 A′ —— 本次 scan-consuming reconciliation 的主體 provider;
    /// bump 規則表據此推進該 provider 的 reconcileGeneration(R1/R2/R3)。production(coordinator)
    /// 必傳;nil 僅供既有測試 shim 相容 = 不建立/不推進 generation。readings 混入他 provider
    /// 屬 adapter contract violation(fold 照舊,generation 只動主體)。
    public func ingest(readings: [RateLimitReading], settings: CoreSettings, fullReindex: Bool = false,
                       now: Date? = nil, reconcilingProvider: String? = nil) -> IngestResult {
        var transitions: [LimitTransition] = []
        let sorted = readings.sorted { $0.observedAt < $1.observedAt }
        // #49 amendment(owner):candidate/publish-on-commit —— fold 在整份值語義 snapshot 的
        // 「候選」上進行(Swift dict COW,便宜);.failed ⇒ 整份還原 = FAILED 必須讓 authoritative
        // in-memory 狀態與 pre-call **觀測等價**(整份 swap 是可證明的 exact snapshot-restore,
        // 無逐欄 rollback 漏欄風險)。UNCHANGED = 候選 == pre-call authoritative(在
        // publish-on-commit 紀律下 authoritative 恆為 last-durable-or-pre-call)。
        let backup = store
        let effectiveNow = now ?? sorted.last.map { $0.observedAt.addingTimeInterval(1) } ?? Date()
        for reading in sorted {
            var provider = store[reading.providerId] ?? PersistedProvider()
            // #83 W3(clearing-2):full-reindex temporal exemption 是 **provider-scoped** 授權——
            // 只有 reconciling 主體的讀數得到 full fold;同批混入的他 provider 讀數(contract-
            // violation 防禦域)維持 ordinary temporal authority,不得改寫 established state /
            // 重放 crossings。subject nil(測試 shim)保留批次級舊語義。
            let readingFull = fullReindex
                && (reconcilingProvider == nil || reading.providerId == reconcilingProvider)
            if let plan = reading.planType { provider.planType = plan }
            if let w = reading.primary {
                // Codex 5h tombstone 之持久化(見下方 codexFiveHourAbsentSince):不新於「5h 已消失」
                // 時點的殘留 5h 讀數(如已封存 session 檔以新路徑被重掃重放)不得復活已凍結的 5h 槽;
                // 較新的合法 5h 讀數(Codex 恢復 5h)則正常折疊並解除凍結。
                if reading.providerId == "codex", let absent = provider.codexFiveHourAbsentSince,
                   reading.observedAt <= absent {
                    // 略過:過期殘留,不得復活已凍結的 5h
                } else {
                    provider.primary = fold(window: provider.primary, reading: w, observedAt: reading.observedAt,
                                            providerId: reading.providerId, windowName: "5h",
                                            settings: settings, fullReindex: readingFull, now: effectiveNow,
                                            estimatedResetDeliveredAt: provider.estimatedResetDeliveredAt,
                                            transitions: &transitions)
                    if reading.providerId == "codex" { provider.codexFiveHourAbsentSince = nil }
                }
            }
            if let w = reading.secondary {
                provider.secondary = fold(window: provider.secondary, reading: w, observedAt: reading.observedAt,
                                          providerId: reading.providerId, windowName: "weekly",
                                          settings: settings, fullReindex: readingFull, now: effectiveNow,
                                          transitions: &transitions)
            }
            // Codex 的每筆 rate_limits 是完整快照:若回報了「週」窗卻沒有「5h」窗,代表 5h 此刻不存在
            // (如 Codex 暫撤 5h)→ 清掉 5h 槽(tombstone)並記錄消失時點,而非沿用舊值 ghost —— 連
            // full reindex 或封存重放也保持凍結,不再冒出 0% 環。僅在此讀數不舊於現任 5h 時才清。
            // 反向「有 5h 無週」屬 primary-only 部分更新(testPrimaryOnlyReadingsDoNotDisturbStaleWeekly),
            // 保留舊週值,不 tombstone 週槽。僅限 Codex(原子快照);Claude 分窗讀數與 plan-only 不受影響。
            if reading.providerId == "codex", reading.primary == nil, reading.secondary != nil,
               reading.observedAt >= (provider.primary?.observedAt ?? .distantPast) {
                provider.primary = nil
                // 只前進不倒退:亂序遲到的較舊週-only 快照不得把消失時點拉回而讓中間的殘留 5h 復活。
                provider.codexFiveHourAbsentSince = max(provider.codexFiveHourAbsentSince ?? .distantPast, reading.observedAt)
            }
            store[reading.providerId] = provider
        }
        // #83 A′ bump 規則表(PLAN-v2 §3.3;窮舉、無 runtime 裁量):
        //   changed commit             ⇒ gen++(R2)
        //   full 完成(即使 unchanged) ⇒ gen++(R3;blob 因此已變 ⇒ .committed([]),§4-e)
        //   首次(gen 缺席)之 unchanged ⇒ 建立 gen=1(migration:與 proto-I1 no-op confirm 同一 barrier)
        //   ordinary unchanged(已建立)⇒ 不 bump;confirmed 則零寫入
        //   subject nil(測試 shim 相容)⇒ generation 完全不動
        func bumpGeneration(_ s: String) {
            var p = store[s] ?? PersistedProvider()
            p.reconcileGeneration = (p.reconcileGeneration ?? 0) + 1
            store[s] = p
        }
        if store == backup {
            if let s = reconcilingProvider,
               fullReindex || store[s]?.reconcileGeneration == nil {
                // R3(full-unchanged 仍建 identity)或首次建立:進 durable-change 路徑。
                bumpGeneration(s)
                do { try saveDurably() } catch {
                    store = backup   // FAILED 純度:bump 一併回捲
                    return .failed(error)
                }
                return .committed(transitions)   // transitions 必空(store==backup);gen++ ⇒ 非 .unchanged
            }
            // I1:generation UNCONFIRMED(process 起始/他方寫入/C7c 之後)⇒ 先補一次 durable
            // no-op save;只有它成功才得回 .unchanged(否則 .failed,watermark 不得前進)。
            // A′:同 identity 的 re-confirm 不是新 reconciliation ⇒ 不 bump(bump 表列 3)。
            if confirmedStateBlob == nil, stateURL != nil {
                do { try saveDurably() } catch {
                    store = backup   // 內容本就相等;僅為對稱與未來安全
                    return .failed(error)
                }
            }
            return .unchanged   // replay/no-op:durable 已確認,watermark 可安全追上(row 6/10)
        }
        // #83 U5(R1/R2 粒度收斂)+ W4(clearing-2):bump/establish 規則(owner)——
        //   subject slice changed ∨ generation missing ∨ successful full 需 completion identity
        //   ⇒ bump 主體;unrelated provider / derived 變化永不 bump 主體。
        // gen-missing 腿:identity establishment 獨立於 reading mutation——否則他 provider 混入
        // 的 changed 讀數會令本次 durable commit 通過而主體 watermark 先於 identity 前進。
        if let s = reconcilingProvider,
           fullReindex || store[s] != backup[s] || store[s]?.reconcileGeneration == nil {
            bumpGeneration(s)
        }
        do {
            try saveDurably()
            return .committed(transitions)   // durable 成立 → publish(已在)→ transitions 可交付
        } catch {
            store = backup   // FAILED 純度(owner):authoritative memory 觀測等價於 pre-call
            return .failed(error)
        }
    }

    /// tests-only shim(@testable;production 一律走三態 `ingest`):展開三態為 transitions,
    /// 供既有測試延用;`.failed` 直接 fatalError——測試環境的 save 不應失敗。
    func ingestTransitions(readings: [RateLimitReading], settings: CoreSettings,
                           fullReindex: Bool = false, now: Date? = nil,
                           reconcilingProvider: String? = nil) -> [LimitTransition] {
        switch ingest(readings: readings, settings: settings, fullReindex: fullReindex, now: now,
                      reconcilingProvider: reconcilingProvider) {
        case .unchanged: return []
        case .committed(let t): return t
        case .failed(let e): fatalError("test-shim ingest failed: \(e)")
        }
    }

    /// #83 U3/G2 shared boundary predicate——sweep 與 fold 的**全部** official-reset 發射點共用
    /// 唯一規則:同一 logical 5h reset boundary 已由 estimated 路徑「交付」⇒ official 重複不發;
    /// handled-but-not-delivered 絕不抑制(delivered 語義純淨,由 `estimatedResetDeliveredAt`
    /// 專載)。tolerance = resetRecency(owner 2026-08-14:5h 窗結構排除同窗第二真 boundary 的
    /// false-positive;SEV1 真實形態 estimated↔official 可差十餘分鐘,120s 會令修復失效)。
    static func estimatedAlreadyDeliveredSameBoundary(deliveredAt: Date?, windowName: String,
                                                      boundary: Date?) -> Bool {
        guard windowName == "5h", let d = deliveredAt, let b = boundary else { return false }
        return abs(b.timeIntervalSince(d)) <= resetRecency
    }

    private func fold(window stored: PersistedWindow?, reading: RateLimitWindowReading, observedAt: Date,
                      providerId: String, windowName: String, settings: CoreSettings,
                      fullReindex: Bool, now: Date, estimatedResetDeliveredAt: Date? = nil,
                      transitions: inout [LimitTransition]) -> PersistedWindow {
        // 翻轉證據(本讀數)距當下太久 → 狀態照常採納,但不得發「剛剛重置」的慶祝/通知。
        let rolloverIsFresh = now.timeIntervalSince(observedAt) <= Self.resetRecency
        guard var current = stored else {
            return PersistedWindow(percent: reading.usedPercent, resetsAt: reading.resetsAt,
                                   observedAt: observedAt, windowMinutes: reading.windowMinutes,
                                   corrected: false, expiryHandled: false,
                                   history: [PercentSample(at: observedAt, percent: reading.usedPercent)])
        }

        let sameWindow = isSameWindow(current.resetsAt, reading.resetsAt)
        let looksLikeNilRollover = current.resetsAt == nil && reading.resetsAt == nil
            && reading.usedPercent < current.percent - 20

        if sameWindow && !looksLikeNilRollover {
            // 只有「晚於候選最後觀測」的現任讀數才能證明現任在候選之後仍存活 →
            // 候選作廢;亂序/重放的較舊現任讀數不得打斷進行中的確認。
            if let p = current.pending, observedAt > p.observedAt { current.pending = nil }
            let previous = current.percent
            if !fullReindex, observedAt <= current.observedAt {
                // #49 I2(supersede #44「同窗無條件 max」的 monotonic-guard 措辭):committed
                // observedAt 之前(**含 equal**,owner 拍板不用 max tie-break)的觀測不得 mutate
                // committed value —— timestamp 是唯一 mutation authority;這使 decrease-ending
                // batch 的 replay 冪等(S2:[90@t1,30@t2,29@t3] commit 後,90@t1 不得抬回)。
                // 完全 inert:不動 percent/resetsAt/windowMinutes/observedAt/history
                //(與 testOldObservationsAreFullyInert 同向;fullReindex 為重建授權,不受此 gate)。
                return current
            }
            if fullReindex {
                current.corrected = reading.usedPercent < previous - 0.5
                if current.corrected {
                    current.correctedAt = observedAt
                    current.correctedReason = .reindex
                } else {
                    current.correctedAt = nil
                    current.correctedReason = nil
                }
                current.percent = reading.usedPercent
                current.pendingDecrease = nil
            } else if reading.usedPercent < previous - 0.5, observedAt > current.observedAt {
                // 同窗官方下修(方案升級/後端重算)需連續兩筆 observedAt 嚴格遞增的
                // 較低讀數確認;期間 percent 與 observedAt 皆凍結(單調防護照舊),
                // 重放(observedAt 未前進)不可自我確認。第二筆採「最新值」——
                // 兩筆間的小幅回升(60→45.0→45.4)仍屬同一次下修事件。
                if var p = current.pendingDecrease {
                    if observedAt > p.observedAt {
                        p.percent = reading.usedPercent
                        p.observedAt = observedAt
                        p.count += 1
                        if p.count >= 2 {
                            current.percent = reading.usedPercent
                            current.corrected = true
                            current.correctedAt = observedAt
                            current.correctedReason = .official
                            current.observedAt = observedAt
                            current.pendingDecrease = nil
                            current.history.append(PercentSample(at: observedAt, percent: reading.usedPercent))
                            if current.history.count > 48 { current.history.removeFirst(current.history.count - 48) }
                        } else {
                            current.pendingDecrease = p
                        }
                    }
                } else {
                    current.pendingDecrease = PendingDecrease(percent: reading.usedPercent,
                                                              observedAt: observedAt, count: 1)
                }
                if let r = reading.resetsAt { current.resetsAt = r }
                if reading.windowMinutes > 0 { current.windowMinutes = reading.windowMinutes }
                return current
            } else {
                // 單調防護:同窗口內只允許上升(舊面板不得覆蓋新聚合值)。
                // ≈同值/上升讀數要「晚於候選最後觀測」才能作廢下修候選 —— 亂序遲到的
                // 高值讀數(觀測時間早於候選)無法反證候選之後的狀態(與換窗 pending 同律)。
                current.percent = max(previous, reading.usedPercent)
                if let p = current.pendingDecrease, observedAt > p.observedAt {
                    current.pendingDecrease = nil
                }
            }
            current.observedAt = max(current.observedAt, observedAt)
            if let r = reading.resetsAt { current.resetsAt = r }
            if reading.windowMinutes > 0 { current.windowMinutes = reading.windowMinutes }
            if current.percent > previous {
                appendCrossings(previous: previous, now: current.percent, providerId: providerId,
                                windowName: windowName, settings: settings, transitions: &transitions)
            }
            if current.history.last?.percent != current.percent {
                current.history.append(PercentSample(at: observedAt, percent: current.percent))
                if current.history.count > 48 { current.history.removeFirst(current.history.count - 48) }
            }
            return current
        }

        // #83 U3:三個 fold 發射點與 sweep 共用同一 boundary predicate(舊窗邊界 = 本次翻轉的
        // logical boundary;estimated 已交付同 boundary ⇒ 抑制 official 重複)。
        // #83 W2(clearing-2):nil-resetsAt 窗(nil-reset 來源 / 未建邊界)以 observedAt 為
        // logical reset 時點 fallback——「deliveredAt ↔ official observedAt 在既有 recency 窗內
        // 判同一 logical reset」(owner;15 分鐘窗維持)。engine 級防禦,不依賴 per-provider 假設。
        let boundaryAlreadyDelivered = Self.estimatedAlreadyDeliveredSameBoundary(
            deliveredAt: estimatedResetDeliveredAt, windowName: windowName,
            boundary: current.resetsAt ?? observedAt)
        if looksLikeNilRollover {
            // nil-reset 來源沒有 resetsAt 可比對窗口身分,維持既有行為:>20 點驟降即視為翻轉;
            // G2/W2 的 delivery-identity 比對以 observedAt 為 logical reset 時點(上方 fallback)。
            guard observedAt > current.observedAt else { return current }
            if current.percent >= 30, reading.usedPercent < current.percent - 20, !current.expiryHandled,
               rolloverIsFresh, !boundaryAlreadyDelivered {
                transitions.append(.reset(providerId: providerId, window: windowName, estimated: false))
            }
            return PersistedWindow(percent: reading.usedPercent, resetsAt: reading.resetsAt,
                                   observedAt: observedAt, windowMinutes: reading.windowMinutes,
                                   corrected: false, expiryHandled: false,
                                   history: [PercentSample(at: observedAt, percent: reading.usedPercent)])
        }

        // 窗口不同(resets_at 相差 ≥120s)。後端偶發「假重置」抖動:單筆讀數宣稱窗口
        // 剛重置(used≈0、resets_at 更晚),數秒後回滾 — 故不能以「resets_at 較晚者勝」
        // 仲裁(最後一次抖動會永久佔住槽位、擋掉之後所有真讀數)。改為:
        //   1) 只考慮不舊於現任觀測的讀數(重掃舊檔天然被擋);
        //   2) 觀測當下已過期的「新窗口」必為殘留資料,不採信;
        //   3) 換窗需連續兩筆同窗讀數確認(pending 持久化,可跨批次/重啟累計);
        //   4) 現任窗口一旦有新讀數即作廢候選(見上方同窗分支)。
        guard observedAt >= current.observedAt else { return current }
        if let candidateReset = reading.resetsAt, candidateReset <= observedAt { return current }

        // 換窗需兩筆確認的唯一情境:現任窗口「可證明存活」(有具體 resets_at 且尚未到期)
        // 卻收到不同窗讀數 — 這正是後端抖動的形態。其餘情況維持原有的第一筆即接管:
        // 現任已過期 = 預期中的翻轉(hook 恢復不必多等一筆);現任無 resets_at = 無從
        // 證明存活,snapshot 型來源(如 statusline 落地檔)可能長時間不產生第二筆新觀測。
        // 若抖動恰在這些間隙搶佔,佔位窗隨即成為「可證明存活」的現任,真讀數兩筆內
        // 即可換回,不會如舊制永久卡死。
        let incumbentProvablyLive = current.resetsAt.map { $0 > observedAt } ?? false
        if !incumbentProvablyLive {
            if current.percent >= 30, reading.usedPercent < current.percent - 20, !current.expiryHandled,
               rolloverIsFresh, !boundaryAlreadyDelivered {   // U3:shared boundary predicate
                transitions.append(.reset(providerId: providerId, window: windowName, estimated: false))
            }
            return PersistedWindow(percent: reading.usedPercent, resetsAt: reading.resetsAt,
                                   observedAt: observedAt, windowMinutes: reading.windowMinutes,
                                   corrected: false, expiryHandled: false,
                                   history: [PercentSample(at: observedAt, percent: reading.usedPercent)])
        }

        // 現任窗口可證明存活卻收到「不同窗」讀數:抖動的唯一形態 → 需兩筆確認。
        //
        // 刻意「不」要求候選的 resets_at 晚於現任(舊制的 b > a):抖動窗的 resets_at
        // 永遠較晚(觀測時刻+整窗長),若要求較晚才可接管,抖動一旦搶佔成功,真實窗
        // (resets_at 較早)就永遠無法奪回 — 這正是本次修正的原始事故。反向風險
        // (殘留來源把存活現任回滾到較早窗)被兩道既有防線壓低:現任只要再發聲一筆
        // 就作廢候選,且萬一誤接管,真實窗同樣兩筆內奪回,不會永久卡死。
        if var p = current.pending, isSameWindow(p.resetsAt, reading.resetsAt) {
            // 同一筆讀數的重放(observedAt 未前進)不得自我確認。
            guard observedAt > p.observedAt else { return current }
            p.count += 1
            // 候選窗內同樣適用單調防護:亂序的較低樣本不得拉低接管值。
            p.percent = max(p.percent, reading.usedPercent)
            p.resetsAt = reading.resetsAt
            p.observedAt = observedAt
            if reading.windowMinutes > 0 { p.windowMinutes = reading.windowMinutes }
            if p.count >= 2 {
                // 已確認換窗。expiryHandled 表示 sweepExpiredWindows 已為此窗發過重置,不重複。
                if current.percent >= 30, p.percent < current.percent - 20, !current.expiryHandled,
                   rolloverIsFresh, !boundaryAlreadyDelivered {   // U3:shared boundary predicate
                    transitions.append(.reset(providerId: providerId, window: windowName, estimated: false))
                }
                return PersistedWindow(percent: p.percent, resetsAt: p.resetsAt,
                                       observedAt: p.observedAt, windowMinutes: p.windowMinutes,
                                       corrected: false, expiryHandled: false,
                                       history: [PercentSample(at: p.observedAt, percent: p.percent)])
            }
            current.pending = p
            return current
        }

        // 新候選(尚無 pending,或與 pending 屬不同窗):同樣要求觀測時間前進。
        if let p = current.pending, observedAt <= p.observedAt { return current }
        current.pending = PendingWindow(percent: reading.usedPercent, resetsAt: reading.resetsAt,
                                        observedAt: observedAt, windowMinutes: reading.windowMinutes,
                                        count: 1)
        return current
    }

    private func isSameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 120
        case (nil, nil): return true
        default: return false
        }
    }

    private func appendCrossings(previous: Double, now: Double, providerId: String, windowName: String,
                                 settings: CoreSettings, transitions: inout [LimitTransition]) {
        for threshold in [settings.warnThresholdPercent, settings.dangerThresholdPercent] {
            if previous < threshold, now >= threshold {
                transitions.append(.crossedThreshold(providerId: providerId, window: windowName,
                                                     percent: now, threshold: threshold))
            }
        }
        if previous < 99.5, now >= 99.5 {
            transitions.append(.exhausted(providerId: providerId, window: windowName))
        }
    }

    /// 掃描已過期的窗口(resets_at 已過),觸發一次性的重置轉變。
    /// 重置「慶祝/通知」的新鮮度門檻:邊界已過超過此時長 → 靜默處理(狀態照常摺疊,
    /// 只是不發 transition)。寵物與通知的措辭是「剛剛重置」;app 睡過/關閉跨過邊界後,
    /// 首次刷新補發的是陳舊消息,一天前的 reset 不該說 "just reset"(codex SEV1 round-2)。
    static let resetRecency: TimeInterval = 15 * 60

    /// `excluding`:#83 U2——poisoned providers(row 5/8)整輪 fail-closed,派生 pass 亦不得
    /// 寫 marker / 交付 reset;coordinator 每輪傳入本輪 poison 集。
    public func sweepExpiredWindows(now: Date = Date(), excluding: Set<String> = []) -> [LimitTransition] {
        let backupForSweep = store   // #49:候選語義(失敗整份還原)
        var transitions: [LimitTransition] = []
        var changed = false
        for (providerId, var provider) in store where !excluding.contains(providerId) {
            var providerChanged = false
            for keyPath in [\PersistedProvider.primary, \PersistedProvider.secondary] {
                guard var w = provider[keyPath: keyPath], let resetsAt = w.resetsAt,
                      resetsAt < now, !w.expiryHandled else { continue }
                // 新鮮度閘:過期太久的 reset 只靜默標記(expiryHandled 照設,不重複檢查),不慶祝。
                // #83 G2/U3(shared boundary predicate,讀側統一):同一 logical 5h boundary 若
                // estimated 已**交付**,official 不再發——與 fold 三發射點共用同一 helper。
                let windowName = keyPath == \PersistedProvider.primary ? "5h" : "weekly"
                let estimatedDeliveredSameBoundary = Self.estimatedAlreadyDeliveredSameBoundary(
                    deliveredAt: provider.estimatedResetDeliveredAt, windowName: windowName, boundary: resetsAt)
                if w.percent >= 30, now.timeIntervalSince(resetsAt) <= Self.resetRecency,
                   !estimatedDeliveredSameBoundary {
                    transitions.append(.reset(providerId: providerId,
                                              window: keyPath == \PersistedProvider.primary ? "5h" : "weekly",
                                              estimated: false))
                }
                w.expiryHandled = true
                if keyPath == \PersistedProvider.primary {
                    provider.primary = w
                    // #49 I3:同一 logical 5h reset boundary 只有一個 durable delivery identity——
                    // official 處理(無論慶祝與否)於**同一 durable commit** 抑制 estimated fallback,
                    // 關閉 S3 的 official→estimated 跨 cycle 重發(restore 亦不會回退到未抑制態,
                    // 因為抑制與 official marker 同一 candidate/同一 barrier)。
                    provider.estimatedResetHandled = true
                } else { provider.secondary = w }
                providerChanged = true
            }
            if providerChanged {
                store[providerId] = provider
                changed = true
            }
        }
        guard changed else { return transitions }
        // #49 amendment:durable-marker-before-delivery —— marker 未 durable 前不得交付 reset
        //(否則 persist 失敗 + recency 窗內 reload ⇒ 同一 reset 重發 = invariant 2 違反)。
        // 失敗:整份還原候選、記 loud、0 transitions、下輪重算重試;crash-after-commit-before-
        // delivery 仍可能漏一次通知 = 既定 at-most-once 方向(owner)。
        do { try saveDurably() } catch {
            store = backupForSweep
            recordDerivedFailure(error)
            return []
        }
        return transitions
    }

    // MARK: - Claude 估算窗口的重置偵測

    /// 同一 provider+window 在同一次刷新同時出現官方(estimated:false)與估算(estimated:true)
    /// 的 reset → 丟棄估算那筆:兩者是同一事實的兩種證據,官方勝;寵物/通知的歸因不得被
    /// 估算蓋掉官方(慶祝採 last-wins,估算在 coordinator 流程中後到)。
    public static func preferOfficialResets(_ transitions: [LimitTransition]) -> [LimitTransition] {
        let official = Set(transitions.compactMap { t -> String? in
            if case let .reset(pid, win, false) = t { return "\(pid)|\(win)" }
            return nil
        })
        guard !official.isEmpty else { return transitions }
        return transitions.filter { t in
            if case let .reset(pid, win, true) = t, official.contains("\(pid)|\(win)") { return false }
            return true
        }
    }

    /// 估算型(帳本推導)5h 區塊結束時觸發重置轉變。
    ///
    /// `lastEventAt`:該 provider 帳本最新事件時間(顯示端仲裁同款證據)。官方 5h 窗口仍在
    /// 治理(`hasUsableWindow`,與顯示端**同一條規則**)時,估算邊界**不得**發 reset ——
    /// 否則 dashboard 說「官方 36%、18:20 重置」而寵物在 18:00 慶祝估算邊界,自相矛盾且
    /// 讓估算裝成官方事實(2026-07-16 使用者實測回報:提前 20 分鐘假慶祝)。
    /// 被壓下時仍標記 `estimatedResetHandled`:官方稍後過期也不得補發這個已成陳舊消息的邊界。
    public func noteEstimatedBlock(providerId: String, blockEnd: Date?, blockTokens: Int,
                                   lastEventAt: Date? = nil, now: Date = Date()) -> [LimitTransition] {
        var provider = store[providerId] ?? PersistedProvider()
        var transitions: [LimitTransition] = []
        var changed = false
        if let storedEnd = provider.estimatedBlockEnd, now > storedEnd,
           (provider.estimatedBlockTokens ?? 0) > 0, provider.estimatedResetHandled != true {
            // 兩道閘(缺一不發):
            // 1. 新鮮度:邊界已過 > resetRecency = 陳舊消息(app 睡過邊界;官方治理期壓下後
            //    官方才過期 —— 都不得補發,codex SEV1 round-2:18:00 邊界在 18:26 補發,
            //    與官方 18:20 的 sweep reset 撞成雙通知且估算歸因蓋掉官方)。
            // 2. 官方不治理:hasUsableWindow(與顯示端同一條規則)為真時估算邊界不得發聲。
            if now.timeIntervalSince(storedEnd) <= Self.resetRecency,
               !hasUsableWindow(provider.primary, now: now, lastEventAt: lastEventAt) {
                transitions.append(.reset(providerId: providerId, window: "5h", estimated: true))
                provider.estimatedResetDeliveredAt = storedEnd   // G2:delivery identity 記錄(同一 barrier)
            }
            provider.estimatedResetHandled = true
            changed = true
        }
        if let blockEnd {
            if provider.estimatedBlockEnd != blockEnd {
                provider.estimatedBlockEnd = blockEnd
                changed = true
                if provider.estimatedResetHandled != false {
                    provider.estimatedResetHandled = false
                    changed = true
                }
            }
            if provider.estimatedBlockTokens != blockTokens {
                provider.estimatedBlockTokens = blockTokens
                changed = true
            }
        }
        if changed {
            let backup = store   // #49 amendment:durable-marker-before-delivery(同 sweep)
            store[providerId] = provider
            do { try saveDurably() } catch {
                store = backup
                recordDerivedFailure(error)
                return []   // marker 未 durable ⇒ estimated reset 不得交付;下輪重算重試
            }
        }
        return transitions
    }

    // MARK: - 對外狀態組裝

    public func limitState(providerId: String, ledger: UsageLedger, settings: CoreSettings,
                           now: Date = Date()) -> ProviderLimitState {
        let lastEvent = ledger.newestEvent(providerId: providerId)
        let burn = ledger.burnRatePerHour(providerId: providerId, window: 3600, now: now)

        // Claude Code:官方 statusline 讀值逐窗口優先;窗口過期後由 hasUsableWindow
        // 逐窗口決定何時退回帳本預算估算(閒置寬限 24h;有 reset 後活動則立即退回)。
        if providerId == "claude-code" {
            return claudeStateWithOfficialFallback(ledger: ledger, settings: settings,
                                                   now: now, lastEvent: lastEvent, burn: burn)
        }
        return readingBackedState(providerId: providerId, settings: settings, now: now,
                                  lastEvent: lastEvent, burn: burn)
    }

    /// 過期官方窗口的活動反證容差:帳本活動需領先官方檔觀測時間超過此值,
    /// 才視為「hook 已停更」。避免 reset 邊界上 hook 與 JSONL 同批寫入的競態誤判。
    static let expiredEvidenceTolerance: TimeInterval = 60

    /// 單一官方窗口是否仍值得信任:
    /// 1. 窗口尚未 reset → 可信。
    /// 2. 已過期,但帳本在 reset 之後有新活動、而官方檔一直沒再更新 → hook 已停,
    ///    立即不可信(交回預算估算),不得讓 recovered 0% 撐滿 24h。
    /// 3. 已過期且無活動反證(閒置)→ reset 後 24h 內仍代表「已恢復」的最近狀態。
    private func hasUsableWindow(_ window: PersistedWindow?, now: Date, lastEventAt: Date?) -> Bool {
        guard let window else { return false }
        if let reset = window.resetsAt, reset > now { return true }
        if let reset = window.resetsAt, let lastEventAt,
           lastEventAt > reset,
           lastEventAt.timeIntervalSince(window.observedAt) > Self.expiredEvidenceTolerance {
            return false
        }
        return now.timeIntervalSince(window.observedAt) < 24 * 3600
    }

    private func claudeStateWithOfficialFallback(ledger: UsageLedger, settings: CoreSettings,
                                                 now: Date, lastEvent: UsageEvent?, burn: Double) -> ProviderLimitState {
        let provider = store["claude-code"]
        let useOfficialFiveHour = hasUsableWindow(provider?.primary, now: now, lastEventAt: lastEvent?.timestamp)
        let useOfficialWeekly = hasUsableWindow(provider?.secondary, now: now, lastEventAt: lastEvent?.timestamp)
        let estimated = claudeState(ledger: ledger, settings: settings, now: now,
                                    lastEvent: lastEvent, burn: burn)
        guard useOfficialFiveHour || useOfficialWeekly else { return estimated }

        let official = readingBackedState(providerId: "claude-code", settings: settings, now: now,
                                          lastEvent: lastEvent, burn: burn)
        let fiveHour = useOfficialFiveHour ? official.fiveHour : estimated.fiveHour
        let weekly = useOfficialWeekly ? official.weekly : estimated.weekly
        let lastOfficialReading = [
            useOfficialFiveHour ? provider?.primary?.observedAt : nil,
            useOfficialWeekly ? provider?.secondary?.observedAt : nil
        ].compactMap { $0 }.max()
        let warning = deriveWarning(fiveHour: fiveHour, weekly: weekly, settings: settings,
                                    lastEventAt: lastEvent?.timestamp,
                                    lastReadingAt: lastOfficialReading ?? estimated.lastReadingAt,
                                    now: now)
        return ProviderLimitState(
            providerId: "claude-code",
            fiveHour: fiveHour,
            weekly: weekly,
            burnRateTokensPerHour: burn,
            projectedExhaustionAt: useOfficialFiveHour ? official.projectedExhaustionAt : estimated.projectedExhaustionAt,
            lastEventAt: lastEvent?.timestamp,
            lastReadingAt: lastOfficialReading ?? estimated.lastReadingAt,
            warning: warning,
            planType: official.planType,
            lastSourceDescription: official.lastSourceDescription ?? estimated.lastSourceDescription
        )
    }

    private func readingBackedState(providerId: String, settings: CoreSettings, now: Date,
                                    lastEvent: UsageEvent?, burn: Double) -> ProviderLimitState {
        let provider = store[providerId]

        func windowState(_ w: PersistedWindow?, defaultMinutes: Int) -> LimitWindowState {
            guard let w else {
                return LimitWindowState(windowMinutes: defaultMinutes, confidence: .unknown)
            }
            if let resetsAt = w.resetsAt, resetsAt < now {
                // 窗口已過期:視為已恢復,等待新讀值。
                return LimitWindowState(usedPercent: 0, resetAt: nil,
                                        windowMinutes: w.windowMinutes, confidence: .estimated)
            }
            let age = now.timeIntervalSince(w.observedAt)
            let confidence: Confidence = age > 6 * 3600 ? .stale : .high
            // corrected 是一次性事件的標示,不是永久狀態:組裝層統一以 correctedAt 閘 24h,
            // UI/報告/CLI 全部消費點同步治癒;舊 state(corrected=true 但無 correctedAt)不 surface。
            let correctionVisible = w.corrected
                && (w.correctedAt.map { now.timeIntervalSince($0) <= 24 * 3600 } ?? false)
            return LimitWindowState(usedPercent: w.percent, resetAt: w.resetsAt,
                                    windowMinutes: w.windowMinutes, confidence: confidence,
                                    corrected: correctionVisible,
                                    correctedAt: correctionVisible ? w.correctedAt : nil,
                                    correctedReason: correctionVisible ? w.correctedReason : nil)
        }

        let fiveHour = windowState(provider?.primary, defaultMinutes: 300)
        let weekly = windowState(provider?.secondary, defaultMinutes: 10080)

        var projected: Date?
        if let w = provider?.primary, let rate = percentSlopePerHour(w.history, now: now), rate > 0.5,
           let percent = fiveHour.usedPercent, percent < 100 {
            projected = now.addingTimeInterval((100 - percent) / rate * 3600)
        }

        let warning = deriveWarning(fiveHour: fiveHour, weekly: weekly, settings: settings,
                                    lastEventAt: lastEvent?.timestamp, lastReadingAt: provider?.primary?.observedAt,
                                    now: now)
        return ProviderLimitState(
            providerId: providerId,
            fiveHour: fiveHour,
            weekly: weekly,
            burnRateTokensPerHour: burn,
            projectedExhaustionAt: projected,
            lastEventAt: lastEvent?.timestamp,
            lastReadingAt: provider?.primary?.observedAt ?? provider?.secondary?.observedAt,
            warning: warning,
            planType: provider?.planType,
            lastSourceDescription: lastEvent.map { "\($0.sourceKind) event at \(LocalTime.format($0.timestamp))" }
        )
    }

    private func percentSlopePerHour(_ history: [PercentSample], now: Date) -> Double? {
        let recent = history.filter { now.timeIntervalSince($0.at) < 2 * 3600 }
        guard let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= 900, last.percent > first.percent else { return nil }
        let hours = last.at.timeIntervalSince(first.at) / 3600
        return (last.percent - first.percent) / hours
    }

    // MARK: - Claude 5 小時區塊估算(帳本推導)

    /// 區塊規則:第一個事件所在整點開窗,5 小時後關窗;窗外的下一個事件開新窗。
    public static func fiveHourBlock(events: [UsageEvent], now: Date) -> (start: Date, end: Date, tokens: Int)? {
        guard !events.isEmpty else { return nil }
        var blockStart: Date?
        var blockEnd = Date.distantPast
        var tokens = 0
        for e in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            if e.timestamp >= blockEnd {
                let cal = Calendar.current
                var comps = cal.dateComponents([.year, .month, .day, .hour], from: e.timestamp)
                comps.minute = 0; comps.second = 0
                blockStart = cal.date(from: comps) ?? e.timestamp
                blockEnd = blockStart!.addingTimeInterval(5 * 3600)
                tokens = 0
            }
            tokens += e.tokens.total
        }
        guard let start = blockStart, now < blockEnd else { return nil }
        return (start, blockEnd, tokens)
    }

    private func claudeState(ledger: UsageLedger, settings: CoreSettings, now: Date,
                             lastEvent: UsageEvent?, burn: Double) -> ProviderLimitState {
        let recent = ledger.events(in: .trailing(days: 8, now: now), providerId: "claude-code")
        let block = Self.fiveHourBlock(events: recent, now: now)
        let weeklyTokens = ledger.totals(in: .trailing(days: 7, now: now), providerId: "claude-code").total

        func percent(_ tokens: Int, budget: Int?) -> Double? {
            guard let budget, budget > 0 else { return nil }
            return Double(tokens) / Double(budget) * 100
        }

        // idle = 本週有活動,但當前無 active 5h 區塊(區別於「從未使用」)。採 weekly(7d)資格窗
        // 而非 block 計算用的 8d,避免 7d23h→8d01h 的武斷斷崖(cross-model round-2)。
        let fiveIdle = (block == nil) && weeklyTokens > 0
        let fiveHour: LimitWindowState
        if let block {
            fiveHour = LimitWindowState(
                usedPercent: percent(block.tokens, budget: settings.claudeFiveHourTokenBudget),
                usedTokens: block.tokens,
                budgetTokens: settings.claudeFiveHourTokenBudget,
                resetAt: block.end,
                windowMinutes: 300,
                confidence: settings.claudeFiveHourTokenBudget != nil ? .estimated : .unknown
            )
        } else {
            // 無 active block:idle(本週有活動)或無資料(從未使用)。一律**不給百分比**——
            // 即使設了 budget,percent(0,budget)=0 會被面板誤 render 成「0% 安全餘量」(cross-model
            // round-2 的 fail-closed:漏檢只退成「—」,不造假)。usedTokens 僅 idle 給 0(誠實),
            // 從未使用給 nil(無資料)。
            fiveHour = LimitWindowState(
                usedPercent: nil,
                usedTokens: fiveIdle ? 0 : nil,
                budgetTokens: settings.claudeFiveHourTokenBudget,
                resetAt: nil,
                windowMinutes: 300,
                confidence: fiveIdle ? .estimated : .unknown,
                idle: fiveIdle
            )
        }
        // weekly 同樣不造假:本週零用量 → 百分比 nil(非 0%);usedTokens 保留(rolling 7-day 誠實計數)。
        let weekly = LimitWindowState(
            usedPercent: weeklyTokens > 0 ? percent(weeklyTokens, budget: settings.claudeWeeklyTokenBudget) : nil,
            usedTokens: weeklyTokens,
            budgetTokens: settings.claudeWeeklyTokenBudget,
            resetAt: nil, // 帳本無法得知官方週重置點;顯示為 rolling 7-day 估算
            windowMinutes: 10080,
            confidence: settings.claudeWeeklyTokenBudget != nil ? .estimated : .unknown
        )

        // 投影只在有 active block 時計算:idle 後首小時的殘留 burn 不得產生「exhausts at …」(round-2)。
        var projected: Date?
        if let block, let budget = settings.claudeFiveHourTokenBudget, burn > 1000 {
            let remaining = Double(budget - block.tokens)
            if remaining > 0 { projected = now.addingTimeInterval(remaining / burn * 3600) }
            else if block.tokens >= budget { projected = now }
        }

        let warning = deriveWarning(fiveHour: fiveHour, weekly: weekly, settings: settings,
                                    lastEventAt: lastEvent?.timestamp, lastReadingAt: lastEvent?.timestamp, now: now)
        return ProviderLimitState(
            providerId: "claude-code",
            fiveHour: fiveHour,
            weekly: weekly,
            burnRateTokensPerHour: burn,
            projectedExhaustionAt: projected,
            lastEventAt: lastEvent?.timestamp,
            lastReadingAt: lastEvent?.timestamp,
            warning: warning,
            // plan 標籤與 statusline 窗口可用性無關(plan-only reading 落地於 store):
            // 官方讀值失效退回預算估算時,chip 不得消失。
            planType: store["claude-code"]?.planType,
            lastSourceDescription: lastEvent.map { "\($0.sourceKind) event at \(LocalTime.format($0.timestamp))" }
        )
    }

    private func deriveWarning(fiveHour: LimitWindowState, weekly: LimitWindowState, settings: CoreSettings,
                               lastEventAt: Date?, lastReadingAt: Date?, now: Date) -> WarningState {
        guard lastEventAt != nil || lastReadingAt != nil else { return .noData }
        let percents = [fiveHour.usedPercent, weekly.usedPercent].compactMap { $0 }
        if percents.contains(where: { $0 >= 99.5 }) { return .exhausted }
        if percents.contains(where: { $0 >= settings.warnThresholdPercent }) { return .warning }
        // 資料陳舊:近期有事件,但 rate-limit 讀值明顯落後。
        if let lastEventAt, let lastReadingAt,
           lastEventAt.timeIntervalSince(lastReadingAt) > Double(settings.staleAfterMinutes) * 60 {
            return .stale
        }
        return .ok
    }
}
