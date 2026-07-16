import Foundation
import UsageCore

// aipet:UsageCore 的無介面入口,供驗證與腳本使用。
//
// 行程安全設計:App 與 CLI 共用同一份本機資料。CLI 的 status/report 預設「唯讀」
// (直接渲染磁碟上的帳本與限額狀態,不掃描、不寫入),加上 --refresh 才會執行
// 寫入階段;所有寫入都由跨行程檔案鎖(refresh.lock)互斥。
//
// 用法:
//   aipet status [--refresh] [--full]     顯示各 provider 的限額與今日用量(預設抑制原始路徑/錯誤)
//   aipet report [--refresh] [--out FILE] [--days N]   匯出 HTML 報告(預設今日)
//   aipet sources [--full]                說明各 adapter 讀取哪些本機檔案(預設隱藏自訂根路徑)
//   aipet reindex                         全量重建帳本索引(寫入,持鎖)
//   aipet diag [--json] [--out FILE]      輸出 redacted 診斷(封閉詞彙,可安全貼進 issue;唯讀、無寫入)
//   aipet sprites [--out DIR]             匯出像素寵物 PNG contact sheets(預設 dist/sprite-preview)

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "status"
let wantsRefresh = args.contains("--refresh")
// status/sources 預設抑制原始路徑/錯誤原文(sink 政策見 StatusRenderer);--full 印原文。
let wantsFull = args.contains("--full")
if wantsFull, command == "status" || command == "sources" {
    FileHandle.standardError.write(
        "⚠ --full output may contain full local paths and raw provider/error text — don't paste it publicly.\n"
            .data(using: .utf8)!)
}

func value(for flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else { return nil }
    return args[args.index(after: i)]
}

let dataDir = AppPaths.dataDirectory()
// 與 GUI 同源的設定(settings.json 的 core 欄位):預算、閾值、啟用的 provider。
// diag 為純唯讀入口 → readOnly:不建立資料目錄(對不存在的目錄零副作用)。
let coordinator = UsageCoordinator(dataDir: dataDir, settings: CoreSettings.loadShared(dataDir: dataDir),
                                   readOnly: command == "diag")

/// diag `--out`:同目錄暫存檔以 0600 建立後,用 rename(2) 原子替換(mode 隨 rename 保留,無權限窗)。
func writeDiagAtomic(_ text: String, to url: URL) throws {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(".aipet-diag-\(ProcessInfo.processInfo.processIdentifier).tmp")
    // 清掉前次崩潰殘留的同名 tmp(含可能被植入的 symlink;removeItem 移除連結本身而非目標)。
    try? fm.removeItem(at: tmp)
    // O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW、mode 0600:獨佔建立、拒絕跟隨 symlink、建立即 0600(無權限窗)。
    let fd = open(tmp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw NSError(domain: "aipet", code: 1) }
    let bytes = Array(text.utf8)
    var ok = true
    bytes.withUnsafeBytes { buf in
        var written = 0
        while written < bytes.count {
            let n = write(fd, buf.baseAddress!.advanced(by: written), bytes.count - written)
            if n < 0 {
                if errno == EINTR { continue }   // 被訊號中斷 → 重試,不當失敗
                ok = false; break
            }
            if n == 0 { ok = false; break }
            written += n
        }
    }
    close(fd)
    guard ok else { try? fm.removeItem(at: tmp); throw NSError(domain: "aipet", code: 1) }
    // rename(2):原子替換,mode 隨檔案保留(0600)。
    if rename(tmp.path, url.path) != 0 {
        try? fm.removeItem(at: tmp)
        throw NSError(domain: "aipet", code: 1)
    }
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
            let fileName = "AIPetUsage-Report-\(df.string(from: Date())).html"
            let url: URL
            if let dir = value(for: "--out-dir") {
                // launchd 排程無法做 shell 日期展開,故由 CLI 於執行時產生檔名 + 建立資料夾。
                let dirURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                } catch {
                    print("export failed: cannot create --out-dir \(dirURL.path): \(error)")
                    exit(1)
                }
                url = dirURL.appendingPathComponent(fileName)
            } else if let out = value(for: "--out") {
                url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            } else {
                url = URL(fileURLWithPath: fileName)
            }
            do {
                try await coordinator.exportReport(kind: kind, to: url)
                print("report written: \(url.path)  (\(headline))")
            } catch {
                print("export failed: \(error)")
                exit(1)
            }
            return
        }

        // 渲染邏輯(含 sink 隱私政策)集中在 StatusRenderer(純函式、可測試)。
        print(StatusRenderer.statusText(dashboard: dash, headline: headline, full: wantsFull))

    case "diag":
        // 唯讀、無網路、無寫入(除非 --out)。輸出為封閉詞彙的 redacted 診斷,可安全貼進 issue。
        let now = Date()
        let dash = await coordinator.dashboard()
        let sources = await coordinator.diagnosticSourceStates(now: now)
        let info = Bundle.main.infoDictionary
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let app = DiagnosticAppInfo(
            version: info?["CFBundleShortVersionString"] as? String,
            channel: BuildChannel(known: info?["AIPetUsageBuildChannel"] as? String),
            os: "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
        )
        let report = DiagnosticReport.collect(dashboard: dash, sourceStates: sources,
                                              settings: await coordinator.currentSettings(),
                                              app: app, now: now)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let text = args.contains("--json") ? report.renderJSON(home: home) : report.renderText(home: home)
        if let out = value(for: "--out") {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            do { try writeDiagAtomic(text, to: url); print("diagnostic written") }
            catch { print("diagnostic write failed"); exit(1) }
        } else {
            print(text)
        }

    case "sources":
        print(StatusRenderer.sourcesText(infos: await coordinator.adapterInfos(), full: wantsFull))

    case "sprites":
        SpriteExport.run(outPath: value(for: "--out"))

    default:
        print("usage: aipet [status|report|sources|reindex|diag|sprites] [--refresh] [--full] [--out FILE|DIR] [--days N] [--json]")
        print("  --full   status/sources: print raw local paths and raw error text (default output suppresses them; not for public pasting either way — use `aipet diag` to share)")
    }
}

semaphore.wait()
