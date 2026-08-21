import Foundation
import SQLite3

// OpenCode(opencode CLI ≥ v1.x,SQLite 儲存)adapter。
// 對照 docs/DATA_SOURCES.md「OpenCode」與 docs/ADAPTER_CONTRACT.md;R1 雙模型計畫審查定案:
//   - **表級窄查詢**:只 SELECT `session` 表的 10 個宣告欄位(數值/識別欄,無內容);
//     `message`/`part`/`session_message` 的 data blob、`title`/`summary_diffs`,以及
//     **同庫共存的 `account`/`credential`/`control_account`(OAuth tokens!)永不查詢** ——
//     並以 sqlite3_set_authorizer 白名單在執行期強制(schema 漂移出 view 也擋;codex C8)。
//   - 唯讀開啟(SQLITE_OPEN_READONLY);WAL 讀者協定會更新 `-shm` read-mark(僅協調資料,
//     絕非 db/WAL 內容)——ADAPTER_CONTRACT 規則 1 的明文窄例外。任何 sqlite 錯誤
//     (BUSY/CANTOPEN/授權拒絕)→ 整輪 fail-soft:throw、不推進狀態、不產生半批事件。
//   - session 列是**每 session 累計計數器**:每輪發正差額事件;任一 token 類別倒退 →
//     epoch+1、全類基準重設、不發事件(all-or-nothing;grok G7)。cost 倒退獨立重設
//     (codex C4)。事件 id = `oc:<session-id>:<epoch>:<from>`(from = 差額前的摺疊空間
//     總量)——回歸後重生長不碰撞(grok G1/codex C2);scan-state 寫入失敗的重播因
//     同 id 被帳本去重,方向為**有界低估**、狀態恢復後自癒(codex C1;與 Grok 低估姿態一致)。
//   - `tokens_reasoning` 摺入 output(計費歸屬);cache_write 無 TTL 標示 → 落
//     `cacheWriteUnknown`,絕不假冒 5m/1h(codex C7)。時間戳為毫秒。
//   - `session.cost` 差額作為 providerCostUSD:僅在有限、> ε、且該輪確有 token 差額時
//     接受(cost == 0 且 tokens > 0 在 opencode 語意下是「缺費率 fallback 0」的歧義值,
//     一律視為未定價;codex C4)。
//   - roots 刻意為空:FSEvents 走 watchFiles(db + wal 檔案級白名單),auth.json/
//     credential 變更不觸發 refresh(grok G3/codex C5)。
public struct OpenCodeAdapter: ProviderAdapter, CumulativeAnchorAdapter {
    public let providerId = "opencode"
    // db 只存目前累計(非可重播歷史)→ 不可重掃重建;reindex 保留既有切片、只走增量(codex MF2)。
    public var historyModel: ProviderHistoryModel { .cumulativeSnapshotOnly }
    public let displayName = "OpenCode"

    private let dbURL: URL

    public init(dbURL: URL? = nil) {
        self.dbURL = dbURL ?? Self.defaultDbURL()
    }

    /// XDG_DATA_HOME(僅絕對路徑;XDG 規範:相對路徑必須忽略)→ 否則 ~/.local/share。
    static func defaultDbURL() -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("opencode/opencode.db")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// 內建預設(**真實 home**;disclosure 分類用)。
    static func builtinRoots() -> [(url: URL, label: String)] {
        [(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode"),
          "~/.local/share/opencode")]
    }

    /// 刻意無目錄 roots:coordinator 會把 roots 整棵樹當 trigger,而 opencode 資料夾內
    /// 還有 auth.json / log / repos —— 不得因憑證檔變更觸發 refresh。
    public var roots: [URL] { [] }

    /// 檔案級觸發白名單:db 主檔 + WAL(寫入先落 WAL)。父目錄由 coordinator 監看。
    public var watchFiles: [URL] {
        [dbURL, URL(fileURLWithPath: dbURL.path + "-wal")]
    }

    public func detectAvailability() -> ProviderAvailability {
        let dir = dbURL.deletingLastPathComponent()
        let disclosure = RootDisclosure.classify(selectedRoot: dir, candidates: [dir],
                                                 builtin: Self.builtinRoots())
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return ProviderAvailability(available: false, detail: "opencode.db not found",
                                        disclosure: disclosure)
        }
        return ProviderAvailability(available: true, detail: "found \(dbURL.path)", disclosure: disclosure)
    }

    /// db 與 wal 同 id 各報一筆:WAL 模式下寫入常只落 `-wal`,主檔 mtime 可能停在上次
    /// checkpoint —— diag 的同 id 合併取較新者,WAL 活躍不得誤判 stale(R2 grok F3)。
    public func diagnosticSources() -> [DiagnosticSourceDescriptor] {
        [DiagnosticSourceDescriptor(id: .opencodeDb, url: dbURL),
         DiagnosticSourceDescriptor(id: .opencodeDb, url: URL(fileURLWithPath: dbURL.path + "-wal"))]
    }

    public func explainDataSources() -> String {
        "Reads opencode's local SQLite database (~/.local/share/opencode/opencode.db, or under XDG_DATA_HOME) strictly read-only — only the per-session usage counters: token counts (input/output/reasoning/cache), opencode's own cost figure, model ID, project directory, and timestamps from the `session` table. A runtime SQLite authorizer allowlists exactly those columns: message/prompt content tables and the credential/account tables that share this database are never queried. Standard WAL read coordination only; database content is never modified. Costs are opencode-reported (models.dev rates) and labelled estimated. OpenCode exposes no usage limits locally, so no usage percent is shown."
    }

    public func explainRequiredPermissions() -> String {
        "Read-only access to opencode's local database (~/.local/share/opencode/opencode.db). Needed to count local OpenCode token usage and opencode-reported cost per project and model. Prompts, message contents, and the credential tables in that database are never read; nothing is uploaded."
    }

    // MARK: - 掃描

    /// 摺疊空間基準(per session):epoch + 4 個 token 類別 + cost。
    private struct Baseline {
        var epoch: Int
        var input: Int
        var output: Int        // tokens_output + tokens_reasoning(摺疊後)
        var cacheRead: Int
        var cacheWrite: Int
        var cost: Double

        var foldTotal: Int { input + output + cacheRead + cacheWrite }

        // context 值編碼:「epoch,in,out,cr,cw,cost」。
        init(epoch: Int = 1, input: Int = 0, output: Int = 0, cacheRead: Int = 0,
             cacheWrite: Int = 0, cost: Double = 0) {
            self.epoch = epoch
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.cost = cost
        }

        init?(serialized: String) {
            let parts = serialized.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 6,
                  let e = Int(parts[0]), let i = Int(parts[1]), let o = Int(parts[2]),
                  let cr = Int(parts[3]), let cw = Int(parts[4]), let c = Double(parts[5]) else { return nil }
            // F4 twin:persisted scan-state context 也是未受信整數。epoch 超出合法演進域、
            // counters 超出來源可能域(readRows 同一 1e15 cap)或 cost 非有限/負 → 不採信,
            // 視同 context 損壞重建 baseline —— 否則 `epoch + 1` / `foldTotal` 的相加
            // 會在構造過的 scan-state 上 trap。
            let cap = 1_000_000_000_000_000
            guard e > 0, e < Int.max - 1,
                  i >= 0, i <= cap, o >= 0, o <= cap,
                  cr >= 0, cr <= cap, cw >= 0, cw <= cap,
                  c.isFinite, c >= 0 else { return nil }
            self.init(epoch: e, input: i, output: o, cacheRead: cr, cacheWrite: cw, cost: c)
        }

        var serialized: String {
            "\(epoch),\(input),\(output),\(cacheRead),\(cacheWrite),\(String(format: "%.6f", cost))"
        }
    }

    private struct Row {
        var id: String
        var directory: String?
        var modelJSON: String?
        var cost: Double
        var input: Int
        var outputFolded: Int
        var cacheRead: Int
        var cacheWrite: Int
        var timeUpdatedMs: Int64
        var timeCreatedMs: Int64?
    }

    public func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
        let key = dbURL.path
        let mark = state.files[key]
        var context = mark?.context ?? ["schema": "1"]
        let highWater = mark?.offset ?? 0

        // 完整讀取成功後才計算事件與新狀態;任何 sqlite 錯誤在此前 throw(不推進狀態,codex C3)。
        let rows = try Self.readRows(dbPath: key, sinceMs: highWater)

        var events: [UsageEvent] = []
        var parseErrors = 0
        var maxSeen = highWater
        let decoder = JSONDecoder()

        for row in rows {
            maxSeen = max(maxSeen, row.timeUpdatedMs)
            let ctxKey = "s:\(row.id)"
            var base = context[ctxKey].flatMap { Baseline(serialized: $0) } ?? Baseline()

            // 任一 token 類別倒退(revert/壓縮/還原)→ epoch+1、全基準重設、不發事件(G7)。
            if row.input < base.input || row.outputFolded < base.output
                || row.cacheRead < base.cacheRead || row.cacheWrite < base.cacheWrite {
                context[ctxKey] = Baseline(epoch: base.epoch + 1, input: row.input,
                                           output: row.outputFolded, cacheRead: row.cacheRead,
                                           cacheWrite: row.cacheWrite, cost: row.cost).serialized
                continue
            }

            let dIn = row.input - base.input
            let dOut = row.outputFolded - base.output
            let dCr = row.cacheRead - base.cacheRead
            let dCw = row.cacheWrite - base.cacheWrite
            let tokenDelta = dIn + dOut + dCr + dCw

            // cost 倒退獨立處理:重設 cost 基準、本輪不掛 providerCost;token 差額照發(C4)。
            // 重設必須**立即持久化**(R2 grok F1)—— cost-only 倒退若不寫回 context,
            // 之後每輪都會從陳舊高基準重算成「又一次倒退」,合法增量被反覆吞掉。
            var costDelta = row.cost - base.cost
            if costDelta < -1e-6 {
                base.cost = row.cost
                costDelta = 0
                context[ctxKey] = base.serialized
            }

            guard tokenDelta > 0 else {
                // 零 token 差額(含 cost-only 正向變化):不發事件、不推進 token/cost 基準
                //(正向 cost 差額累積到下一次帶 token 的差額一併掛上)。
                continue
            }

            // providerCost 接受條件:有限、> ε、且伴隨 token 差額(cost==0 是 opencode
            // 缺費率 fallback 的歧義值 → 視為未定價,走 registry → 誠實 unknown)。
            let providerCost: Double? =
                (costDelta.isFinite && costDelta > 1e-6) ? costDelta : nil

            var modelId: String?
            if let json = row.modelJSON, let data = json.data(using: .utf8) {
                struct ModelRef: Decodable { var id: String? }   // 窄解碼:僅 id;providerID 不物化
                if let ref = try? decoder.decode(ModelRef.self, from: data) {
                    modelId = ref.id
                } else {
                    parseErrors += 1
                }
            }

            let projectName = row.directory.map { URL(fileURLWithPath: $0).lastPathComponent }
            events.append(UsageEvent(
                id: "oc:\(row.id):\(base.epoch):\(base.foldTotal)",
                providerId: providerId,
                projectId: row.directory,
                projectName: projectName,
                modelId: modelId,
                timestamp: Date(timeIntervalSince1970: TimeInterval(row.timeUpdatedMs) / 1000),
                tokens: TokenBreakdown(input: dIn, output: dOut, cacheRead: dCr, cacheWriteUnknown: dCw),
                sourceKind: "opencode-session",
                sourcePath: key,
                providerCostUSD: providerCost
            ))

            // cost 基準:差額被接受才推進到當前值;歧義/零差額則保留(累積到下一次
            // 帶 token 的差額)。倒退情形已在上方重設。
            let newCostBase = providerCost != nil ? row.cost : base.cost
            context[ctxKey] = Baseline(epoch: base.epoch, input: row.input, output: row.outputFolded,
                                       cacheRead: row.cacheRead, cacheWrite: row.cacheWrite,
                                       cost: newCostBase).serialized
        }

        var newState = state
        let size = ((try? FileManager.default.attributesOfItem(atPath: key))?[.size] as? NSNumber)?
            .int64Value ?? 0
        // highWater 與全部基準同存於**同一** FileScanMark → 原子同進退(G2)。
        newState.files[key] = FileScanMark(offset: maxSeen, size: size, context: context)
        return (AdapterRefreshResult(events: events, rateLimits: [],
                                     scannedFiles: rows.isEmpty ? 0 : 1, parseErrors: parseErrors,
                                     completeness: .complete),   // 整輪讀取成功才走到這(任何 sqlite 錯誤已在上游 throw)
                newState)
    }

    // MARK: - #50 authoritative census
    //
    // C contract:scan cursor 僅為 discovery 最佳化,**不得決定某個已具權威的 incarnation
    // 是否被檢視**。因此本函式一律自 0 讀取全部 session 列 —— 備份還原使 `time_updated`
    // 一併倒退時,該列仍會被看到,epoch 邊界不會被錯過。
    public func censusCumulative(anchors: [IncarnationKey: CumulativeAnchor],
                                 scanState: ScanState,
                                 boundaryMs: Int64?,
                                 establishAll: Bool) throws -> CumulativeDerivation {
        let key = dbURL.path
        let rows = try Self.readRows(dbPath: key, sinceMs: 0)

        var proposals: [IncarnationKey: CumulativeProposal] = [:]
        var ambiguous: [IncarnationKey] = []
        var parseErrors = 0
        var excludedRows = 0
        var maxSeen: Int64 = 0
        let decoder = JSONDecoder()

        for row in rows {
            maxSeen = max(maxSeen, row.timeUpdatedMs)
            // B:缺 time_created 的列無法構成 incarnation key ⇒ 不可能成為 authority。
            // X4:缺 identity 的列無法納入 census —— 列被跳過(B contract),且本輪喪失
            // complete-census 資格(boundary 不得推進),否則該列修復後會被假 boundary
            // 永久打成歧義。parseErrors 同步計(來源品質 surface 維持不變)。
            // R4-B(luna-50-r4,owner contract):loader 會拒絕的 identity,census 就不得
            // 接受(writer/reader symmetry)—— 空 sessionId 無法構成合法 incarnation key
            //(`IncarnationKey(encoded:)` 拒絕空 sid),接受它 = runtime 自己 durable-commit
            // 一份下一輪必 reject 的 authority,且 re-baseline 會反覆重製同一 poison。
            guard !row.id.isEmpty else { parseErrors += 1; excludedRows += 1; continue }
            guard let tc = row.timeCreatedMs else { parseErrors += 1; excludedRows += 1; continue }
            let ik = IncarnationKey(sessionId: row.id, timeCreatedMs: tc)
            let current = AnchorCounters(input: row.input, output: row.outputFolded,
                                         cacheRead: row.cacheRead, cacheWrite: row.cacheWrite,
                                         cost: row.cost)

            if establishAll {
                // 顯式 re-baseline:所有可觀測 incarnation 一律 zero-delta 重錨。
                // F4:epoch 演進一律走 checked helper —— 上界即 fail closed(throw),絕不 trap。
                let nextEpoch: Int
                if let prior = anchors[ik] {
                    guard let n = CumulativeAnchor.nextEpoch(after: prior.epoch) else {
                        throw EpochBoundExceeded(sessionId: row.id)
                    }
                    nextEpoch = n
                } else {
                    nextEpoch = 1
                }
                proposals[ik] = CumulativeProposal(
                    event: nil,
                    target: CumulativeAnchor(epoch: nextEpoch, accountedThrough: current))
                continue
            }

            guard let anchor = anchors[ik] else {
                // R1:此 incarnation 沒有權威。是「觀測邊界之後才建立」還是「本應早已可見」?
                guard let boundary = boundaryMs else {
                    // 尚無 complete-census 證明 ⇒ provider 首次建立 ⇒ zero-delta,不回填。
                    proposals[ik] = CumulativeProposal(
                        event: nil, target: CumulativeAnchor(epoch: 1, accountedThrough: current))
                    continue
                }
                if tc > boundary {
                    // 建立於可信觀測期內 ⇒ 其目前累計量全部發生在我們的觀測之下,計入首窗。
                    // F1(grok-50-r2):authority establishment 不得繫於 growth 事件之有無 ——
                    // 首窗全零時 growth() 回 nil,此處仍必須立 zero-delta anchor;否則 boundary
                    // 越過其 timeCreated 後,該 incarnation 永久落入 R1(c) 歧義,其後真實用量
                    // 全數被 fail-closed 丟棄(testReproGrokR2F1ZeroFirstWindowIncarnationLosesAnchor)。
                    proposals[ik] = growth(row: row, from: AnchorCounters(), epoch: 1, incarnation: ik,
                                           sourcePath: key, decoder: decoder, parseErrors: &parseErrors)
                        ?? CumulativeProposal(
                            event: nil, target: CumulativeAnchor(epoch: 1, accountedThrough: current))
                } else {
                    // 本應早已可見卻無權威 ⇒ 歧義,不得猜測。
                    ambiguous.append(ik)
                }
                continue
            }

            // R4-A(grok-50-r4,owner contract):**任一 authoritative cumulative 座標**倒退
            //(四類 token 或 provider cost)⇒ 單一 accounting epoch 邊界 —— 整個座標系一起
            // 換 epoch、全量重錨到現值、本輪不發事件(混合 provenance 禁止;同 snapshot 多維
            // 倒退也只 bump 一次 —— 單一 predicate、單一 nextEpoch)。這使舊 epoch 的
            // operation 座標命名空間不可重用:cost 1→3→1→3 的第二個 1→3 必然落在新 epoch,
            // canonical id 不可能回繞碰撞。cost 座標取 session.cost 原值(含 0 —— 誤把
            // 費率缺失的歸零判成 rollback 的代價只是保守的一輪不發事件 + 重錨,絕不 overcount)。
            // 還原後真正的新成長由下一輪自新 baseline 產生。
            // R5-A(owner verdict,r5):accounting contract **沒有 epsilon** —— provider cost 的
            // 任何 exact 下降都是 rollback(1e-6 只是舊 implementation tolerance,不是 money
            // semantics;sub-eps 抖動若判成 rollback,代價僅是保守的一輪不發事件,絕不累積誤差)。
            if !current.dominates(anchor.accountedThrough)
                || current.cost < anchor.accountedThrough.cost {
                // F4:同上 —— 這裡的輸入已通過 validateSemantics(< Int.max),但演進域更窄
                //(≤ Int.max - 2),超界即 fail closed,不得寫出不可載入的 epoch。
                guard let bumped = CumulativeAnchor.nextEpoch(after: anchor.epoch) else {
                    throw EpochBoundExceeded(sessionId: row.id)
                }
                proposals[ik] = CumulativeProposal(
                    event: nil,
                    target: CumulativeAnchor(epoch: bumped, accountedThrough: current))
                continue
            }
            if let p = growth(row: row, from: anchor.accountedThrough, epoch: anchor.epoch, incarnation: ik,
                              sourcePath: key, decoder: decoder, parseErrors: &parseErrors) {
                proposals[ik] = p
            }
        }

        var newState = scanState
        let size = ((try? FileManager.default.attributesOfItem(atPath: key))?[.size] as? NSNumber)?
            .int64Value ?? 0
        newState.files[key] = FileScanMark(offset: maxSeen, size: size,
                                           context: scanState.files[key]?.context)
        return CumulativeDerivation(proposals: proposals, ambiguous: ambiguous, scanState: newState,
                                    parseErrors: parseErrors, excludedRows: excludedRows,
                                    scannedFiles: rows.isEmpty ? 0 : 1)
    }

    /// 同 epoch 的正向成長。回傳 nil = 本輪對該 incarnation 無任何狀態變更。
    private func growth(row: Row, from base: AnchorCounters, epoch: Int, incarnation: IncarnationKey,
                        sourcePath: String,
                        decoder: JSONDecoder, parseErrors: inout Int) -> CumulativeProposal? {
        let dIn = row.input - base.input
        let dOut = row.outputFolded - base.output
        let dCr = row.cacheRead - base.cacheRead
        let dCw = row.cacheWrite - base.cacheWrite
        let tokenDelta = dIn + dOut + dCr + dCw

        // R5-A:cost 倒退在 census rollback predicate 已被攔截(整體換 epoch)—— 本分支為
        // 防禦性不可達;strict 語義下與 predicate 同一數值 contract(無 epsilon)。
        var costBase = base.cost
        var costDelta = row.cost - costBase
        if costDelta < 0 { costBase = row.cost; costDelta = 0 }

        guard tokenDelta > 0 else {
            // R6:cost-only 的正向變化自成一筆事件(provider 回報的成本就是該筆的成本),
            // **不得**延到下一筆帶 token 的事件 —— 那會讓這段成本與其 token 早先取得的
            // registry estimate 重複計價。
            // R5-A:任何 exact 上升都是 cost growth(1.0000000 → 1.0000005 必須恰好入帳
            // +0.0000005,否則 anchor 推進而事件被吞 = 無 lifetime bound 的 undercount)。
            if costDelta.isFinite, costDelta > 0 {
                let ev = UsageEvent(
                    id: incarnation.eventId(epoch: epoch, previous: base,
                                            target: { var t = base; t.cost = row.cost; return t }()),
                    providerId: providerId,
                    projectId: row.directory,
                    projectName: row.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
                    modelId: nil,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row.timeUpdatedMs) / 1000),
                    tokens: TokenBreakdown(),
                    sourceKind: "opencode-session",
                    sourcePath: sourcePath,
                    providerCostUSD: costDelta)
                var t = base
                t.cost = row.cost
                return CumulativeProposal(event: ev,
                                          target: CumulativeAnchor(epoch: epoch, accountedThrough: t))
            }
            guard costBase != base.cost else { return nil }
            var t = base
            t.cost = costBase
            return CumulativeProposal(event: nil,
                                      target: CumulativeAnchor(epoch: epoch, accountedThrough: t))
        }

        // providerCost 接受條件:有限、> 0(R5-A:exact,無 epsilon)、且伴隨 token 差額
        //(cost==0 是 opencode 缺費率 fallback 的歧義值 → 視為未定價,走 registry)。
        let providerCost: Double? = (costDelta.isFinite && costDelta > 0) ? costDelta : nil

        var modelId: String?
        if let json = row.modelJSON, let data = json.data(using: .utf8) {
            struct ModelRef: Decodable { var id: String? }   // 窄解碼:僅 id
            if let ref = try? decoder.decode(ModelRef.self, from: data) {
                modelId = ref.id
            } else {
                parseErrors += 1
            }
        }

        // R6:cost 基準**恆**推進到現值 —— 歧義輪(cost 未變或為 0)的成本不得累積到下一筆
        // 帶 token 的事件,否則會與該輪 token 已取得的 registry estimate 重複計價。
        let target = AnchorCounters(input: row.input, output: row.outputFolded,
                                    cacheRead: row.cacheRead, cacheWrite: row.cacheWrite,
                                    cost: row.cost)
        let event = UsageEvent(
            id: incarnation.eventId(epoch: epoch, previous: base, target: target),   // R3/X2:綁完整 operation
            providerId: providerId,
            projectId: row.directory,
            projectName: row.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
            modelId: modelId,
            timestamp: Date(timeIntervalSince1970: TimeInterval(row.timeUpdatedMs) / 1000),
            tokens: TokenBreakdown(input: dIn, output: dOut, cacheRead: dCr, cacheWriteUnknown: dCw),
            sourceKind: "opencode-session",
            sourcePath: sourcePath,
            providerCostUSD: providerCost
        )
        return CumulativeProposal(event: event,
                                  target: CumulativeAnchor(epoch: epoch, accountedThrough: target))
    }

    // MARK: - SQLite(唯讀 + authorizer 白名單)

    private static func readRows(dbPath: String, sinceMs: Int64) throws -> [Row] {
        var db: OpaquePointer?
        // 唯讀開啟:絕不建立 db;WAL sidecar 缺失且無法唯讀參與 → 開啟失敗 → fail-soft。
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw OpenCodeError.cannotOpen
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 250)

        // 執行期白名單(codex C8):SELECT + `session` 宣告欄位(+ sqlite 內部 schema)以外
        // 一律 DENY —— 即使未來 schema 把 session 換成掛在 credential 上的 view,
        // 底層表的 READ 也會被拒,prepare 直接失敗。
        guard sqlite3_set_authorizer(db, opencodeAuthorizerCallback, nil) == SQLITE_OK else {
            throw OpenCodeError.cannotOpen
        }

        let sql = """
        SELECT id, directory, model, cost, tokens_input, tokens_output, tokens_reasoning, \
        tokens_cache_read, tokens_cache_write, time_updated, time_created \
        FROM session WHERE time_updated >= ? ORDER BY time_updated, id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw OpenCodeError.schemaMismatch
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sinceMs)

        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw OpenCodeError.readFailed }   // BUSY 等 → 整輪放棄
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            // 數值驗證(R2 codex F8):NULL/負值/超界計數器不得矽轉成 0 或負基準
            //(負 current 會把基準重設成負、之後回到 0 便偽造正差額)。cost 為負或
            // 非有限 → 以 0 計(歧義 → 未定價),不整輪放棄。時間戳必須為正。
            for col in Int32(4)...9 where sqlite3_column_type(stmt, col) == SQLITE_NULL {
                throw OpenCodeError.schemaMismatch
            }
            let ti = sqlite3_column_int64(stmt, 4), to = sqlite3_column_int64(stmt, 5)
            let tr = sqlite3_column_int64(stmt, 6), tcr = sqlite3_column_int64(stmt, 7)
            let tcw = sqlite3_column_int64(stmt, 8), tu = sqlite3_column_int64(stmt, 9)
            let maxSane: Int64 = 1_000_000_000_000_000   // 1e15:溢位不可能、超界即異常
            for v in [ti, to, tr, tcr, tcw] where v < 0 || v > maxSane {
                throw OpenCodeError.schemaMismatch
            }
            guard tu > 0, tu <= maxSane else { throw OpenCodeError.schemaMismatch }
            let rawCost = sqlite3_column_double(stmt, 3)
            // #50 O2-a:time_created 是 incarnation 判別子,非 accounting 資料 —— NULL / 非正 /
            // 超界不整輪放棄(那會連可用的用量一併丟掉),只令該列無法構成 incarnation key。
            let tcRaw = sqlite3_column_int64(stmt, 10)
            let timeCreated: Int64? =
                (sqlite3_column_type(stmt, 10) != SQLITE_NULL && tcRaw > 0 && tcRaw <= maxSane) ? tcRaw : nil
            rows.append(Row(
                id: String(cString: idC),
                directory: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                modelJSON: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                cost: (rawCost.isFinite && rawCost >= 0) ? rawCost : 0,
                input: Int(ti),
                outputFolded: Int(to) + Int(tr),
                cacheRead: Int(tcr),
                cacheWrite: Int(tcw),
                timeUpdatedMs: tu,
                timeCreatedMs: timeCreated
            ))
        }
        return rows
    }
}

public enum OpenCodeError: Error {
    case cannotOpen
    case schemaMismatch
    case readFailed
}

/// authorizer 允許的 `session` 欄位(**封閉集合**;與 readRows 的 SELECT 一一對應)。
private let opencodeAllowedSessionColumns: Set<String> = [
    "id", "directory", "model", "cost", "tokens_input", "tokens_output", "tokens_reasoning",
    "tokens_cache_read", "tokens_cache_write", "time_updated",
    // #50 O2-a:session incarnation 判別子。**僅此一欄**——`event_sequence` /
    // `session_context_epoch` 屬新表,不在允許範圍(該 db 與 account/credential/control_account
    // 同居,擴表是安全決策;且 session_context_epoch 的 baseline/snapshot 為 text)。
    "time_created",
]

/// C 回呼(無捕獲):SELECT 與宣告欄位之外一律 DENY —— 含 sqlite_* 內部表
/// (R2 codex F5:掛在 sqlite_master 上的誘餌 view 也必須被拒;實測 prepare
/// 我方單一 SELECT 不需要授權內部表讀取)。
private let opencodeAuthorizerCallback: @convention(c) (
    UnsafeMutableRawPointer?, Int32,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Int32 = { _, action, p1, p2, _, _ in
    switch action {
    case SQLITE_SELECT:
        return SQLITE_OK
    case SQLITE_READ:
        guard let tableC = p1 else { return SQLITE_DENY }
        let table = String(cString: tableC)
        if table == "session", let colC = p2, opencodeAllowedSessionColumns.contains(String(cString: colC)) {
            return SQLITE_OK
        }
        return SQLITE_DENY
    default:
        return SQLITE_DENY
    }
}
