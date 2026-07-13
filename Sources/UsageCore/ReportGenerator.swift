import Foundation

public struct ReportData: Sendable {
    public var title: String
    public var period: DateInterval
    public var generatedAt: Date
    public var timezoneName: String
    public var totals: TokenBreakdown
    public var cost: CostResult
    public var byProvider: [ProviderDaySummary]
    public var limitStates: [ProviderLimitState]
    public var projects: [ProjectSummary]
    public var models: [ModelUsageSummary]
    public var buckets: [(String, Int)]
    public var pricingRows: [ModelPrice]
    public var unknownModels: [(String, Int)]
    public var dataQuality: [String]
    public var petSummary: String?
    public var streak: UsageStreak
    public var dailyHeat: [DayBucket]

    public init(title: String, period: DateInterval, generatedAt: Date, timezoneName: String,
                totals: TokenBreakdown, cost: CostResult, byProvider: [ProviderDaySummary],
                limitStates: [ProviderLimitState], projects: [ProjectSummary], models: [ModelUsageSummary],
                buckets: [(String, Int)], pricingRows: [ModelPrice], unknownModels: [(String, Int)],
                dataQuality: [String], petSummary: String?,
                streak: UsageStreak = UsageStreak(current: 0, longest: 0),
                dailyHeat: [DayBucket] = []) {
        self.title = title
        self.period = period
        self.generatedAt = generatedAt
        self.timezoneName = timezoneName
        self.totals = totals
        self.cost = cost
        self.byProvider = byProvider
        self.limitStates = limitStates
        self.projects = projects
        self.models = models
        self.buckets = buckets
        self.pricingRows = pricingRows
        self.unknownModels = unknownModels
        self.dataQuality = dataQuality
        self.petSummary = petSummary
        self.streak = streak
        self.dailyHeat = dailyHeat
    }
}

/// 產出離線可讀、自足(內嵌 CSS、無外部資源、無必要 JavaScript)的靜態 HTML 報告。
/// 預設不包含提示詞、訊息內容或完整本機路徑(只顯示專案名稱)。
public enum ReportGenerator {

    public static func generateHTML(_ data: ReportData) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(data.title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <main>
        <header>
        <h1>🐾 \(esc(data.title))</h1>
        <p class="meta">Period: \(df.string(from: data.period.start)) → \(df.string(from: data.period.end))
        &nbsp;·&nbsp; Generated: \(df.string(from: data.generatedAt)) (\(esc(data.timezoneName)))</p>
        </header>
        """

        // 執行摘要
        let activeProjects = data.projects.count
        let activeAgents = data.byProvider.filter { $0.tokens.total > 0 }.count
        html += """
        <section>
        <h2>Summary</h2>
        <div class="tiles">
        \(tile("Total tokens", fmtTokens(data.totals.total)))
        \(tile("Estimated cost", fmtCost(data.cost)))
        \(tile("Active agents", "\(activeAgents)"))
        \(tile("Active projects", "\(activeProjects)"))
        \(tile("Cache read", fmtTokens(data.totals.cacheRead)))
        \(tile("Output tokens", fmtTokens(data.totals.output)))
        </div>
        </section>
        """

        // 各 agent 用量
        html += "<section><h2>Usage by coding agent</h2><table><thead><tr><th>Agent</th><th>Input</th><th>Output</th><th>Cache read</th><th>Cache write</th><th>Total</th><th>Est. cost</th></tr></thead><tbody>"
        for p in data.byProvider {
            html += "<tr><td>\(esc(p.displayName))</td><td>\(fmtTokens(p.tokens.input))</td><td>\(fmtTokens(p.tokens.output))</td><td>\(fmtTokens(p.tokens.cacheRead))</td><td>\(fmtTokens(p.tokens.cacheWrite))</td><td><strong>\(fmtTokens(p.tokens.total))</strong></td><td>\(fmtCost(p.cost))</td></tr>"
        }
        html += "</tbody></table></section>"

        // 限額狀態
        html += "<section><h2>Limit status</h2><table><thead><tr><th>Agent</th><th>Window</th><th>Used</th><th>Resets</th><th>Confidence</th><th>State</th></tr></thead><tbody>"
        for limit in data.limitStates {
            html += limitRow(providerId: limit.providerId, name: "5-hour", w: limit.fiveHour, warning: limit.warning, df: df)
            html += limitRow(providerId: limit.providerId, name: "Weekly", w: limit.weekly, warning: limit.warning, df: df)
        }
        html += "</tbody></table>"
        let corrected = data.limitStates.filter { $0.fiveHour.corrected || $0.weekly.corrected }
        if !corrected.isEmpty {
            html += "<p class=\"note\">⚠ Some usage percentages were corrected downward recently (confirmed official readings or a full reindex).</p>"
        }
        html += "</section>"

        // 專案表
        html += "<section><h2>Projects</h2><table><thead><tr><th>Project</th><th>Tokens</th><th>Est. cost</th><th>Agents</th><th>Top model</th><th>Last active</th><th>Share</th></tr></thead><tbody>"
        for p in data.projects {
            let last = p.lastActive.map { df.string(from: $0) } ?? "—"
            html += "<tr><td>\(esc(p.projectName))</td><td>\(fmtTokens(p.tokens.total))</td><td>\(fmtCost(p.cost))</td><td>\(esc(p.providers.joined(separator: ", ")))</td><td>\(esc(p.topModel ?? "—"))</td><td>\(last)</td><td>\(pct(p.shareOfPeriod * 100))</td></tr>"
        }
        if data.projects.isEmpty { html += "<tr><td colspan=\"7\">No usage in this period.</td></tr>" }
        html += "</tbody></table><p class=\"note\">Project names shown; full local paths are redacted by default.</p></section>"

        // 時間軸
        html += "<section><h2>Timeline</h2>"
        let maxTokens = max(1, data.buckets.map(\.1).max() ?? 1)
        if data.buckets.isEmpty {
            html += "<p class=\"note\">No activity in this period.</p>"
        } else {
            html += "<table class=\"chart\"><tbody>"
            for (label, tokens) in data.buckets {
                let width = max(1, Int(Double(tokens) / Double(maxTokens) * 100))
                html += "<tr><td class=\"lbl\">\(esc(label))</td><td class=\"barcell\"><div class=\"bar\" style=\"width:\(width)%\"></div></td><td class=\"val\">\(fmtTokens(tokens))</td></tr>"
            }
            html += "</tbody></table>"
        }
        html += "</section>"

        html += activitySection(data)

        // 模型與計價假設
        html += "<section><h2>Model pricing assumptions</h2><table><thead><tr><th>Model</th><th>Tokens</th><th>Est. cost</th><th>Input $/M</th><th>Output $/M</th><th>Cache read $/M</th><th>Source</th><th>Effective</th></tr></thead><tbody>"
        for m in data.models {
            let price = data.pricingRows.first {
                $0.providerId == m.providerId && ($0.modelId == m.modelId || ($0.modelId.hasSuffix("*") && m.modelId.hasPrefix(String($0.modelId.dropLast()))))
            }
            if let price {
                let override = price.userOverride ? " (user override)" : ""
                html += "<tr><td>\(esc(m.providerId))/\(esc(m.modelId))</td><td>\(fmtTokens(m.tokens.total))</td><td>\(fmtCost(m.cost))</td><td>\(money(price.inputPerMillion))</td><td>\(money(price.outputPerMillion))</td><td>\(price.cacheReadPerMillion.map(money) ?? "—")</td><td>\(esc(price.source))\(override)</td><td>\(esc(price.effectiveFrom))</td></tr>"
            } else {
                html += "<tr class=\"unknown\"><td>\(esc(m.providerId))/\(esc(m.modelId))</td><td>\(fmtTokens(m.tokens.total))</td><td>unknown model — excluded from cost</td><td colspan=\"5\">No pricing entry. Add a user override to include this model in cost totals.</td></tr>"
            }
        }
        html += "</tbody></table>"
        if !data.unknownModels.isEmpty {
            let total = data.unknownModels.reduce(0) { $0 + $1.1 }
            html += "<p class=\"note\">⚠ \(fmtTokens(total)) tokens across \(data.unknownModels.count) unknown model(s) are excluded from the cost total. The cost shown is a lower bound.</p>"
        }
        html += "</section>"

        // 資料品質
        html += "<section><h2>Data quality</h2>"
        if data.dataQuality.isEmpty {
            html += "<p class=\"note\">No parser errors or stale-data warnings on the last refresh.</p>"
        } else {
            html += "<ul>"
            for q in data.dataQuality { html += "<li>\(esc(q))</li>" }
            html += "</ul>"
        }
        html += """
        <p class="note">Values marked <em>estimated</em> derive from local token counts and configurable budgets,
        not from provider-reported percentages. <em>High</em> confidence limit rows come directly from
        provider-reported rate-limit data found in local logs.</p>
        </section>
        """

        if let pet = data.petSummary {
            html += "<section><h2>Pet summary</h2><p>\(esc(pet))</p></section>"
        }

        html += """
        <footer>
        <p>🔒 This report was generated locally by AI Pet Usage. No usage data leaves this machine.
        Prompts and message contents are never read or included.</p>
        </footer>
        </main>
        </body>
        </html>
        """
        return html
    }

    private static func limitRow(providerId: String, name: String, w: LimitWindowState, warning: WarningState, df: DateFormatter) -> String {
        var used = "—"
        if w.idle {
            used = "idle"
        } else if let p = w.usedPercent {
            used = pct(p)
            if let t = w.usedTokens, let b = w.budgetTokens {
                used += " (\(fmtTokens(t)) / \(fmtTokens(b)))"
            }
        } else if let t = w.usedTokens {
            used = "\(fmtTokens(t)) tokens (no budget set)"
        }
        var resets = w.idle ? "no active 5h window" : (w.resetAt.map { df.string(from: $0) } ?? "—")
        if name == "Weekly", w.resetAt == nil, w.usedTokens != nil {
            resets = "rolling 7-day"
        }
        let stateBadge: String
        switch warning {
        case .exhausted: stateBadge = "<span class=\"badge bad\">exhausted</span>"
        case .warning: stateBadge = "<span class=\"badge warn\">warning</span>"
        case .stale: stateBadge = "<span class=\"badge warn\">stale</span>"
        case .noData: stateBadge = "<span class=\"badge\">no data</span>"
        case .ok: stateBadge = "<span class=\"badge ok\">ok</span>"
        }
        return "<tr><td>\(esc(providerId))</td><td>\(name)</td><td>\(used)</td><td>\(resets)</td><td>\(w.confidence.rawValue)</td><td>\(stateBadge)</td></tr>"
    }

    // MARK: - 格式化

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// token 精簡格式,全 app 單一出處(Trends 的 tokenLabel 亦轉呼叫此處)。
    /// 進位溢位防護(codex R4):999,999,999/1e6 四捨五入成 "1,000.00M" —
    /// 係數格式化後若進位到 ≥1000,自動升一級單位("1.00B"),永不出現 1,000.xx 係數。
    public static func fmtTokens(_ n: Int) -> String {
        let d = Double(n)
        guard abs(d) >= 1_000 else { return "\(n)" }
        let units: [(divisor: Double, suffix: String, decimals: Int)] = [
            (1e3, "k", 1), (1e6, "M", 2), (1e9, "B", 2), (1e12, "T", 2),
        ]
        var index = units.lastIndex { abs(d) >= $0.divisor } ?? 0
        while index < units.count {
            let u = units[index]
            let body = grouped(d / u.divisor, decimals: u.decimals)
            if !body.hasPrefix("1,000") && !body.hasPrefix("-1,000") {
                return body + u.suffix
            }
            index += 1   // 係數被四捨五入進位到 1000 → 升級單位重算
        }
        let last = units[units.count - 1]
        return grouped(d / last.divisor, decimals: last.decimals) + last.suffix
    }

    /// 千分位數字 **單一出處**(R4 使用者提議的抽取):en_US_POSIX、固定 ,/.。
    /// fmtUSD / fmtTokens 皆為此函式的薄包裝;未來任何數字顯示直接呼叫。
    public static func grouped(_ value: Double, decimals: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.groupingSize = 3
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }

    /// 金額(千分位;R3 使用者要求全 app 一致):$1,234.56。分隔符固定 ","/"."
    /// (與 app 英文文案一致,不隨系統 locale 漂移)。
    public static func fmtUSD(_ value: Double, decimals: Int = 2) -> String {
        "$" + grouped(value, decimals: decimals)
    }

    static func fmtCost(_ c: CostResult) -> String {
        var s = fmtUSD(c.knownUSD)
        if c.unknownModelTokens > 0 { s += "+ (partial)" }
        else if c.isEstimated { s += " (est.)" }
        return s
    }

    static func money(_ v: Double) -> String { fmtUSD(v, decimals: 3) }
    static func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }

    private static let css = """
    :root { color-scheme: light dark; --fg:#1d2129; --bg:#ffffff; --muted:#667085; --line:#e5e8ee;
            --accent:#4d6bfe; --ok:#12805c; --warn:#b54708; --bad:#b42318; --tile:#f6f7fb; }
    @media (prefers-color-scheme: dark) {
      :root { --fg:#e6e9ef; --bg:#101318; --muted:#98a2b3; --line:#2a2f3a; --tile:#1a1f28;
              --ok:#3ccb95; --warn:#f7b27a; --bad:#f97066; }
    }
    * { box-sizing: border-box; }
    body { margin:0; font:15px/1.55 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
           color:var(--fg); background:var(--bg); }
    main { max-width: 920px; margin: 0 auto; padding: 32px 20px 48px; }
    h1 { font-size: 26px; margin: 0 0 4px; }
    h2 { font-size: 18px; margin: 32px 0 10px; border-bottom: 1px solid var(--line); padding-bottom: 6px; }
    .meta, .note { color: var(--muted); font-size: 13px; }
    .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 10px; }
    .tiles div { background: var(--tile); border-radius: 10px; padding: 12px 14px; }
    .tiles .k { font-size: 12px; color: var(--muted); }
    .tiles .v { font-size: 20px; font-weight: 650; margin-top: 2px; }
    table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
    th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font-weight: 600; font-size: 12px; }
    tr.unknown td { color: var(--warn); }
    .badge { display:inline-block; padding: 1px 8px; border-radius: 99px; font-size: 12px; background: var(--tile); }
    .badge.ok { color: var(--ok); } .badge.warn { color: var(--warn); } .badge.bad { color: var(--bad); }
    .chart td { border-bottom: none; padding: 2px 8px; }
    .chart .lbl { width: 110px; color: var(--muted); font-size: 12px; white-space: nowrap; }
    .chart .barcell { width: auto; }
    .chart .bar { background: var(--accent); border-radius: 4px; height: 12px; min-width: 2px; }
    .chart .val { width: 70px; text-align: right; font-size: 12px; color: var(--muted); }
    .heatwrap { overflow-x: auto; padding: 4px 0; }
    .heatmap { display: inline-grid; grid-auto-flow: column; grid-template-rows: repeat(7, 11px); gap: 3px; }
    .heatmap span { width: 11px; height: 11px; border-radius: 2px; }
    .heatmap .pad { background: transparent; }
    .heatmap .l0 { background: var(--line); }
    .heatmap .l1 { background: var(--accent); opacity: .30; }
    .heatmap .l2 { background: var(--accent); opacity: .50; }
    .heatmap .l3 { background: var(--accent); opacity: .72; }
    .heatmap .l4 { background: var(--accent); opacity: .95; }
    footer { margin-top: 40px; padding-top: 12px; border-top: 1px solid var(--line);
             color: var(--muted); font-size: 12.5px; }
    @media print { body { background: #fff; } main { max-width: none; padding: 0; } }
    """

    private static func tile(_ k: String, _ v: String) -> String {
        "<div><div class=\"k\">\(esc(k))</div><div class=\"v\">\(esc(v))</div></div>"
    }

    /// Activity section:使用連續天數 + 日曆熱圖(每格一天,依相對用量分 4 級上色)。
    private static func activitySection(_ data: ReportData) -> String {
        let cal = Calendar.current
        let s = data.streak
        var html = "<section><h2>Activity</h2>"
        html += "<p class=\"meta\">Current streak: <strong>\(s.current) day\(s.current == 1 ? "" : "s")</strong> · Longest: <strong>\(s.longest) day\(s.longest == 1 ? "" : "s")</strong></p>"
        guard data.period.duration > 48 * 3600, !data.dailyHeat.isEmpty else {
            return html + "</section>"
        }
        let byDay = Dictionary(data.dailyHeat.map { ($0.day, $0.tokens) }, uniquingKeysWith: +)
        let maxV = data.dailyHeat.map(\.tokens).max() ?? 0
        // period 為半開區間 [start, end);end 若正好落在午夜(排他邊界)需退一天,
        // 否則熱圖會多出一個範圍外的空格。取 end 前一瞬的當日即最後一個可能有事件的日。
        let lastDay = cal.startOfDay(for: data.period.end.addingTimeInterval(-1))
        // 熱圖最多顯示約一年,避免超長期間(如 all-time)產生巨大格點。
        let yearAgo = cal.date(byAdding: .day, value: -370, to: lastDay) ?? lastDay
        let firstDay = max(cal.startOfDay(for: data.period.start), yearAgo)
        let leadingPad = (cal.component(.weekday, from: firstDay) - cal.firstWeekday + 7) % 7
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        html += "<div class=\"heatwrap\"><div class=\"heatmap\">"
        for _ in 0..<leadingPad { html += "<span class=\"pad\"></span>" }
        var d = firstDay
        while d <= lastDay {
            let tokens = byDay[d] ?? 0
            let title = "\(df.string(from: d)) · \(fmtTokens(tokens)) tokens"
            html += "<span class=\"l\(heatLevel(tokens, maxV: maxV))\" title=\"\(esc(title))\"></span>"
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        html += "</div></div>"
        html += "<p class=\"note\">Each cell is one day; darker = more tokens (relative to the busiest day in range).</p></section>"
        return html
    }

    private static func heatLevel(_ tokens: Int, maxV: Int) -> Int {
        guard tokens > 0, maxV > 0 else { return 0 }
        let ratio = Double(tokens) / Double(maxV)
        if ratio > 0.66 { return 4 }
        if ratio > 0.33 { return 3 }
        if ratio > 0.10 { return 2 }
        return 1
    }
}
