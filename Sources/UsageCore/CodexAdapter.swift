import Foundation

/// 讀取 Codex CLI 的本機 rollout 紀錄(`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// 與 `~/.codex/archived_sessions`)。擷取 `token_count` 事件的 token 累計與
/// `rate_limits`(5 小時 / 週窗口的 used_percent 與 resets_at),以及 `turn_context`
/// 的 model 與 cwd。不讀取提示詞或訊息內容。
public struct CodexAdapter: ProviderAdapter {
    public let providerId = "codex"
    public let displayName = "Codex"

    public let roots: [URL]

    public init(roots: [URL]? = nil) {
        if let roots {
            self.roots = roots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            let candidates = [
                codexHome.appendingPathComponent("sessions"),
                codexHome.appendingPathComponent("archived_sessions"),
            ]
            self.roots = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    public func detectAvailability() -> ProviderAvailability {
        guard let root = roots.first else {
            return ProviderAvailability(available: false, detail: "~/.codex/sessions not found")
        }
        return ProviderAvailability(available: true, detail: "found \(root.path)")
    }

    public func explainDataSources() -> String {
        "Reads Codex CLI rollout logs (rollout-*.jsonl) under ~/.codex/sessions and ~/.codex/archived_sessions. Only token_count totals, rate-limit percentages, reset times, model IDs, project paths, and timestamps are extracted. Prompts and message contents are never read into the ledger."
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
                    let newOffset = try JSONLScanner.scan(
                        url: url, from: startOffset,
                        quickFilters: ["token_count", "turn_context", "session_meta"]
                    ) { hit in
                        guard let obj = (try? JSONSerialization.jsonObject(with: hit.data)) as? JSONObject else {
                            parseErrors += 1
                            return
                        }
                        Self.parseLine(obj, ctx: &ctx, fileStem: fileStem, byteOffset: hit.byteOffset,
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

    static func parseLine(_ obj: JSONObject, ctx: inout FileContext, fileStem: String, byteOffset: Int64,
                          sourcePath: String, events: inout [UsageEvent], readings: inout [RateLimitReading]) {
        guard let type = obj.str("type") else { return }
        let payload = obj.obj("payload") ?? [:]
        let timestamp = obj.date("timestamp") ?? payload.date("timestamp")

        switch type {
        case "session_meta":
            if let cwd = payload.str("cwd") { ctx.cwd = cwd }
        case "turn_context":
            if let cwd = payload.str("cwd") { ctx.cwd = cwd }
            if let model = payload.str("model") { ctx.model = model }
        case "event_msg":
            guard payload.str("type") == "token_count" else { return }
            guard let ts = timestamp else { return }

            if let info = payload.obj("info"), let totals = info.obj("total_token_usage") {
                let input = totals.int("input_tokens") ?? 0
                let cached = totals.int("cached_input_tokens") ?? 0
                let output = totals.int("output_tokens") ?? 0

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

            if let limits = payload.obj("rate_limits") {
                let reading = RateLimitReading(
                    providerId: "codex",
                    observedAt: ts,
                    primary: parseWindow(limits.obj("primary"), observedAt: ts),
                    secondary: parseWindow(limits.obj("secondary"), observedAt: ts),
                    planType: limits.str("plan_type"),
                    sourcePath: sourcePath
                )
                if reading.primary != nil || reading.secondary != nil {
                    readings.append(reading)
                }
            }
        default:
            break
        }
    }

    static func parseWindow(_ obj: JSONObject?, observedAt: Date) -> RateLimitWindowReading? {
        guard let obj, let percent = obj.double("used_percent") else { return nil }
        let windowMinutes = obj.int("window_minutes") ?? 0
        var resetsAt: Date?
        if let unix = obj.double("resets_at") {
            resetsAt = Date(timeIntervalSince1970: unix)
        } else if let inSeconds = obj.double("resets_in_seconds") {
            resetsAt = observedAt.addingTimeInterval(inSeconds)
        }
        return RateLimitWindowReading(usedPercent: percent, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }
}
