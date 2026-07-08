import Foundation

/// launchd 排程匯出的純資料規格:由設定產生 LaunchAgent plist XML(可單元測試)。
/// launchctl 的實際 bootstrap/bootout 由 app 層(ScheduledReportManager)處理。
public struct ScheduledReportSpec: Sendable, Equatable {
    public var label: String
    public var programPath: String     // 絕對路徑到 bundle 內的 aipet
    public var days: Int
    public var outDir: String
    public var hour: Int               // 0-23
    public var minute: Int             // 0-59
    public var homePath: String
    public var stdoutLog: String
    public var stderrLog: String
    public var extraEnv: [String: String]   // 存在時傳遞 CODEX_HOME / CLAUDE_CONFIG_DIR

    public init(label: String, programPath: String, days: Int, outDir: String,
                hour: Int, minute: Int, homePath: String,
                stdoutLog: String, stderrLog: String, extraEnv: [String: String] = [:]) {
        self.label = label
        self.programPath = programPath
        self.days = max(1, days)
        self.outDir = outDir
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        self.homePath = homePath
        self.stdoutLog = stdoutLog
        self.stderrLog = stderrLog
        self.extraEnv = extraEnv
    }

    /// launchd 呼叫的完整參數(絕對路徑;launchd 環境稀疏,故不依賴 PATH/shell)。
    public var programArguments: [String] {
        [programPath, "report", "--refresh", "--days", String(days), "--out-dir", outDir]
    }

    /// 產生 launchd plist XML(所有字串值皆 XML-escape)。
    public func plistXML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let args = programArguments.map { "<string>\(esc($0))</string>" }.joined()
        var env = "<key>HOME</key><string>\(esc(homePath))</string>"
        for key in extraEnv.keys.sorted() {
            env += "<key>\(esc(key))</key><string>\(esc(extraEnv[key]!))</string>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(esc(label))</string>
            <key>ProgramArguments</key><array>\(args)</array>
            <key>StartCalendarInterval</key><dict><key>Hour</key><integer>\(hour)</integer><key>Minute</key><integer>\(minute)</integer></dict>
            <key>EnvironmentVariables</key><dict>\(env)</dict>
            <key>StandardOutPath</key><string>\(esc(stdoutLog))</string>
            <key>StandardErrorPath</key><string>\(esc(stderrLog))</string>
            <key>ProcessType</key><string>Background</string>
            <key>RunAtLoad</key><false/>
        </dict>
        </plist>
        """
    }
}
