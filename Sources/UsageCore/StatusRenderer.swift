import Foundation

/// `aipet status` / `aipet sources` 的**純函式渲染器**(可測試;CLI main 只負責取數與列印)。
///
/// 隱私姿態(docs/DATA_BOUNDARY.md「Not share-hardened」):預設輸出**抑制原始本機路徑與原始
/// 錯誤文字**,但仍含專案 basename、方案標籤、用量數字與精確時間 —— **不是**公開張貼藝品;
/// `aipet diag` 與 HTML 報告才是 paste-hardened。`--full` 是本機除錯的原文出口(仍剝控制字元)。
///
/// Sink 守則(每個動態字串,**先剝控制字元、再過隱私政策、才輸出**;ESC 夾在路徑中不得
/// 破壞形狀偵測,ANSI/OSC/換行注入不得操縱終端):
/// - `planType`(provider 可控自由字串)→ strip → `safeLabel` → 24 字上限;
/// - 專案名 → strip → `PrivacyRedaction.displayProjectName`(sink 端 fail-closed,不信任上游);
/// - `errorMessage` → 固定句(原文僅 `--full`);
/// - `dataQuality` → `safeDataQuality`(原文僅 `--full`);
/// - `sources` 的根路徑 → `RootDisclosure`(內建固定標籤或 `custom root (…; details hidden)`;
///   原始 `detail` 僅 `--full`)。
public enum StatusRenderer {

    /// 移除 C0/C1 控制字元與 DEL(ESC 亦在內 → ANSI/OSC 序列失效,殘餘視為普通文字)。
    /// 換行/tab 一併移除:status 的動態欄位都是單行語義,注入換行可偽造輸出行。
    public static func stripTerminalControls(_ s: String) -> String {
        String(s.unicodeScalars.filter { u in
            !(u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value))
        })
    }

    /// 方案標籤 sink 政策:strip → safeLabel(絕對路徑形收斂)→ 上限 24 字(自由字串不得撐爆版面)。
    static func safePlanLabel(_ s: String) -> String {
        let cleaned = PrivacyRedaction.safeLabel(stripTerminalControls(s))
        return cleaned.count <= 24 ? cleaned : String(cleaned.prefix(23)) + "…"
    }

    static func fmtDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: d)
    }

    /// `reported limits:` / `estimated (your budget):` 行的 `5h:` 欄對齊欄位(左段補齊到此寬度)。
    private static let windowColumn = 51
    private static func padTo(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    /// provider-reported 窗的 CLI cell(封閉文案,`lowercased()`;§2.5 D28)。
    /// provided → `NN.N% (片段…[· corrected])`;非 provided → `主文`,次行非空才接 ` — 次行`;`corrected` 恆為括號內最後片段(chrome)。
    static func cliReportedCell(_ field: ReportedLimitField, cue: ReportedLimitCue, now: Date) -> String {
        let r = ReportedLimitText.render(field: field, cue: cue, now: now)
        let cell: String
        if r.gaugePercent != nil {
            var secondary = r.secondary
            if case .provided(_, _, _, true) = field {
                secondary = secondary.isEmpty ? "corrected" : secondary + " · corrected"
            }
            cell = secondary.isEmpty ? r.main : "\(r.main) (\(secondary))"
        } else {
            cell = r.secondary.isEmpty ? r.main : "\(r.main) — \(r.secondary)"
        }
        return cell.lowercased()
    }

    /// estimate 窗的 CLI cell(**不** `lowercased()`:token 單位後綴 M/B/T 與專有名詞須保留;inactive 窗顯 `—`)。
    static func cliEstimateCell(active: Bool, window: LimitWindowState, kind: LimitWindowKind, now: Date) -> String {
        guard active else { return "—" }
        let r = EstimateRowText.render(window: window, kind: kind, now: now)
        return r.secondary.isEmpty ? r.main : "\(r.main) (\(r.secondary))"
    }

    public static func statusText(dashboard dash: DashboardState, headline: String, full: Bool, now: Date) -> String {
        var lines: [String] = []
        lines.append("AI Pet Usage — status (\(stripTerminalControls(headline)))")
        lines.append(String(repeating: "─", count: 72))
        for snap in dash.snapshots {
            let limit = dash.limitStates.first { $0.providerId == snap.providerId }
            let reported = dash.reportedLimits.first { $0.providerId == snap.providerId }
            let error: String
            if let raw = snap.errorMessage {
                // 錯誤原文可含完整路徑/任意 provider 文字 → 預設固定句;原文僅 --full(仍剝控制字元)。
                error = full ? "  error: \(stripTerminalControls(raw))"
                             : "  error: provider refresh failed (run with --full for the raw error)"
            } else {
                error = ""
            }
            lines.append("\(stripTerminalControls(snap.displayName))  [\(snap.status.rawValue)]\(error)")
            // 本機觀測用量(原 today 行;與 provider-reported limits 分離,D14)
            lines.append("  " + padTo("local usage:", 19)
                         + "\(ReportGenerator.fmtTokens(snap.tokenInput ?? 0)) in / \(ReportGenerator.fmtTokens(snap.tokenOutput ?? 0)) out / \(ReportGenerator.fmtTokens(snap.tokenCache ?? 0)) cache"
                         + "   last data: \(fmtDate(snap.updatedAt))")
            // provider 回報的官方限額(四態投影;與本機用量是兩個資料域)
            if let reported {
                let left = "  " + padTo("reported limits:", 19)
                    + ReportedLimitText.cliSourceLabel(providerId: reported.providerId)
                let windows = "5h: " + cliReportedCell(reported.fiveHour, cue: reported.cue, now: now)
                    + "   weekly: " + cliReportedCell(reported.weekly, cue: reported.cue, now: now)
                lines.append(padTo(left, windowColumn) + windows)
                // 本機估算列(既有 Claude budget 估算):只 claude-code、至少一窗 active 時才輸出
                if reported.providerId == "claude-code",
                   reported.fiveHourEstimateActive || reported.weeklyEstimateActive, let limit {
                    let ewindows = "5h: " + cliEstimateCell(active: reported.fiveHourEstimateActive, window: limit.fiveHour, kind: .fiveHour, now: now)
                        + "   weekly: " + cliEstimateCell(active: reported.weeklyEstimateActive, window: limit.weekly, kind: .weekly, now: now)
                    lines.append(padTo("  estimated (your budget):", windowColumn) + ewindows)
                }
            }
            if let limit {
                lines.append("  burn: \(ReportGenerator.fmtTokens(Int(limit.burnRateTokensPerHour)))/h" +
                             (limit.projectedExhaustionAt.map { "  → limit at \(fmtDate($0))" } ?? "") +
                             (limit.planType.map { "  plan: \(safePlanLabel($0))" } ?? ""))
            }
        }
        lines.append(String(repeating: "─", count: 72))
        lines.append("today: \(ReportGenerator.fmtTokens(dash.todayTotals.total)) tokens, ~\(ReportGenerator.fmtUSD(dash.todayCost.knownUSD))" +
                     (dash.todayCost.unknownModelTokens > 0 ? " (+\(ReportGenerator.fmtTokens(dash.todayCost.unknownModelTokens)) tokens unpriced)" : ""))
        if !dash.topProjects.isEmpty {
            lines.append("top projects:")
            // Share 欄整組配額(‰;top-5 是截斷子集,「其餘」納入分母 —— 逐列獨立捨入
            // 的和可超過 100%,與 in/out/cache 同類缺陷;xcheck r1 twin)。
            let shown = Array(dash.topProjects.prefix(5))
            let mille = ReportGenerator.rowShares(rows: shown.map { $0.tokens.total },
                                                  periodTotal: dash.todayTotals.total, scale: 1000)
            for (i, p) in shown.enumerated() {
                // sink 端 fail-closed:即使上游已 basename,顯示前仍過 displayProjectName。
                // projectId 也必須先剝控制字元:name 不可用時 fallback 取其 basename,
                // raw ID 夾帶換行可偽造輸出行(codex impl-review SEV1)。
                let name = PrivacyRedaction.displayProjectName(
                    projectName: stripTerminalControls(p.projectName),
                    projectId: stripTerminalControls(p.projectId))
                lines.append(String(format: "  %-32s %10s  %6s", (name as NSString).utf8String!,
                                    (ReportGenerator.fmtTokens(p.tokens.total) as NSString).utf8String!,
                                    (ReportGenerator.milleLabel(mille[i], nonZero: p.tokens.total > 0) as NSString).utf8String!))
            }
        }
        if !dash.dataQuality.isEmpty {
            lines.append("data quality:")
            for q in dash.dataQuality {
                let cleaned = stripTerminalControls(q)
                lines.append("  ⚠ \(full ? cleaned : PrivacyRedaction.safeDataQuality(cleaned))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func sourcesText(
        infos: [(providerId: String, displayName: String, availability: ProviderAvailability,
                 dataSources: String, permissions: String)],
        full: Bool
    ) -> String {
        var lines: [String] = []
        for info in infos {
            let a = info.availability
            let rootLine: String
            switch a.disclosure {
            case .builtin(let label):
                rootLine = a.available ? "found \(label)" : "\(label) not found"
            case .custom:
                rootLine = a.available ? "custom root (found; details hidden)"
                                       : "custom root (not found; details hidden)"
            }
            lines.append("\(stripTerminalControls(info.displayName)) (\(info.providerId)) — available: \(a.available), \(rootLine)")
            if full {
                lines.append("  detail: \(stripTerminalControls(a.detail))")
            }
            lines.append("  data: \(info.dataSources)")
            lines.append("  permissions: \(info.permissions)")
        }
        return lines.joined(separator: "\n")
    }
}
