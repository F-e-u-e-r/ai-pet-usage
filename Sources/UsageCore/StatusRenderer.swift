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

    static func fmtWindow(_ w: LimitWindowState) -> String {
        if w.idle { return "   idle    (idle — no active 5h window)" }
        var out = ""
        if let p = w.usedPercent { out += String(format: "%5.1f%%", p) } else { out += "   — " }
        if let t = w.usedTokens {
            out += " [\(ReportGenerator.fmtTokens(t))"
            if let b = w.budgetTokens { out += "/\(ReportGenerator.fmtTokens(b))" }
            out += "]"
        }
        out += "  resets: \(fmtDate(w.resetAt))  (\(w.confidence.rawValue)\(w.corrected ? ", corrected" : ""))"
        return out
    }

    public static func statusText(dashboard dash: DashboardState, headline: String, full: Bool) -> String {
        var lines: [String] = []
        lines.append("AI Pet Usage — status (\(stripTerminalControls(headline)))")
        lines.append(String(repeating: "─", count: 72))
        for snap in dash.snapshots {
            let limit = dash.limitStates.first { $0.providerId == snap.providerId }
            let error: String
            if let raw = snap.errorMessage {
                // 錯誤原文可含完整路徑/任意 provider 文字 → 預設固定句;原文僅 --full(仍剝控制字元)。
                error = full ? "  error: \(stripTerminalControls(raw))"
                             : "  error: provider refresh failed (run with --full for the raw error)"
            } else {
                error = ""
            }
            lines.append("\(stripTerminalControls(snap.displayName))  [\(snap.status.rawValue)]\(error)")
            if let limit {
                lines.append("  5h:     \(fmtWindow(limit.fiveHour))")
                lines.append("  weekly: \(fmtWindow(limit.weekly))")
                lines.append("  burn: \(ReportGenerator.fmtTokens(Int(limit.burnRateTokensPerHour)))/h" +
                             (limit.projectedExhaustionAt.map { "  → limit at \(fmtDate($0))" } ?? "") +
                             (limit.planType.map { "  plan: \(safePlanLabel($0))" } ?? ""))
            }
            lines.append("  today: \(ReportGenerator.fmtTokens(snap.tokenInput ?? 0)) in / \(ReportGenerator.fmtTokens(snap.tokenOutput ?? 0)) out / \(ReportGenerator.fmtTokens(snap.tokenCache ?? 0)) cache" +
                         "   last data: \(fmtDate(snap.updatedAt))")
        }
        lines.append(String(repeating: "─", count: 72))
        lines.append("today: \(ReportGenerator.fmtTokens(dash.todayTotals.total)) tokens, ~\(ReportGenerator.fmtUSD(dash.todayCost.knownUSD))" +
                     (dash.todayCost.unknownModelTokens > 0 ? " (+\(ReportGenerator.fmtTokens(dash.todayCost.unknownModelTokens)) tokens unpriced)" : ""))
        if !dash.topProjects.isEmpty {
            lines.append("top projects:")
            for p in dash.topProjects.prefix(5) {
                // sink 端 fail-closed:即使上游已 basename,顯示前仍過 displayProjectName。
                let name = PrivacyRedaction.displayProjectName(
                    projectName: stripTerminalControls(p.projectName),
                    projectId: p.projectId)
                lines.append(String(format: "  %-32s %10s  %5.1f%%", (name as NSString).utf8String!,
                                    (ReportGenerator.fmtTokens(p.tokens.total) as NSString).utf8String!,
                                    p.shareOfPeriod * 100))
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
