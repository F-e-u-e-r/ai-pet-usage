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
public struct OpenCodeAdapter: ProviderAdapter {
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
        tokens_cache_read, tokens_cache_write, time_updated \
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
            rows.append(Row(
                id: String(cString: idC),
                directory: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                modelJSON: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                cost: (rawCost.isFinite && rawCost >= 0) ? rawCost : 0,
                input: Int(ti),
                outputFolded: Int(to) + Int(tr),
                cacheRead: Int(tcr),
                cacheWrite: Int(tcw),
                timeUpdatedMs: tu
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
