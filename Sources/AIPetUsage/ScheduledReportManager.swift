import Foundation
import UsageCore

/// 管理每日排程匯出的 LaunchAgent:依設定寫入/移除 plist,並以 launchctl bootstrap/bootout
/// 載入卸載。用未簽名 dev build 可行的 launchctl(非 SMAppService.agent,後者留給簽名發佈)。
enum ScheduledReportManager {
    static let label = "dev.aipetusage.app.report"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// bundle 內 aipet 的絕對路徑(build-app.sh 會把 aipet 放進 Contents/MacOS/;
    /// 與主程式同目錄)。`swift run` 裸執行時找不到 → 回 nil。
    static var bundledAipetPath: String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let aipet = exe.deletingLastPathComponent().appendingPathComponent("aipet")
        return FileManager.default.isExecutableFile(atPath: aipet.path) ? aipet.path : nil
    }

    /// 只有 bundle 內附了 aipet 才可用(與 Notifier/LaunchAtLogin 一致的可用性判斷)。
    static var available: Bool { bundledAipetPath != nil }

    /// 依目前設定套用排程:先冪等卸載,啟用且路徑齊備才重寫 plist + 載入;否則移除 plist。
    /// app 啟動與設定變更時都呼叫,順帶修正 app 被移動後失效的絕對路徑。
    static func apply(settings: AppSettings) {
        unload()   // 冪等:先卸載舊 job
        guard settings.dailyExportEnabled,
              let program = bundledAipetPath,
              let folder = settings.dailyExportFolderPath, !folder.isEmpty else {
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        let env = ProcessInfo.processInfo.environment
        var extra: [String: String] = [:]
        if let v = env["CODEX_HOME"] { extra["CODEX_HOME"] = v }
        if let v = env["CLAUDE_CONFIG_DIR"] { extra["CLAUDE_CONFIG_DIR"] = v }
        let logDir = AppPaths.dataDirectory().path
        let spec = ScheduledReportSpec(
            label: label,
            programPath: program,
            days: settings.dailyExportRangeDays,
            outDir: (folder as NSString).expandingTildeInPath,
            hour: settings.dailyExportHour,
            minute: settings.dailyExportMinute,
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            stdoutLog: logDir + "/scheduled-report.out.log",
            stderrLog: logDir + "/scheduled-report.err.log",
            extraEnv: extra)
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(spec.plistXML().utf8).write(to: plistURL, options: .atomic)
            load()
        } catch {
            NSLog("AIPetUsage scheduled export: write plist failed: %@", String(describing: error))
        }
    }

    private static func load() { run(["bootstrap", "gui/\(getuid())", plistURL.path]) }
    private static func unload() { run(["bootout", "gui/\(getuid())/\(label)"]) }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        guard available || args.first == "bootout" else { return -1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
        catch { return -1 }
    }
}
