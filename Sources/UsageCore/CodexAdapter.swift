import Foundation

/// 讀取 Codex CLI 的本機 rollout 紀錄(`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// 與 `~/.codex/archived_sessions`)。擷取 `token_count` 事件的 token 累計與
/// `rate_limits`(5 小時 / 週窗口的 used_percent 與 resets_at),以及 `turn_context`
/// 的 model 與 cwd。不讀取提示詞或訊息內容。
public struct CodexAdapter: ProviderAdapter {
    public let providerId = "codex"
    public let displayName = "Codex"

    private let candidateRoots: [URL]
    public var roots: [URL] {
        candidateRoots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public init(roots: [URL]? = nil) {
        if let roots {
            self.candidateRoots = roots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            let candidates = [
                codexHome.appendingPathComponent("sessions"),
                codexHome.appendingPathComponent("archived_sessions"),
            ]
            self.candidateRoots = candidates
        }
    }

    /// 內建預設候選(**真實 home**,與 CODEX_HOME 無關)→ sources 預設輸出的固定標籤對照表。
    static func builtinRoots() -> [(url: URL, label: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [(home.appendingPathComponent(".codex/sessions"), "~/.codex/sessions"),
                (home.appendingPathComponent(".codex/archived_sessions"), "~/.codex/archived_sessions")]
    }

    public func detectAvailability() -> ProviderAvailability {
        let disclosure = RootDisclosure.classify(selectedRoot: roots.first,
                                                 candidates: candidateRoots,
                                                 builtin: Self.builtinRoots())
        guard let root = roots.first else {
            return ProviderAvailability(available: false, detail: "~/.codex/sessions not found",
                                        disclosure: disclosure)
        }
        return ProviderAvailability(available: true, detail: "found \(root.path)", disclosure: disclosure)
    }

    public func diagnosticSources() -> [DiagnosticSourceDescriptor] {
        // 預設候選順序為 [sessions, archived_sessions];以固定 id 對位。
        let ids: [DiagnosticSourceID] = [.codexSessions, .codexArchived]
        return zip(candidateRoots, ids).map { DiagnosticSourceDescriptor(id: $1, url: $0) }
    }

    public func explainDataSources() -> String {
        "Reads Codex CLI rollout logs (rollout-*.jsonl) under ~/.codex/sessions and ~/.codex/archived_sessions. Only token_count totals, rate-limit percentages, reset times, model IDs, project paths, and timestamps are decoded (narrow decoder; undeclared fields are never built into objects). Prompts and message contents are never extracted, retained, or emitted."
    }

    public func explainRequiredPermissions() -> String {
        "Read-only access to ~/.codex (or CODEX_HOME). Needed to compute local token usage and to show official 5-hour/weekly rate-limit percentages."
    }

    public func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
        var newState = state
        var events: [UsageEvent] = []
        var readings: [RateLimitReading] = []
        var parseErrors = 0
        var scanned = 0

        for root in roots {
            for (url, size) in JSONLScanner.listFiles(root: root, pathExtension: "jsonl") {
                guard url.lastPathComponent.hasPrefix("rollout-") else { continue }
                let key = url.path
                let mark = state.files[key]
                if let mark, mark.size == size, mark.offset == size { continue }
                scanned += 1

                var ctx = FileContext(from: (mark?.offset ?? 0) <= size ? mark?.context : nil)
                let startOffset = (mark != nil && mark!.offset <= size) ? mark!.offset : 0
                let fileStem = url.deletingPathExtension().lastPathComponent

                do {
                    // 隱私邊界:以**窄 Decodable** 只解出宣告過的用量/中繼欄位。session_meta 的
                    // base_instructions、通過 quickFilter 的 response_item 訊息內容等未宣告欄位
                    // 不會被 decode 成我方持有的物件(對照舊碼:JSONSerialization 會把整行物化
                    // 成 [String:Any])。見 docs/ADAPTER_CONTRACT.md。
                    let decoder = JSONDecoder()
                    let newOffset = try JSONLScanner.scan(
                        url: url, from: startOffset,
                        quickFilters: ["token_count", "turn_context", "session_meta"]
                    ) { hit in
                        guard let line = try? decoder.decode(CodexLine.self, from: hit.data) else {
                            parseErrors += 1
                            return
                        }
                        Self.parseLine(line, ctx: &ctx, fileStem: fileStem, byteOffset: hit.byteOffset,
                                       sourcePath: url.path, events: &events, readings: &readings)
                    }
                    newState.files[key] = FileScanMark(offset: newOffset, size: size, context: ctx.serialized())
                } catch {
                    parseErrors += 1
                }
            }
        }
        return (AdapterRefreshResult(events: events, rateLimits: readings, scannedFiles: scanned, parseErrors: parseErrors), newState)
    }

    // MARK: - 檔案內解析上下文(跨增量掃描持久化)

    struct FileContext {
        var cwd: String?
        var model: String?
        var totalInput: Int = 0
        var totalCached: Int = 0
        var totalOutput: Int = 0
        var hasBaseline = false

        init(from dict: [String: String]?) {
            guard let dict else { return }
            cwd = dict["cwd"]
            model = dict["model"]
            totalInput = Int(dict["in"] ?? "") ?? 0
            totalCached = Int(dict["cached"] ?? "") ?? 0
            totalOutput = Int(dict["out"] ?? "") ?? 0
            hasBaseline = dict["baseline"] == "1"
        }

        func serialized() -> [String: String] {
            var d: [String: String] = [:]
            if let cwd { d["cwd"] = cwd }
            if let model { d["model"] = model }
            d["in"] = String(totalInput)
            d["cached"] = String(totalCached)
            d["out"] = String(totalOutput)
            d["baseline"] = hasBaseline ? "1" : "0"
            return d
        }
    }

    /// Codex rollout 行的**窄 Decodable**:只宣告解析所需的用量/中繼欄位。session_meta 的
    /// `base_instructions`、response_item 的訊息內容、turn_context 的 policy/sandbox 細節等
    /// **未宣告**欄位不會被 decode 成我方持有的物件。DATA_SOURCES.md 的隱私邊界以此為準。
    struct CodexLine: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let timestamp: String?
            let cwd: String?
            let model: String?
            let info: Info?
            let rate_limits: RateLimits?
        }
        struct Info: Decodable { let total_token_usage: Totals? }
        struct Totals: Decodable {
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let output_tokens: Int?
        }
        struct RateLimits: Decodable {
            let plan_type: String?
            let primary: Window?
            let secondary: Window?
        }
        struct Window: Decodable {
            let used_percent: Double?
            let window_minutes: Int?
            let resets_at: Double?
            let resets_in_seconds: Double?
        }
    }

    static func parseLine(_ line: CodexLine, ctx: inout FileContext, fileStem: String, byteOffset: Int64,
                          sourcePath: String, events: inout [UsageEvent], readings: inout [RateLimitReading]) {
        guard let type = line.type else { return }
        let payload = line.payload
        // 與舊碼同義的逐欄後援:外層 timestamp 缺/壞 → 用 payload.timestamp(皆經 ISO8601.parse)。
        let timestamp = line.timestamp.flatMap(ISO8601.parse) ?? payload?.timestamp.flatMap(ISO8601.parse)

        switch type {
        case "session_meta":
            if let cwd = payload?.cwd { ctx.cwd = cwd }
        case "turn_context":
            if let cwd = payload?.cwd { ctx.cwd = cwd }
            if let model = payload?.model { ctx.model = model }
        case "event_msg":
            guard payload?.type == "token_count" else { return }
            guard let ts = timestamp else { return }

            if let totals = payload?.info?.total_token_usage {
                let input = totals.input_tokens ?? 0
                let cached = totals.cached_input_tokens ?? 0
                let output = totals.output_tokens ?? 0

                var dIn = input - ctx.totalInput
                var dCached = cached - ctx.totalCached
                var dOut = output - ctx.totalOutput
                if !ctx.hasBaseline {
                    dIn = input; dCached = cached; dOut = output
                }
                // 累計值倒退(異常/重置)時以目前值為新基準,不產生負事件。
                if dIn < 0 || dCached < 0 || dOut < 0 { dIn = 0; dCached = 0; dOut = 0 }
                ctx.totalInput = input
                ctx.totalCached = cached
                ctx.totalOutput = output
                ctx.hasBaseline = true

                let tokens = TokenBreakdown(input: max(0, dIn - dCached), output: dOut, cacheRead: dCached)
                if tokens.total > 0 {
                    events.append(UsageEvent(
                        id: "cx:\(fileStem):\(byteOffset)",
                        providerId: "codex",
                        projectId: ctx.cwd,
                        projectName: ctx.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                        modelId: ctx.model,
                        timestamp: ts,
                        tokens: tokens,
                        sourceKind: "codex-rollout",
                        sourcePath: sourcePath
                    ))
                }
            }

            if let limits = payload?.rate_limits {
                // Codex 的 primary/secondary 欄位「不」固定對應 5h/週(觀察到 Codex 暫撤 5h 時
                // 只回報週窗口且放在 primary、secondary 為 null),故以 window_minutes 分類到
                // 5h/週兩槽,而非 JSON 位置。RateLimitReading 契約:primary=5h、secondary=週。
                let planType = limits.plan_type
                let (fiveHour, weekly) = classifyWindows(parseWindow(limits.primary, observedAt: ts),
                                                         parseWindow(limits.secondary, observedAt: ts))
                let reading = RateLimitReading(
                    providerId: "codex",
                    observedAt: ts,
                    primary: fiveHour,
                    secondary: weekly,
                    planType: planType,
                    sourcePath: sourcePath
                )
                // 兩窗皆無但有 plan:仍發 plan-only 讀數以保留方案標籤(chip 不因無法分類而消失)。
                if reading.primary != nil || reading.secondary != nil || planType != nil {
                    readings.append(reading)
                }
            }
        default:
            break
        }
    }

    static func parseWindow(_ w: CodexLine.Window?, observedAt: Date) -> RateLimitWindowReading? {
        guard let w, let percent = w.used_percent else { return nil }
        let windowMinutes = w.window_minutes ?? 0
        var resetsAt: Date?
        if let unix = w.resets_at {
            resetsAt = Date(timeIntervalSince1970: unix)
        } else if let inSeconds = w.resets_in_seconds {
            resetsAt = observedAt.addingTimeInterval(inSeconds)
        }
        return RateLimitWindowReading(usedPercent: percent, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }

    /// 以 window_minutes「精確」把兩個窗口分類到 5h/週兩槽(而非 JSON 的 primary/secondary
    /// 位置——Codex 的位置不保證窗型:曾觀察到週窗口被放在 primary、secondary 為 null)。
    /// fail-closed:只有已知的 Codex 窗長才歸位(5h=300、週=10080);其餘(未知/0/未來的
    /// 60 分或 30 天等新窗長)一律忽略,不塞進 UI 寫死「5h/weekly」標籤的既有槽位而誤標。
    /// 同型重覆(理論上不會)保留第一個。
    static func classifyWindows(_ a: RateLimitWindowReading?, _ b: RateLimitWindowReading?)
        -> (fiveHour: RateLimitWindowReading?, weekly: RateLimitWindowReading?) {
        var fiveHour: RateLimitWindowReading?
        var weekly: RateLimitWindowReading?
        for w in [a, b].compactMap({ $0 }) {
            switch w.windowMinutes {
            case 300:   if fiveHour == nil { fiveHour = w }
            case 10080: if weekly == nil { weekly = w }
            default:    break   // 未知窗長:忽略,不誤標到 5h/週槽
            }
        }
        return (fiveHour, weekly)
    }
}
