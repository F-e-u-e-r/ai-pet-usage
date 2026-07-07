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

    public init(enabledProviders: Set<String> = ["codex", "claude-code"],
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
/// 規則(規格要求):同一限額窗口內,較舊/較低的來源事件不得拉低已知百分比;
/// 只有窗口翻轉或全量重建索引才允許向下修正,且修正需標示。
public final class LimitEngine {

    struct PercentSample: Codable {
        var at: Date
        var percent: Double
    }

    struct PersistedWindow: Codable {
        var percent: Double
        var resetsAt: Date?
        var observedAt: Date
        var windowMinutes: Int
        var corrected: Bool
        var expiryHandled: Bool
        var history: [PercentSample]
    }

    struct PersistedProvider: Codable {
        var primary: PersistedWindow?
        var secondary: PersistedWindow?
        var planType: String?
        // Claude 估算窗口的重置偵測狀態
        var estimatedBlockEnd: Date?
        var estimatedBlockTokens: Int?
        var estimatedResetHandled: Bool?
    }

    private var store: [String: PersistedProvider]
    private let stateURL: URL?

    public init(stateURL: URL?) {
        self.stateURL = stateURL
        if let stateURL, let loaded = AtomicJSON.read([String: PersistedProvider].self, from: stateURL) {
            store = loaded
        } else {
            store = [:]
        }
    }

    private func save() {
        guard let stateURL else { return }
        try? AtomicJSON.write(store, to: stateURL)
    }

    /// 其他行程可能已寫入較新的限額狀態;寫入階段開始前重新載入以收斂。
    public func reloadFromDisk() {
        guard let stateURL, let loaded = AtomicJSON.read([String: PersistedProvider].self, from: stateURL) else { return }
        store = loaded
    }

    // MARK: - 讀值折疊

    /// 併入新的 rate-limit 讀值,回傳觸發的轉變(重置/跨閾值/耗盡)。
    public func ingest(readings: [RateLimitReading], settings: CoreSettings, fullReindex: Bool = false) -> [LimitTransition] {
        var transitions: [LimitTransition] = []
        let sorted = readings.sorted { $0.observedAt < $1.observedAt }
        for reading in sorted {
            var provider = store[reading.providerId] ?? PersistedProvider()
            if let plan = reading.planType { provider.planType = plan }
            if let w = reading.primary {
                provider.primary = fold(window: provider.primary, reading: w, observedAt: reading.observedAt,
                                        providerId: reading.providerId, windowName: "5h",
                                        settings: settings, fullReindex: fullReindex, transitions: &transitions)
            }
            if let w = reading.secondary {
                provider.secondary = fold(window: provider.secondary, reading: w, observedAt: reading.observedAt,
                                          providerId: reading.providerId, windowName: "weekly",
                                          settings: settings, fullReindex: fullReindex, transitions: &transitions)
            }
            store[reading.providerId] = provider
        }
        save()
        return transitions
    }

    private func fold(window stored: PersistedWindow?, reading: RateLimitWindowReading, observedAt: Date,
                      providerId: String, windowName: String, settings: CoreSettings,
                      fullReindex: Bool, transitions: inout [LimitTransition]) -> PersistedWindow {
        guard var current = stored else {
            return PersistedWindow(percent: reading.usedPercent, resetsAt: reading.resetsAt,
                                   observedAt: observedAt, windowMinutes: reading.windowMinutes,
                                   corrected: false, expiryHandled: false,
                                   history: [PercentSample(at: observedAt, percent: reading.usedPercent)])
        }

        let sameWindow = isSameWindow(current.resetsAt, reading.resetsAt)

        if sameWindow {
            let previous = current.percent
            if fullReindex {
                current.corrected = reading.usedPercent < previous - 0.5
                current.percent = reading.usedPercent
            } else {
                // 單調防護:同窗口內只允許上升(舊面板不得覆蓋新聚合值)。
                current.percent = max(previous, reading.usedPercent)
            }
            current.observedAt = max(current.observedAt, observedAt)
            if let r = reading.resetsAt { current.resetsAt = r }
            current.windowMinutes = reading.windowMinutes
            if current.percent > previous {
                appendCrossings(previous: previous, now: current.percent, providerId: providerId,
                                windowName: windowName, settings: settings, transitions: &transitions)
            }
            if observedAt >= current.observedAt || current.percent != previous {
                current.history.append(PercentSample(at: observedAt, percent: current.percent))
                if current.history.count > 48 { current.history.removeFirst(current.history.count - 48) }
            }
            return current
        }

        // 窗口不同:只接受更新的窗口(resetsAt 較晚);較舊窗口的殘留讀值一律忽略。
        let newIsLater: Bool
        switch (current.resetsAt, reading.resetsAt) {
        case let (a?, b?): newIsLater = b > a
        case (nil, _?): newIsLater = true
        case (_?, nil): newIsLater = observedAt > current.observedAt
        case (nil, nil): newIsLater = observedAt > current.observedAt
        }
        guard newIsLater else { return current }

        if current.percent >= 30, reading.usedPercent < current.percent - 20 {
            transitions.append(.reset(providerId: providerId, window: windowName))
        }
        return PersistedWindow(percent: reading.usedPercent, resetsAt: reading.resetsAt,
                               observedAt: observedAt, windowMinutes: reading.windowMinutes,
                               corrected: false, expiryHandled: false,
                               history: [PercentSample(at: observedAt, percent: reading.usedPercent)])
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
    public func sweepExpiredWindows(now: Date = Date()) -> [LimitTransition] {
        var transitions: [LimitTransition] = []
        for (providerId, var provider) in store {
            for keyPath in [\PersistedProvider.primary, \PersistedProvider.secondary] {
                guard var w = provider[keyPath: keyPath], let resetsAt = w.resetsAt,
                      resetsAt < now, !w.expiryHandled else { continue }
                if w.percent >= 30 {
                    transitions.append(.reset(providerId: providerId,
                                              window: keyPath == \PersistedProvider.primary ? "5h" : "weekly"))
                }
                w.expiryHandled = true
                if keyPath == \PersistedProvider.primary { provider.primary = w } else { provider.secondary = w }
            }
            store[providerId] = provider
        }
        save()
        return transitions
    }

    // MARK: - Claude 估算窗口的重置偵測

    /// 估算型(帳本推導)5h 區塊結束時觸發重置轉變。
    public func noteEstimatedBlock(providerId: String, blockEnd: Date?, blockTokens: Int, now: Date = Date()) -> [LimitTransition] {
        var provider = store[providerId] ?? PersistedProvider()
        var transitions: [LimitTransition] = []
        if let storedEnd = provider.estimatedBlockEnd, now > storedEnd,
           (provider.estimatedBlockTokens ?? 0) > 0, provider.estimatedResetHandled != true {
            transitions.append(.reset(providerId: providerId, window: "5h"))
            provider.estimatedResetHandled = true
        }
        if let blockEnd {
            if provider.estimatedBlockEnd != blockEnd { provider.estimatedResetHandled = false }
            provider.estimatedBlockEnd = blockEnd
            provider.estimatedBlockTokens = blockTokens
        }
        store[providerId] = provider
        save()
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
            return LimitWindowState(usedPercent: w.percent, resetAt: w.resetsAt,
                                    windowMinutes: w.windowMinutes, confidence: confidence,
                                    corrected: w.corrected)
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
            lastSourceDescription: lastEvent.map { "\($0.sourceKind) event at \(ISO8601.format($0.timestamp))" }
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

        let fiveTokens = block?.tokens ?? 0
        let fivePercent = percent(fiveTokens, budget: settings.claudeFiveHourTokenBudget)
        let fiveHour = LimitWindowState(
            usedPercent: fivePercent,
            usedTokens: fiveTokens,
            budgetTokens: settings.claudeFiveHourTokenBudget,
            resetAt: block?.end,
            windowMinutes: 300,
            confidence: settings.claudeFiveHourTokenBudget != nil ? .estimated : .unknown
        )
        let weeklyPercent = percent(weeklyTokens, budget: settings.claudeWeeklyTokenBudget)
        let weekly = LimitWindowState(
            usedPercent: weeklyPercent,
            usedTokens: weeklyTokens,
            budgetTokens: settings.claudeWeeklyTokenBudget,
            resetAt: nil, // 帳本無法得知官方週重置點;顯示為 rolling 7-day 估算
            windowMinutes: 10080,
            confidence: settings.claudeWeeklyTokenBudget != nil ? .estimated : .unknown
        )

        var projected: Date?
        if let budget = settings.claudeFiveHourTokenBudget, burn > 1000 {
            let remaining = Double(budget - fiveTokens)
            if remaining > 0 { projected = now.addingTimeInterval(remaining / burn * 3600) }
            else if fiveTokens >= budget { projected = now }
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
            planType: nil,
            lastSourceDescription: lastEvent.map { "\($0.sourceKind) event at \(ISO8601.format($0.timestamp))" }
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
