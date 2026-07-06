import Foundation
import UsageCore

// aipet:UsageCore 的無介面入口,供驗證與腳本使用。
//
// 行程安全設計:App 與 CLI 共用同一份本機資料。CLI 的 status/report 預設「唯讀」
// (直接渲染磁碟上的帳本與限額狀態,不掃描、不寫入),加上 --refresh 才會執行
// 寫入階段;所有寫入都由跨行程檔案鎖(refresh.lock)互斥。
//
// 用法:
//   aipet status [--refresh]              顯示各 provider 的限額與今日用量
//   aipet report [--refresh] [--out FILE] [--days N]   匯出 HTML 報告(預設今日)
//   aipet sources                         說明各 adapter 讀取哪些本機檔案
//   aipet reindex                         全量重建帳本索引(寫入,持鎖)

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "status"
let wantsRefresh = args.contains("--refresh")

func value(for flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else { return nil }
    return args[args.index(after: i)]
}

let dataDir = AppPaths.dataDirectory()
// 與 GUI 同源的設定(settings.json 的 core 欄位):預算、閾值、啟用的 provider。
let coordinator = UsageCoordinator(dataDir: dataDir, settings: CoreSettings.loadShared(dataDir: dataDir))

func fmtDate(_ d: Date?) -> String {
    guard let d else { return "—" }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"
    return df.string(from: d)
}

func fmtWindow(_ w: LimitWindowState) -> String {
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

let semaphore = DispatchSemaphore(value: 0)

Task {
    defer { semaphore.signal() }
    switch command {
    case "status", "report", "reindex":
        let start = Date()
        let mutating = wantsRefresh || command == "reindex"
        var headline: String

        let dash: DashboardState
        if mutating {
            let outcome = await coordinator.refresh(fullReindex: command == "reindex")
            dash = outcome.dashboard
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(start))
            headline = outcome.skipped
                ? "refresh skipped — another AI Pet Usage process holds the data lock; showing cached data"
                : "refresh \(elapsed), +\(outcome.insertedEvents) events"
        } else {
            dash = await coordinator.dashboard()
            headline = "cached local data (read-only; add --refresh to rescan provider logs)"
        }

        if command == "report" {
            let days = value(for: "--days").flatMap(Int.init)
            let kind: ReportKind
            if let days, days > 1 {
                kind = .range(.trailing(days: days), title: "Usage Report — last \(days) days")
            } else {
                kind = .today
            }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let defaultName = "AIPetUsage-Report-\(df.string(from: Date())).html"
            let out = value(for: "--out") ?? defaultName
            let url = URL(fileURLWithPath: out)
            do {
                try await coordinator.exportReport(kind: kind, to: url)
                print("report written: \(url.path)  (\(headline))")
            } catch {
                print("export failed: \(error)")
                exit(1)
            }
            return
        }

        print("AI Pet Usage — status (\(headline))")
        print(String(repeating: "─", count: 72))
        for snap in dash.snapshots {
            let limit = dash.limitStates.first { $0.providerId == snap.providerId }
            print("\(snap.displayName)  [\(snap.status.rawValue)]\(snap.errorMessage.map { "  error: \($0)" } ?? "")")
            if let limit {
                print("  5h:     \(fmtWindow(limit.fiveHour))")
                print("  weekly: \(fmtWindow(limit.weekly))")
                print("  burn: \(ReportGenerator.fmtTokens(Int(limit.burnRateTokensPerHour)))/h" +
                      (limit.projectedExhaustionAt.map { "  → limit at \(fmtDate($0))" } ?? "") +
                      (limit.planType.map { "  plan: \($0)" } ?? ""))
            }
            print("  today: \(ReportGenerator.fmtTokens(snap.tokenInput ?? 0)) in / \(ReportGenerator.fmtTokens(snap.tokenOutput ?? 0)) out / \(ReportGenerator.fmtTokens(snap.tokenCache ?? 0)) cache" +
                  "   last data: \(fmtDate(snap.updatedAt))")
        }
        print(String(repeating: "─", count: 72))
        print("today: \(ReportGenerator.fmtTokens(dash.todayTotals.total)) tokens, ~$\(String(format: "%.2f", dash.todayCost.knownUSD))" +
              (dash.todayCost.unknownModelTokens > 0 ? " (+\(ReportGenerator.fmtTokens(dash.todayCost.unknownModelTokens)) tokens unpriced)" : ""))
        if !dash.topProjects.isEmpty {
            print("top projects:")
            for p in dash.topProjects.prefix(5) {
                print(String(format: "  %-32s %10s  %5.1f%%", (p.projectName as NSString).utf8String!,
                             (ReportGenerator.fmtTokens(p.tokens.total) as NSString).utf8String!, p.shareOfPeriod * 100))
            }
        }
        if !dash.dataQuality.isEmpty {
            print("data quality:")
            for q in dash.dataQuality { print("  ⚠ \(q)") }
        }

    case "sources":
        for info in await coordinator.adapterInfos() {
            print("\(info.displayName) (\(info.providerId)) — available: \(info.availability.available), \(info.availability.detail)")
            print("  data: \(info.dataSources)")
            print("  permissions: \(info.permissions)")
        }

    default:
        print("usage: aipet [status|report|sources|reindex] [--refresh] [--out FILE] [--days N]")
    }
}

semaphore.wait()
