import Foundation

/// 讀取 Grok CLI 的本機工作階段紀錄
/// (`~/.grok/sessions/<URL 百分比編碼的 cwd>/<session-uuid>/updates.jsonl`)。
/// 只擷取 `_meta.totalTokens` 這個「累計、近似 context 大小」的計數器,以及
/// 同資料夾 `summary.json`/`signals.json` 的 model 與 cwd。絕不解碼提示詞或訊息內容
/// (`params.update`),不讀取憑證檔,不進行任何網路存取。
///
/// 隱私設計:每行以「窄」的 Decodable(僅解 timestamp 與 params._meta)解碼,
/// 不把整行反序列化成 JSONObject——避免把訊息內容物化到任何資料結構。
///
/// token 語意:`totalTokens` 追蹤的是 context 大小而非帳單用量,壓縮後會倒退(寫入較小值,
/// 歷史不重寫)。每回合事件 = 此計數器相對上一回合的「正成長」;倒退即重設基準、不產生事件。
/// 因此這裡的 token 數是「低估帳單用量」的估計,且無 input/output/cache 拆分(全計為 input)。
/// grok 本機不提供限額,故不回報任何 rate limit / 使用率百分比。
///
/// 已知限制(v1):
///   1. 多個 agent 共用同一 updates.jsonl 時計數器可能交錯;v1 每檔單一基準,
///      交錯造成的倒退會被倒退規則視為壓縮而重設基準,優雅降級、不產生負事件。
///   2. session 中途換 model 時,本次掃描產生的事件一律歸屬 summary.json 目前的 model。
public struct GrokCodeAdapter: ProviderAdapter {
    public let providerId = "grok-code"
    public var historyModel: ProviderHistoryModel { .rebuildableHistory }   // JSONL 逐事件 → 可重掃重建
    public let displayName = "Grok Code"

    private let candidateRoots: [URL]
    /// 訂閱方案標籤來源:`<grokHome>/logs/unified.jsonl` 尾端的 billing 行(可注入供測試)。
    private let billingLogFiles: [URL]
    public var roots: [URL] {
        candidateRoots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public init(roots: [URL]? = nil, billingLogFiles: [URL]? = nil) {
        // GROK_HOME 存在時「取代」整個 ~/.grok 根目錄(工作階段在 $GROK_HOME/sessions)。
        let home = FileManager.default.homeDirectoryForCurrentUser
        let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".grok")
        self.candidateRoots = roots ?? [grokHome.appendingPathComponent("sessions")]
        self.billingLogFiles = billingLogFiles ?? [grokHome.appendingPathComponent("logs/unified.jsonl")]
    }

    /// 內建預設候選(**真實 home**,與 GROK_HOME 無關)。
    static func builtinRoots() -> [(url: URL, label: String)] {
        [(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/sessions"),
          "~/.grok/sessions")]
    }

    public func detectAvailability() -> ProviderAvailability {
        let disclosure = RootDisclosure.classify(selectedRoot: roots.first,
                                                 candidates: candidateRoots,
                                                 builtin: Self.builtinRoots())
        guard let root = roots.first else {
            return ProviderAvailability(available: false, detail: "~/.grok/sessions not found",
                                        disclosure: disclosure)
        }
        return ProviderAvailability(available: true, detail: "found \(root.path)", disclosure: disclosure)
    }

    public func diagnosticSources() -> [DiagnosticSourceDescriptor] {
        candidateRoots.prefix(1).map { DiagnosticSourceDescriptor(id: .grokSessions, url: $0) }
    }

    public func explainDataSources() -> String {
        "Reads Grok CLI session logs (updates.jsonl) under ~/.grok/sessions (or GROK_HOME) — only the cumulative token counter (_meta.totalTokens) plus model ID and project path from sibling summary.json/signals.json. Also reads the tail of logs/unified.jsonl for the subscription tier label (one key narrowly decoded from billing lines; other log content is never parsed). Token figures are context-growth estimates that undercount billed usage and have no input/output split. Prompts and message contents are never read; no network; credential files are never touched. Grok exposes no usage percent locally, so none is shown."
    }

    public func explainRequiredPermissions() -> String {
        "Read-only access to ~/.grok/sessions (or GROK_HOME), plus the tail of ~/.grok/logs/unified.jsonl for the subscription tier label only. Needed to estimate local Grok token usage per project and model. No credentials are read and nothing is uploaded."
    }

    public func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
        var newState = state
        var events: [UsageEvent] = []
        var parseErrors = 0
        var scanned = 0
        var complete = true   // 契約 E:列舉或任一檔內容讀取失敗 → 不完整(不得取代切片)
        let decoder = JSONDecoder()

        for root in roots {
            let listing = JSONLScanner.listFiles(root: root, pathExtension: "jsonl")
            if !listing.complete { complete = false }
            for (url, size) in listing.files {
                // 只掃 updates.jsonl;events.jsonl(生命週期)等其餘 JSONL 一律略過。
                guard url.lastPathComponent == "updates.jsonl" else { continue }
                let key = url.path
                let mark = state.files[key]
                if let mark, mark.size == size, mark.offset == size { continue } // 無新內容
                scanned += 1

                // 檔案被截斷/重寫(offset > size)→ 從 0 重掃並重置上下文;
                // 事件 id 內容穩定,帳本去重會吸收重播。
                var ctx = FileContext(from: (mark?.offset ?? 0) <= size ? mark?.context : nil)
                let startOffset = (mark != nil && mark!.offset <= size) ? mark!.offset : 0
                let sessionDir = url.deletingLastPathComponent()
                let sessionId = sessionDir.lastPathComponent
                let encodedCwd = sessionDir.deletingLastPathComponent().lastPathComponent

                // 每次實際掃描此檔時,讀一次 summary.json/signals.json 補齊 model 與 cwd。
                Self.loadSessionMeta(sessionDir: sessionDir, encodedCwd: encodedCwd, ctx: &ctx)

                do {
                    // quickFilters 只放行含 "totalTokens" 的行:訊息 chunk 等根本不會被 JSON 解析。
                    let newOffset = try JSONLScanner.scan(
                        url: url, from: startOffset, quickFilters: ["totalTokens"]
                    ) { hit in
                        Self.parseLine(hit.data, decoder: decoder, ctx: &ctx, sessionId: sessionId,
                                       byteOffset: hit.byteOffset, sourcePath: url.path,
                                       events: &events, parseErrors: &parseErrors)
                    }
                    newState.files[key] = FileScanMark(offset: newOffset, size: size, context: ctx.serialized())
                } catch {
                    parseErrors += 1
                    complete = false   // 檔案內容讀取失敗 → 不完整(契約 E)
                }
            }
        }
        // grok 本機無「用量百分比」來源(percent 恆為 unknown 屬設計);
        // 但 CLI 的 billing 行含訂閱層級 → 以 plan-only reading 落地標籤,不進窗口仲裁。
        var readings: [RateLimitReading] = []
        if let tier = Self.readSubscriptionTier(from: billingLogFiles) {
            readings.append(RateLimitReading(providerId: "grok-code", observedAt: Date(),
                                             primary: nil, secondary: nil, planType: tier))
        }
        return (AdapterRefreshResult(events: events, rateLimits: readings, scannedFiles: scanned, parseErrors: parseErrors,
                                     completeness: (complete && parseErrors == 0) ? .complete : .incomplete("some sources unreadable or unparsable")), newState)
    }

    // MARK: - 訂閱方案標籤(billing 行窄解碼)

    /// unified.jsonl 行的窄解碼:僅 `ctx.subscriptionTier` 一鍵;其餘 log 內容不物化。
    struct BillingLine: Decodable {
        struct Ctx: Decodable { let subscriptionTier: String? }
        let ctx: Ctx?
    }

    /// 讀 log 尾端(最後 ≤2MiB)的 billing 行,取**最後一筆非空** subscriptionTier。
    /// 缺檔/缺鍵/解析失敗 → nil(絕不猜值)。有界讀取:log 可能很大,只看尾部。
    /// billing 行只在 grok CLI 啟動時寫入,重度使用下可能沉到很深(實測 ~1MB);
    /// tier 一經 ingest 便持久化於 limits-state(nil 讀數不清除),tail 抓到一次即可。
    public static func readSubscriptionTier(from urls: [URL], tailBytes: Int = 2 * 1024 * 1024) -> String? {
        let decoder = JSONDecoder()
        for url in urls {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            var latest: String?
            var scanStart = data.startIndex
            // 從截斷點起第一行可能不完整,逐行掃、壞行跳過即可。
            while scanStart < data.endIndex {
                let lineEnd = data[scanStart...].firstIndex(of: 0x0A) ?? data.endIndex
                let line = data[scanStart..<lineEnd]
                scanStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
                // quickFilter:先做便宜的子字串檢查,再窄解碼。
                guard line.count > 20, line.range(of: Data("subscriptionTier".utf8)) != nil else { continue }
                if let parsed = try? decoder.decode(BillingLine.self, from: line),
                   let tier = parsed.ctx?.subscriptionTier, !tier.isEmpty {
                    latest = tier
                }
            }
            if let latest { return latest }
        }
        return nil
    }

    // MARK: - 檔案內解析上下文(跨增量掃描持久化)

    struct FileContext {
        var cwd: String?
        var model: String?
        /// 上一筆已處理的累計 token 值(近似 context 大小);差值計算的基準。
        var cumulativeTokens: Int = 0
        var hasBaseline = false

        init(from dict: [String: String]?) {
            guard let dict else { return }
            cwd = dict["cwd"]
            model = dict["model"]
            cumulativeTokens = Int(dict["total"] ?? "") ?? 0
            hasBaseline = dict["baseline"] == "1"
        }

        func serialized() -> [String: String] {
            var d: [String: String] = [:]
            if let cwd { d["cwd"] = cwd }
            if let model { d["model"] = model }
            d["total"] = String(cumulativeTokens)
            d["baseline"] = hasBaseline ? "1" : "0"
            return d
        }
    }

    /// 讀 summary.json/signals.json 補上 model 與 cwd(每檔每次刷新至多各讀一次)。
    /// cwd 優先用 sessions 子目錄名(URL 百分比編碼)解碼,summary.json 的 info.cwd 為後援。
    /// model 優先 summary.json.current_model_id,signals.json.primaryModelId 為後援。
    /// 註:summary/signals 僅含中繼資料(id/cwd/model),不含提示詞或訊息內容。
    static func loadSessionMeta(sessionDir: URL, encodedCwd: String, ctx: inout FileContext) {
        if ctx.cwd == nil, let decoded = encodedCwd.removingPercentEncoding, !decoded.isEmpty {
            ctx.cwd = decoded
        }
        if let data = try? Data(contentsOf: sessionDir.appendingPathComponent("summary.json")),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
            if let model = obj.str("current_model_id"), !model.isEmpty { ctx.model = model }
            if ctx.cwd == nil, let info = obj.obj("info"), let cwd = info.str("cwd"), !cwd.isEmpty {
                ctx.cwd = cwd
            }
        }
        if ctx.model == nil,
           let data = try? Data(contentsOf: sessionDir.appendingPathComponent("signals.json")),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
           let model = obj.str("primaryModelId"), !model.isEmpty {
            ctx.model = model
        }
    }

    static func parseLine(_ data: Data, decoder: JSONDecoder, ctx: inout FileContext,
                          sessionId: String, byteOffset: Int64, sourcePath: String,
                          events: inout [UsageEvent], parseErrors: inout Int) {
        guard let rec = try? decoder.decode(GrokRecord.self, from: data) else {
            parseErrors += 1
            return
        }
        // 只認帶 _meta.totalTokens 的紀錄;其餘(訊息 chunk、生命週期)不計 token。
        guard let total = rec.totalTokens else { return }
        // 無法解析時間戳者一律跳過(與 CodexAdapter 同序:時間戳優先於基準更新)。
        guard let ts = Self.resolveTimestamp(rec) else { return }

        // 每檔單一累計基準;差值 = 目前累計 − 基準。首筆(尚無基準)差值即目前累計值。
        let delta = ctx.hasBaseline ? (total - ctx.cumulativeTokens) : total
        // 無論成長或倒退,都把基準推進到目前值:倒退(壓縮)即重設基準、不產生事件。
        ctx.cumulativeTokens = total
        ctx.hasBaseline = true
        guard delta > 0 else { return }

        let id: String
        if let eventId = rec.eventId, !eventId.isEmpty {
            id = "gk:\(eventId)"                  // grok 穩定事件 id
        } else {
            id = "gk:\(sessionId):\(byteOffset)"  // 後援:session uuid + 行位移
        }

        events.append(UsageEvent(
            id: id,
            providerId: "grok-code",
            projectId: ctx.cwd,
            projectName: ctx.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            modelId: ctx.model,
            timestamp: ts,
            // grok 計數器無 I/O 拆分:全部成長計入 input,output/cacheRead 恆為 0。
            tokens: TokenBreakdown(input: delta, output: 0, cacheRead: 0),
            sourceKind: "grok-session",
            sourcePath: sourcePath
        ))
    }

    /// 解析時間戳:頂層 `timestamp` 規格為 epoch 秒;防禦性地把 > 1e12 的值視為毫秒。
    /// 後援 `_meta.agentTimestampMs`(毫秒);兩者皆無則回傳 nil(該筆跳過)。
    static func resolveTimestamp(_ rec: GrokRecord) -> Date? {
        if let raw = rec.timestamp {
            let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        if let ms = rec.agentTimestampMs {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }

    /// 窄解碼結構:僅取 token 計數與時間戳所需欄位。
    /// `params.update`(含 content.text 訊息內容)完全不在解碼範圍內,絕不物化。
    struct GrokRecord: Decodable {
        let timestamp: Double?
        let totalTokens: Int?
        let eventId: String?
        let agentTimestampMs: Double?

        private enum Keys: String, CodingKey { case timestamp, params }
        private enum ParamsKeys: String, CodingKey { case meta = "_meta" }
        private enum MetaKeys: String, CodingKey { case totalTokens, eventId, agentTimestampMs }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            // timestamp 可能是整數或浮點,decode(Double) 兩者皆可;缺鍵/型別不符則為 nil。
            timestamp = try? c.decode(Double.self, forKey: .timestamp)

            guard let params = try? c.nestedContainer(keyedBy: ParamsKeys.self, forKey: .params),
                  let meta = try? params.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta) else {
                totalTokens = nil
                eventId = nil
                agentTimestampMs = nil
                return
            }
            totalTokens = (try? meta.decode(Int.self, forKey: .totalTokens))
                ?? (try? meta.decode(Double.self, forKey: .totalTokens)).map { Int($0) }
            eventId = try? meta.decode(String.self, forKey: .eventId)
            agentTimestampMs = try? meta.decode(Double.self, forKey: .agentTimestampMs)
        }
    }
}
