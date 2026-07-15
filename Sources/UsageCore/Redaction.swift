import Foundation

/// 診斷輸出的「最後安全網」——**不是**隱私保證(保證來自 `DiagnosticFacts` 的封閉詞彙:
/// 任何執行期任意字串都不會進入報告)。scrub 只是縱深防禦:萬一未來有欄位回歸成自由字串,
/// 這一層仍會把明顯的絕對路徑與 token 樣式塗掉。對一份「只含固定標籤 + enum + 數字」的
/// 正常診斷 JSON,scrub 是 no-op(不影響決定性)。
public enum Redaction {
    /// 把明顯會洩漏本機身分的片段塗掉:
    /// 1. 使用者家目錄前綴 → `~`(邊界安全:家目錄後必須是 `/` 或字串結尾,避免 alice 誤中 alice2)。
    /// 2. 其他絕對使用者路徑(`/Users/<name>/…`)→ `~/…`(去掉使用者名)。
    /// 3. 仍為絕對路徑的其餘常見掛載點(`/Volumes/…`、`/private/…`、`/opt/…`、`/tmp/…`)→ `‹redacted-path›`。
    /// 4. 明顯的密鑰樣式(`sk-…`、`xox[baprs]-…`、`Bearer <b64>`、長 hex/base64)→ `‹redacted-token›`。
    /// 冪等:scrub(scrub(x)) == scrub(x)。不動一般散文與數字。
    public static func scrub(_ s: String, home: String) -> String {
        var out = s

        // 1) 家目錄前綴 → ~(邊界安全)
        if !home.isEmpty {
            out = replaceHomePrefix(out, home: home)
        }

        // 2) /Users/<name>/… → ~/…(任何使用者,不只自己)
        out = regexReplace(out, pattern: "/Users/[^/\\s\"']+(/|$)", template: "~$1")

        // 3) 其餘絕對路徑(掛載點/系統暫存)→ ‹redacted-path›
        //    只吃「看起來是檔案路徑」的片段:掛載根 + 至少一段路徑。
        out = regexReplace(out, pattern: "/(Volumes|private|opt|tmp|var)/[^\\s\"']+", template: "‹redacted-path›")

        // 4) 密鑰樣式
        out = regexReplace(out, pattern: "sk-[A-Za-z0-9_-]{16,}", template: "‹redacted-token›")
        out = regexReplace(out, pattern: "xox[baprs]-[A-Za-z0-9-]{10,}", template: "‹redacted-token›")
        out = regexReplace(out, pattern: "(?i)bearer\\s+[A-Za-z0-9._-]{16,}", template: "‹redacted-token›")
        // 長 hex / base64 連續串(≥32,通常是金鑰/雜湊);保守起見要求整段被邊界包住。
        out = regexReplace(out, pattern: "(?<![A-Za-z0-9])[A-Fa-f0-9]{32,}(?![A-Za-z0-9])", template: "‹redacted-token›")
        out = regexReplace(out, pattern: "(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/])", template: "‹redacted-token›")

        return out
    }

    private static func replaceHomePrefix(_ s: String, home: String) -> String {
        // 邊界安全:只在 home 之後緊接 `/` 或結尾時替換,避免 `/Users/alice` 誤吃 `/Users/alice2`。
        let escaped = NSRegularExpression.escapedPattern(for: home)
        return regexReplace(s, pattern: escaped + "(/|$)", template: "~$1")
    }

    private static func regexReplace(_ s: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
