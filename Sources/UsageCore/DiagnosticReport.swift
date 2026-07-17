import Foundation

// MARK: - 封閉詞彙(closed vocabulary)
//
// 「redacted diagnostic」的隱私保證來自這裡:**任何執行期任意字串都不會進入報告**。
// 每個對外值都是封閉 enum、Bool、可空數字,或來自受控來源的日期;所有人類可讀標籤
// 都由本檔的**固定查表**產生(我方撰寫的字面量,不含任何執行期資料)。
// [[Redaction]].scrub 只是最後安全網,不是保證。

/// 只認得的 provider id;未知 id 一律丟棄(絕不回顯)。
public enum KnownProviderID: String, Codable, Sendable, CaseIterable {
    case codex
    case claudeCode = "claude-code"
    case grokCode = "grok-code"
    case antigravity
    public init?(known raw: String) { self.init(rawValue: raw) }
}

/// 建置通道(來自 Info.plist 的 AIPetUsageBuildChannel:source/dev/release)。未知 → nil。
public enum BuildChannel: String, Codable, Sendable {
    case source, dev, release
    public init?(known raw: String?) {
        guard let raw, let c = BuildChannel(rawValue: raw) else { return nil }
        self = c
    }
}

/// 活動時間一律**分桶**(避免以 generatedAt − age 反推你確切何時在工作)。
public enum AgeBucket: String, Codable, Sendable {
    case under5m = "<5m"
    case to30m = "5-30m"
    case to2h = "30m-2h"
    case to24h = "2-24h"
    case over1d = ">1d"
    public init(seconds: TimeInterval) {
        let s = max(0, seconds)
        switch s {
        case ..<(5 * 60): self = .under5m
        case ..<(30 * 60): self = .to30m
        case ..<(2 * 3600): self = .to2h
        case ..<(24 * 3600): self = .to24h
        default: self = .over1d
        }
    }
}

/// 來源檔狀態:fail-closed。無法讀取 ≠ 不存在;stat 失敗 → unknown(絕不當成 present)。
public enum SourceState: String, Codable, Sendable {
    case present, missing, unreadable, unknown
}

/// refresh 錯誤只以「有/無」表示——描述文字一律丟棄。
public enum DiagnosticErrorCode: String, Codable, Sendable {
    case refreshFailed
}

/// data-quality 訊息分類碼(由 app 自撰的固定樣板前綴分類;無法辨識 → other,不留任何文字)。
public enum QualityCode: String, Codable, Sendable {
    case refreshError
    case unparsableLines
    case historyKeptUnavailable
    case refreshSkippedLock
    case refreshSkippedInFlight
    case correctedRecently
    case staleReading
    case percentUnavailable
    case other
}

/// 蒐集層(有 I/O 的一端)回報的來源狀態;只有 id/state/mtime 分桶,絕無 URL。
public struct DiagnosticSourceState: Sendable {
    public var id: DiagnosticSourceID
    public var state: SourceState
    public var modifiedAge: AgeBucket?
    public init(id: DiagnosticSourceID, state: SourceState, modifiedAge: AgeBucket?) {
        self.id = id
        self.state = state
        self.modifiedAge = modifiedAge
    }
}

/// CLI 蒐集的 app/OS 資訊(受控:version 為我方注入的 semver,os 由數字元件組成)。
public struct DiagnosticAppInfo: Sendable {
    public var version: String?
    public var channel: BuildChannel?
    public var os: String
    public init(version: String?, channel: BuildChannel?, os: String) {
        self.version = version
        self.channel = channel
        self.os = os
    }
}

// MARK: - 報告(Encodable;只存封閉詞彙,絕不存 DashboardState/URL/Error/自由字串)

public struct DiagnosticReport: Encodable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var app: App
    public var settings: Settings
    public var providers: [Provider]
    public var sources: [Source]
    public var quality: [Quality]

    public struct App: Encodable, Sendable {
        public var version: String?
        public var channel: String?
        public var os: String
    }
    public struct Settings: Encodable, Sendable {
        public var enabledProviders: [String]
        public var warnPercent: Int
        public var dangerPercent: Int
        public var budgetsConfigured: Bool
    }
    public struct Provider: Encodable, Sendable {
        public var id: String
        public var displayName: String
        public var available: Bool
        public var status: String
        public var error: String?
        public var lastDataAge: String?
        public var input: Int?
        public var output: Int?
        public var cache: Int?
        public var fiveHour: Window?
        public var weekly: Window?
        enum CodingKeys: String, CodingKey {
            case id, displayName, available, status, error, lastDataAge, input, output, cache, fiveHour, weekly
        }
        // 顯式 encode(含 nil→null):缺資料一律 null,絕不省略成看似 0 或遺漏。
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(displayName, forKey: .displayName)
            try c.encode(available, forKey: .available)
            try c.encode(status, forKey: .status)
            try c.encode(error, forKey: .error)
            try c.encode(lastDataAge, forKey: .lastDataAge)
            try c.encode(input, forKey: .input)
            try c.encode(output, forKey: .output)
            try c.encode(cache, forKey: .cache)
            try c.encode(fiveHour, forKey: .fiveHour)
            try c.encode(weekly, forKey: .weekly)
        }
    }
    public struct Window: Encodable, Sendable {
        public var usedPercent: Double?
        public var confidence: String
        public var windowMinutes: Int
        public var resetInMinutes: Int?
        public var idle: Bool
        public var corrected: Bool
        enum CodingKeys: String, CodingKey {
            case usedPercent, confidence, windowMinutes, resetInMinutes, idle, corrected
        }
        // usedPercent / resetInMinutes 為 nil 時輸出 JSON null(idle/未知絕不變 0)。
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(usedPercent, forKey: .usedPercent)
            try c.encode(confidence, forKey: .confidence)
            try c.encode(windowMinutes, forKey: .windowMinutes)
            try c.encode(resetInMinutes, forKey: .resetInMinutes)
            try c.encode(idle, forKey: .idle)
            try c.encode(corrected, forKey: .corrected)
        }
    }
    public struct Source: Encodable, Sendable {
        public var id: String
        public var label: String
        public var state: String
        public var modifiedAge: String?
    }
    public struct Quality: Encodable, Sendable {
        public var code: String
        public var provider: String?
        public var count: Int?
    }

    // MARK: 固定標籤表(我方字面量,無執行期資料)

    static func displayName(_ id: KnownProviderID) -> String {
        switch id {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .grokCode: return "Grok Code"
        case .antigravity: return "Antigravity"
        }
    }
    /// 來源標籤是**正規預設路徑字面量**,不是解析後的真實路徑(即使有 CODEX_HOME 等覆寫,也只顯示這個)。
    static func sourceLabel(_ id: DiagnosticSourceID) -> String {
        switch id {
        case .codexSessions: return "~/.codex/sessions"
        case .codexArchived: return "~/.codex/archived_sessions"
        case .claudeProjects: return "~/.claude/projects"
        case .claudeStatuslineOurHook: return "~/Library/Application Support/AIPetUsage/claude-statusline.json"
        case .claudeStatuslineShared: return "~/.claude/usage-status.json"
        case .grokSessions: return "~/.grok/sessions"
        }
    }
    static func qualityText(_ code: QualityCode) -> String {
        switch code {
        case .refreshError: return "a refresh error occurred"
        case .unparsableLines: return "unparsable line(s) skipped on last scan"
        case .historyKeptUnavailable: return "history kept — provider unavailable during full reindex"
        case .refreshSkippedLock: return "refresh skipped — another process held the data lock"
        case .refreshSkippedInFlight: return "refresh skipped — a refresh was already in progress"
        case .correctedRecently: return "usage percent corrected downward recently"
        case .staleReading: return "rate-limit reading older than 6h; percent may lag"
        case .percentUnavailable: return "percent unavailable — run aipet install-hook or set a token budget"
        case .other: return "other data-quality note (details withheld)"
        }
    }
}

// MARK: - 純轉換:collect(...) 把已取得的資料折成封閉詞彙(無 I/O、無時鐘;now 由外部注入)

public extension DiagnosticReport {
    /// `dashboard` 與 `sourceStates` 由呼叫端(CLI)先取得;本函式不做 I/O,決定性:相同輸入+now ⇒ 相同輸出。
    static func collect(dashboard: DashboardState,
                        sourceStates: [DiagnosticSourceState],
                        settings: CoreSettings,
                        app: DiagnosticAppInfo,
                        now: Date) -> DiagnosticReport {
        // providers:未知 id 丟棄;依 id 排序。
        var providers: [Provider] = []
        for snap in dashboard.snapshots {
            guard let pid = KnownProviderID(known: snap.providerId) else { continue }
            let hasData = snap.status != .noData && snap.status != .unavailable
            let limit = dashboard.limitStates.first { $0.providerId == snap.providerId }
            providers.append(Provider(
                id: pid.rawValue,
                displayName: displayName(pid),
                available: snap.status != .unavailable,
                status: snap.status.rawValue,
                error: snap.errorMessage != nil ? DiagnosticErrorCode.refreshFailed.rawValue : nil,
                lastDataAge: snap.updatedAt.map { AgeBucket(seconds: now.timeIntervalSince($0)).rawValue },
                input: hasData ? snap.tokenInput : nil,
                output: hasData ? snap.tokenOutput : nil,
                cache: hasData ? snap.tokenCache : nil,
                fiveHour: limit.map { window($0.fiveHour, now: now) },
                weekly: limit.map { window($0.weekly, now: now) }
            ))
        }
        providers.sort { $0.id < $1.id }

        // sources:依 id 折疊(present > unreadable > missing > unknown),取較新的 mtime 分桶;依 id 排序。
        var byId: [DiagnosticSourceID: DiagnosticSourceState] = [:]
        for st in sourceStates {
            if let cur = byId[st.id] {
                byId[st.id] = foldSource(cur, st)
            } else {
                byId[st.id] = st
            }
        }
        let sources = byId.values
            .map { Source(id: $0.id.rawValue, label: sourceLabel($0.id),
                          state: $0.state.rawValue, modifiedAge: $0.modifiedAge?.rawValue) }
            .sorted { $0.id < $1.id }

        // quality:分類 app 自撰樣板 → 碼 + 選填 count/provider;依 (code, provider) 排序。
        var quality = dashboard.dataQuality.map(classifyQuality)
        // 完整標準鍵含 count,避免同 (code, provider) 但不同 count 的兩筆順序隨輸入而變。
        quality.sort {
            ($0.code, $0.provider ?? "", $0.count ?? -1) < ($1.code, $1.provider ?? "", $1.count ?? -1)
        }

        // enabledProviders 亦走封閉詞彙:未知 id(手改 settings.json)一律丟棄,不回顯任意字串。
        let enabled = settings.enabledProviders.compactMap { KnownProviderID(known: $0)?.rawValue }.sorted()
        return DiagnosticReport(
            schemaVersion: 1,
            generatedAt: now,
            app: App(version: sanitizedVersion(app.version), channel: app.channel?.rawValue, os: sanitizedOS(app.os)),
            settings: Settings(
                enabledProviders: enabled,
                warnPercent: Int(settings.warnThresholdPercent.rounded()),
                dangerPercent: Int(settings.dangerThresholdPercent.rounded()),
                budgetsConfigured: settings.claudeFiveHourTokenBudget != nil || settings.claudeWeeklyTokenBudget != nil
            ),
            providers: providers,
            sources: sources,
            quality: quality
        )
    }

    private static func window(_ w: LimitWindowState, now: Date) -> Window {
        // idle 恆為 nil(絕不造假 0%);非有限值 → nil。
        let pct: Double? = {
            guard !w.idle, let p = w.usedPercent, p.isFinite else { return nil }
            return p
        }()
        let resetIn: Int? = w.resetAt.map { max(0, Int(($0.timeIntervalSince(now) / 60).rounded())) }
        return Window(usedPercent: pct, confidence: w.confidence.rawValue,
                      windowMinutes: w.windowMinutes, resetInMinutes: resetIn,
                      idle: w.idle, corrected: w.corrected)
    }

    private static func foldSource(_ a: DiagnosticSourceState, _ b: DiagnosticSourceState) -> DiagnosticSourceState {
        func rank(_ s: SourceState) -> Int {
            switch s { case .present: return 3; case .unreadable: return 2; case .missing: return 1; case .unknown: return 0 }
        }
        let winner = rank(a.state) >= rank(b.state) ? a : b
        // mtime:取兩者中「較新」(較小的 age bucket 序)以反映最近活動。
        func ageRank(_ x: AgeBucket?) -> Int {
            switch x { case .under5m: return 0; case .to30m: return 1; case .to2h: return 2; case .to24h: return 3; case .over1d: return 4; case nil: return 5 }
        }
        let newer = ageRank(a.modifiedAge) <= ageRank(b.modifiedAge) ? a.modifiedAge : b.modifiedAge
        return DiagnosticSourceState(id: winner.id, state: winner.state, modifiedAge: newer)
    }

    /// 只認 app 自撰的固定樣板;比對後只留 enum + 選填整數 count + 選填已知 provider,**丟棄樣板以外的任何文字**。
    private static func classifyQuality(_ s: String) -> Quality {
        // 無 pid 前綴的兩種 refresh-skipped
        if s.hasPrefix("refresh skipped") {
            if s.contains("already in progress") { return Quality(code: QualityCode.refreshSkippedInFlight.rawValue, provider: nil, count: nil) }
            if s.contains("lock") { return Quality(code: QualityCode.refreshSkippedLock.rawValue, provider: nil, count: nil) }
            return Quality(code: QualityCode.other.rawValue, provider: nil, count: nil)
        }
        // "<pid>: <rest>" —— 只接受已知 pid;rest 以固定樣式比對
        guard let colon = s.range(of: ": ") else {
            return Quality(code: QualityCode.other.rawValue, provider: nil, count: nil)
        }
        let pidRaw = String(s[s.startIndex..<colon.lowerBound])
        let rest = String(s[colon.upperBound...])
        // 未知 pid → 一律 .other(不因尾巴像樣板就回傳已知碼)。
        guard let provider = KnownProviderID(known: pidRaw)?.rawValue else {
            return Quality(code: QualityCode.other.rawValue, provider: nil, count: nil)
        }
        if rest.hasPrefix("refresh error — ") {
            return Quality(code: QualityCode.refreshError.rawValue, provider: provider, count: nil)
        }
        if rest.hasPrefix("history kept") {
            return Quality(code: QualityCode.historyKeptUnavailable.rawValue, provider: provider, count: nil)
        }
        if rest.hasPrefix("percent unavailable") {
            return Quality(code: QualityCode.percentUnavailable.rawValue, provider: provider, count: nil)
        }
        if rest.hasPrefix("rate-limit reading is older than") {
            return Quality(code: QualityCode.staleReading.rawValue, provider: provider, count: nil)
        }
        // "<window> usage percent corrected downward — <cause> at <ABS TIME>":丟棄整個後綴(含絕對時間)。
        if rest.contains("usage percent corrected downward") {
            return Quality(code: QualityCode.correctedRecently.rawValue, provider: provider, count: nil)
        }
        // "<N> unparsable line(s) skipped on last scan"
        if rest.contains("unparsable line"), let n = leadingInt(rest) {
            return Quality(code: QualityCode.unparsableLines.rawValue, provider: provider, count: n)
        }
        return Quality(code: QualityCode.other.rawValue, provider: nil, count: nil)
    }

    private static func leadingInt(_ s: String) -> Int? {
        let digits = s.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// version 必須是我方注入的 semver(僅數字與點);否則視為未知,以維持「無任意執行期字串」。
    private static func sanitizedVersion(_ v: String?) -> String? {
        guard let v, !v.isEmpty else { return nil }
        let ok = v.allSatisfy { $0.isNumber || $0 == "." }
        return ok ? v : nil
    }

    /// os 由 ProcessInfo 的數字元件組成(如 "14.5.0");非「數字與點」一律視為 unknown。
    static func sanitizedOS(_ s: String) -> String {
        let ok = !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." }
        return ok ? s : "unknown"
    }
}

// MARK: - Render(text / JSON);最後一律過一次 [[Redaction]].scrub 當安全網

public extension DiagnosticReport {
    static func isoUTC() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    func renderJSON(home: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(DiagnosticReport.isoUTC().string(from: date))
        }
        guard let data = try? enc.encode(self), let raw = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        // JSON 已是封閉詞彙,不再過 scrub——對 JSON 字串做文字替換反而可能破壞跳脫/結構。
        // 隱私保證來自 collect 的封閉詞彙,leak 測試據此驗證(非靠 scrub)。
        _ = home
        return raw
    }

    func renderText(home: String) -> String {
        var L: [String] = []
        L.append("AI Pet Usage — diagnostic (schema \(schemaVersion), redacted)")
        L.append("generated: \(DiagnosticReport.isoUTC().string(from: generatedAt))")
        L.append("app: \(app.version ?? "unknown")\(app.channel.map { " (\($0))" } ?? "")   os: \(app.os)")
        L.append("settings: enabled=[\(settings.enabledProviders.joined(separator: ", "))] warn=\(settings.warnPercent)% danger=\(settings.dangerPercent)% budgets=\(settings.budgetsConfigured ? "set" : "none")")
        L.append(String(repeating: "─", count: 60))
        for p in providers {
            var head = "\(p.displayName) [\(p.status)]"
            if let e = p.error { head += "  error: \(e)" }
            if let a = p.lastDataAge { head += "  last data: \(a)" }
            L.append(head)
            if let w = p.fiveHour { L.append("  5h:     \(DiagnosticReport.windowLine(w))") }
            if let w = p.weekly { L.append("  weekly: \(DiagnosticReport.windowLine(w))") }
            if p.input != nil || p.output != nil || p.cache != nil {
                L.append("  today tokens: in=\(p.input.map(String.init) ?? "—") out=\(p.output.map(String.init) ?? "—") cache=\(p.cache.map(String.init) ?? "—")")
            }
        }
        L.append(String(repeating: "─", count: 60))
        L.append("sources:")
        for s in sources {
            L.append("  \(s.label)  [\(s.state)]\(s.modifiedAge.map { "  modified: \($0)" } ?? "")")
        }
        if !quality.isEmpty {
            L.append("data quality:")
            for q in quality {
                var line = "  \(DiagnosticReport.qualityText(QualityCode(rawValue: q.code) ?? .other))"
                if let pr = q.provider { line += " [\(pr)]" }
                if let c = q.count { line += " ×\(c)" }
                L.append(line)
            }
        }
        return Redaction.scrub(L.joined(separator: "\n"), home: home)
    }

    private static func windowLine(_ w: Window) -> String {
        var s = ""
        if w.idle {
            s += "idle (no active 5h window)"
        } else if let p = w.usedPercent {
            s += String(format: "%.1f%%", p)
        } else {
            s += "—"
        }
        s += "  (\(w.confidence), \(w.windowMinutes)m"
        if let r = w.resetInMinutes { s += ", resets in \(r)m" }
        if w.corrected { s += ", corrected" }
        s += ")"
        return s
    }
}
