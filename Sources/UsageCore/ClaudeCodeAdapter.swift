import Foundation

/// 讀取 Claude Code 的本機對話紀錄(`~/.claude/projects/**/*.jsonl`)。
/// 只擷取 assistant 訊息的 `message.usage` token 統計與 model/cwd/timestamp;
/// 不讀取、不保存任何提示詞或訊息內容。
public struct ClaudeCodeAdapter: ProviderAdapter {
    public let providerId = "claude-code"
    public let displayName = "Claude Code"

    private let candidateRoots: [URL]
    public var roots: [URL] {
        candidateRoots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// 官方限額來源:statusline 落地檔也要監看(父目錄監看 + 檔路徑作為觸發白名單)。
    public var watchFiles: [URL] { statuslineFiles }
    /// Claude Code statusline payload 的落地檔候選位置。Claude Code 每次刷新
    /// 狀態列都會把官方 JSON(含 `rate_limits` 的 5h/週 used_percentage 與
    /// resets_at)餵給 statusline 指令;只要有任何 hook 把它存檔,就能在此讀到
    /// 官方限額,不需使用者手動設預算。
    public let statuslineFiles: [URL]
    /// 訂閱方案標籤來源(`~/.claude.json` 窄解碼;可注入供測試/停用)。
    public let planConfigFiles: [URL]

    public init(roots: [URL]? = nil, statuslineFiles: [URL]? = nil, planConfigFiles: [URL]? = nil) {
        self.planConfigFiles = planConfigFiles ?? Self.defaultConfigFiles()
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let roots {
            self.candidateRoots = roots
        } else {
            var candidates = [home.appendingPathComponent(".claude/projects")]
            if let cfg = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                candidates.append(URL(fileURLWithPath: cfg).appendingPathComponent("projects"))
            }
            candidates.append(home.appendingPathComponent(".config/claude/projects"))
            self.candidateRoots = candidates
        }
        if let statuslineFiles {
            self.statuslineFiles = statuslineFiles
        } else {
            self.statuslineFiles = [
                // 本 app 自帶 hook(Scripts/claude-statusline-hook.sh)的輸出
                AppPaths.dataDirectory().appendingPathComponent("claude-statusline.json"),
                // 其他 statusline 工具常見的落地位置(同為官方 payload 原文)
                home.appendingPathComponent(".claude/usage-status.json"),
            ]
        }
    }

    public func detectAvailability() -> ProviderAvailability {
        guard let root = roots.first else {
            return ProviderAvailability(available: false, detail: "~/.claude/projects not found")
        }
        return ProviderAvailability(available: true, detail: "found \(root.path)")
    }

    public func explainDataSources() -> String {
        "Reads Claude Code session logs (*.jsonl) under ~/.claude/projects — only per-message token counts, model IDs, project paths, and timestamps. Also reads Claude Code's own statusline payload (rate_limits: official 5h/weekly used percent + reset times) when a statusline hook saves it locally, and the subscription tier label (two keys narrowly decoded from ~/.claude.json; nothing else in that file is parsed). Prompts and message contents are never read."
    }

    public func explainRequiredPermissions() -> String {
        "Read-only access to ~/.claude/projects (and CLAUDE_CONFIG_DIR if set), plus ~/.claude.json for the subscription tier label only. Needed to compute local token usage per project and model."
    }

    public func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
        var newState = state
        var events: [UsageEvent] = []
        var parseErrors = 0
        var scanned = 0

        for root in roots {
            for (url, size) in JSONLScanner.listFiles(root: root, pathExtension: "jsonl") {
                let key = url.path
                let mark = state.files[key]
                if let mark, mark.size == size, mark.offset == size { continue } // 無新內容
                scanned += 1
                let startOffset = (mark != nil && mark!.offset <= size) ? mark!.offset : 0
                do {
                    let newOffset = try JSONLScanner.scan(url: url, from: startOffset,
                                                          quickFilters: ["input_tokens"]) { hit in
                        guard let obj = (try? JSONSerialization.jsonObject(with: hit.data)) as? JSONObject else {
                            parseErrors += 1
                            return
                        }
                        if let event = Self.parseAssistantLine(obj, sourcePath: url.path) {
                            events.append(event)
                        }
                    }
                    newState.files[key] = FileScanMark(offset: newOffset, size: size)
                } catch {
                    parseErrors += 1
                }
            }
        }
        var readings = Self.readStatuslineRateLimits(from: statuslineFiles)
        if let plan = Self.readPlanLabel(configFiles: planConfigFiles) {
            // plan-only reading(無窗口):只落地 planType,不進窗口仲裁。
            readings.append(RateLimitReading(providerId: "claude-code", observedAt: Date(),
                                             primary: nil, secondary: nil,
                                             planType: plan, sourcePath: nil))
        }
        return (AdapterRefreshResult(events: events, rateLimits: readings, scannedFiles: scanned, parseErrors: parseErrors), newState)
    }

    /// 解析 Claude Code statusline payload 落地檔中的官方 `rate_limits`。
    /// 這是 Claude Code 自身介面輸出的資料(非第三方格式):
    /// `{"rate_limits": {"five_hour": {"used_percentage": N, "resets_at": unix},
    ///                   "seven_day": {...}}}`
    ///
    /// 多個落地檔(本 app hook / 其他 statusline 工具)可能一新一舊、或各缺一窗:
    /// 對 five_hour / seven_day **各自**取「該窗存在且檔案 mtime 最新」者,並以
    /// **primary-only / secondary-only 兩筆讀數**回傳、各帶自己來源檔的 mtime ——
    /// ingest 對 primary/secondary 共用 reading.observedAt,合成單筆會讓活躍檔的
    /// 新 mtime 灌給另一窗的陳舊值,偽造「兩筆 observedAt 遞增」觸發假下修。
    /// 兩窗恰好同檔時合為一筆(observedAt 相同,無交叉污染)。
    public static func readStatuslineRateLimits(from urls: [URL]) -> [RateLimitReading] {
        struct Candidate {
            var window: RateLimitWindowReading
            var observedAt: Date
            var path: String
        }
        var bestPrimary: Candidate?
        var bestSecondary: Candidate?
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
                  let limits = obj.obj("rate_limits") else { continue } // 半寫入/壞 JSON → 跳過該檔

            let observedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                .flatMap { $0 } ?? Date()

            func window(_ key: String, minutes: Int) -> RateLimitWindowReading? {
                guard let w = limits.obj(key),
                      let percent = w.double("used_percentage") ?? w.double("used_percent") else { return nil }
                var resetsAt: Date?
                if let unix = w.double("resets_at") { resetsAt = Date(timeIntervalSince1970: unix) }
                return RateLimitWindowReading(usedPercent: percent, windowMinutes: minutes, resetsAt: resetsAt)
            }

            if let p = window("five_hour", minutes: 300),
               bestPrimary.map({ observedAt > $0.observedAt }) ?? true {
                bestPrimary = Candidate(window: p, observedAt: observedAt, path: url.path)
            }
            if let s = window("seven_day", minutes: 10080),
               bestSecondary.map({ observedAt > $0.observedAt }) ?? true {
                bestSecondary = Candidate(window: s, observedAt: observedAt, path: url.path)
            }
        }

        if let p = bestPrimary, let s = bestSecondary, p.path == s.path {
            return [RateLimitReading(providerId: "claude-code", observedAt: p.observedAt,
                                     primary: p.window, secondary: s.window,
                                     planType: nil, sourcePath: p.path)]
        }
        var readings: [RateLimitReading] = []
        if let p = bestPrimary {
            readings.append(RateLimitReading(providerId: "claude-code", observedAt: p.observedAt,
                                             primary: p.window, secondary: nil,
                                             planType: nil, sourcePath: p.path))
        }
        if let s = bestSecondary {
            readings.append(RateLimitReading(providerId: "claude-code", observedAt: s.observedAt,
                                             primary: nil, secondary: s.window,
                                             planType: nil, sourcePath: s.path))
        }
        return readings
    }

    // MARK: - 訂閱方案標籤(窄解碼;隱私邊界見 docs/DATA_SOURCES.md)

    /// `~/.claude.json`(或 `$CLAUDE_CONFIG_DIR/.claude.json`)的窄解碼結構:
    /// **僅**宣告方案標籤所需的兩個鍵;檔案其餘內容(帳號、專案清單等)不解碼、不物化。
    /// 禁止以 JSONSerialization 整檔物化(該檔含敏感欄位)。
    struct ClaudeConfigPlan: Decodable {
        struct OAuthAccount: Decodable {
            let organizationRateLimitTier: String?
            let organizationType: String?
        }
        let oauthAccount: OAuthAccount?
    }

    /// 讀取使用者的 Claude 訂閱方案標籤("Max 20x"/"Pro"…)。任何失敗 → nil(不進 UI)。
    public static func readPlanLabel(configFiles: [URL]) -> String? {
        for url in configFiles {
            guard let data = try? Data(contentsOf: url),
                  let cfg = try? JSONDecoder().decode(ClaudeConfigPlan.self, from: data),
                  let account = cfg.oauthAccount else { continue }
            if let label = Self.planLabel(tier: account.organizationRateLimitTier,
                                          organizationType: account.organizationType) {
                return label
            }
        }
        return nil
    }

    static func defaultConfigFiles() -> [URL] {
        var candidates: [URL] = []
        if let cfg = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            candidates.append(URL(fileURLWithPath: cfg).appendingPathComponent(".claude.json"))
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"))
        return candidates
    }

    /// 映射優先序:1) rate-limit tier 命中表;2) 去前綴 title-case 兜底;
    /// 3) organizationType;4) 皆無 → nil。
    public static func planLabel(tier: String?, organizationType: String?) -> String? {
        if let tier, !tier.isEmpty {
            switch tier {
            case "default_claude_max_20x": return "Max 20x"
            case "default_claude_max_5x": return "Max 5x"
            case "default_claude_pro": return "Pro"
            default:
                let stripped = tier.hasPrefix("default_claude_")
                    ? String(tier.dropFirst("default_claude_".count)) : tier
                // 兜底只在去前綴後的單一 token 恰為 pro 時映射,避免未知 tier 含 "pro" 子字串誤判。
                if stripped.lowercased() == "pro" { return "Pro" }
                let pretty = stripped.split(separator: "_")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
                return pretty.isEmpty ? nil : pretty
            }
        }
        switch organizationType {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return nil
        }
    }

    static func parseAssistantLine(_ obj: JSONObject, sourcePath: String) -> UsageEvent? {
        guard obj.str("type") == "assistant",
              let message = obj.obj("message"),
              let usage = message.obj("usage"),
              let timestamp = obj.date("timestamp")
        else { return nil }

        let model = message.str("model")
        if model == "<synthetic>" { return nil }

        let input = usage.int("input_tokens") ?? 0
        let output = usage.int("output_tokens") ?? 0
        let cacheRead = usage.int("cache_read_input_tokens") ?? 0
        var write5m = 0
        var write1h = 0
        if let creation = usage.obj("cache_creation") {
            write5m = creation.int("ephemeral_5m_input_tokens") ?? 0
            write1h = creation.int("ephemeral_1h_input_tokens") ?? 0
        }
        let creationTotal = usage.int("cache_creation_input_tokens") ?? 0
        if write5m + write1h == 0, creationTotal > 0 {
            write5m = creationTotal // 無細分時視為 5m 快取(計價時標示為估計)
        }
        let tokens = TokenBreakdown(input: input, output: output, cacheRead: cacheRead,
                                    cacheWrite5m: write5m, cacheWrite1h: write1h)
        if tokens.total == 0 { return nil }

        let messageId = message.str("id")
        let requestId = obj.str("requestId")
        let uuid = obj.str("uuid")
        guard let idCore = messageId ?? uuid else { return nil }
        let id = "cc:\(idCore):\(requestId ?? "-")"

        let cwd = obj.str("cwd")
        let projectName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }

        return UsageEvent(
            id: id,
            providerId: "claude-code",
            projectId: cwd,
            projectName: projectName,
            modelId: model,
            timestamp: timestamp,
            tokens: tokens,
            sourceKind: "claude-jsonl",
            sourcePath: sourcePath
        )
    }
}
