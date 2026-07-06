import Foundation

/// 讀取 Claude Code 的本機對話紀錄(`~/.claude/projects/**/*.jsonl`)。
/// 只擷取 assistant 訊息的 `message.usage` token 統計與 model/cwd/timestamp;
/// 不讀取、不保存任何提示詞或訊息內容。
public struct ClaudeCodeAdapter: ProviderAdapter {
    public let providerId = "claude-code"
    public let displayName = "Claude Code"

    public let roots: [URL]
    /// Claude Code statusline payload 的落地檔候選位置。Claude Code 每次刷新
    /// 狀態列都會把官方 JSON(含 `rate_limits` 的 5h/週 used_percentage 與
    /// resets_at)餵給 statusline 指令;只要有任何 hook 把它存檔,就能在此讀到
    /// 官方限額,不需使用者手動設預算。
    public let statuslineFiles: [URL]

    public init(roots: [URL]? = nil, statuslineFiles: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let roots {
            self.roots = roots
        } else {
            var candidates = [home.appendingPathComponent(".claude/projects")]
            if let cfg = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                candidates.append(URL(fileURLWithPath: cfg).appendingPathComponent("projects"))
            }
            candidates.append(home.appendingPathComponent(".config/claude/projects"))
            self.roots = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
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
        "Reads Claude Code session logs (*.jsonl) under ~/.claude/projects — only per-message token counts, model IDs, project paths, and timestamps. Also reads Claude Code's own statusline payload (rate_limits: official 5h/weekly used percent + reset times) when a statusline hook saves it locally. Prompts and message contents are never read."
    }

    public func explainRequiredPermissions() -> String {
        "Read-only access to ~/.claude/projects (and CLAUDE_CONFIG_DIR if set). Needed to compute local token usage per project and model."
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
        let readings = Self.readStatuslineRateLimits(from: statuslineFiles)
        return (AdapterRefreshResult(events: events, rateLimits: readings, scannedFiles: scanned, parseErrors: parseErrors), newState)
    }

    /// 解析 Claude Code statusline payload 落地檔中的官方 `rate_limits`。
    /// 這是 Claude Code 自身介面輸出的資料(非第三方格式):
    /// `{"rate_limits": {"five_hour": {"used_percentage": N, "resets_at": unix},
    ///                   "seven_day": {...}}}`
    static func readStatuslineRateLimits(from urls: [URL]) -> [RateLimitReading] {
        var readings: [RateLimitReading] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
                  let limits = obj.obj("rate_limits") else { continue }

            let observedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                .flatMap { $0 } ?? Date()

            func window(_ key: String, minutes: Int) -> RateLimitWindowReading? {
                guard let w = limits.obj(key),
                      let percent = w.double("used_percentage") ?? w.double("used_percent") else { return nil }
                var resetsAt: Date?
                if let unix = w.double("resets_at") { resetsAt = Date(timeIntervalSince1970: unix) }
                return RateLimitWindowReading(usedPercent: percent, windowMinutes: minutes, resetsAt: resetsAt)
            }

            let primary = window("five_hour", minutes: 300)
            let secondary = window("seven_day", minutes: 10080)
            if primary != nil || secondary != nil {
                readings.append(RateLimitReading(providerId: "claude-code", observedAt: observedAt,
                                                 primary: primary, secondary: secondary,
                                                 planType: nil, sourcePath: url.path))
            }
        }
        return readings
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
