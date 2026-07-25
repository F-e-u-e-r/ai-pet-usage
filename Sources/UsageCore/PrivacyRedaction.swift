import Foundation

/// 可分享輸出(HTML 報告)的 **sink 端** 隱私護欄。原則:不信任 upstream 一定給了乾淨值,
/// sink 自己 fail-closed —— 即使 `projectName` 缺失/被塞入完整路徑、或 dataQuality 夾帶原始
/// 錯誤文字,也絕不把完整本機路徑或原始錯誤輸出到報告。與 [[Redaction]](診斷用網)互補。
public enum PrivacyRedaction {

    /// 報告用的專案顯示名:**永不**輸出完整本機路徑。
    /// 1. 非空、且不像路徑的 `projectName` → 原樣(修剪空白)。
    /// 2. `projectName` 像路徑(或空)→ 取 basename(`lastPathComponent`)。
    /// 3. 仍不安全/空 → `"Unnamed project"`。
    public static func displayProjectName(projectName: String?, projectId: String?) -> String {
        if let n = projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty, !looksLikePath(n) {
            return n
        }
        for candidate in [projectName, projectId] {
            guard let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { continue }
            let base = lastPathSegment(c)
            if !base.isEmpty, !looksLikePath(base) { return base }
        }
        return "Unnamed project"
    }

    /// 資料品質訊息的 sink 端保護:**真封閉詞彙 allowlist**。只認 app 自撰的固定樣板,
    /// 每個都對映到一句無路徑、無原始錯誤、無絕對時間的乾淨訊息;**無法辨識(含被塞入的
    /// 原始錯誤字串)一律 → 通用訊息**。與 `DiagnosticReport.classifyQuality` 同一組樣板意圖,
    /// 差別只在此處回傳人類可讀字串(診斷回傳 enum 碼)。
    public static func safeDataQuality(_ raw: String) -> String {
        let lower = raw.lowercased()
        // provider 短碼前綴(僅允許已知者;未知前綴不回顯)。codePrefix 保持**非 Optional**,
        // 否則 `$0 == codePrefix` 會把陣列推成 [String?]、`.first` 回傳 String??(雙層 Optional)。
        let codePrefix = (raw.components(separatedBy: ":").first ?? "").trimmingCharacters(in: .whitespaces)
        let code = ["codex", "claude-code", "grok-code", "opencode"].first { $0 == codePrefix }
        func prefixed(_ msg: String) -> String {
            if let code { return "\(code): \(msg)" }
            return msg
        }

        // 「refresh error」必須**最先**判:其 err 段是任意原文,可能內嵌其他樣板關鍵詞。
        // 例:`codex: refresh error — unparsable line at /Users/alice/client-88421/log` 若先判
        // unparsable,firstInt 會把路徑裡的 88421 當 count 回顯(路徑衍生識別碼外洩,codex SEV1)。
        if lower.contains("refresh error") { return prefixed("refresh error") }
        if lower.contains("unparsable line") {
            // fail-closed:**絕不** return raw(否則被塞入 "unparsable line SECRET /Users/…" 會原樣洩漏)。
            // count **位置化**擷取:只認「unparsable line」緊前的整數(app 樣板的固定位置),
            // 不掃全字串(任意處的數字可能來自被嵌入的路徑/錯誤文字)。
            let count = countBeforeUnparsable(raw)
            return prefixed(count.map { "\($0) unparsable line(s) skipped on last scan" }
                ?? "unparsable line(s) skipped on last scan")
        }
        if lower.contains("history kept") { return prefixed("history kept (provider unavailable during reindex)") }
        if lower.hasPrefix("state read failed") { return "State file unreadable — refresh skipped; existing data preserved" }
        if lower.hasPrefix("scan-state write failed") { return "State write failed — a rescan will reconcile next refresh" }
        if lower.contains("reindex incomplete") { return prefixed("reindex incomplete — history preserved") }
        if lower.contains("reindex kept cumulative") { return prefixed("reindex kept cumulative history (not rebuildable)") }
        if lower.contains("percent unavailable") {
            return prefixed("usage percent unavailable (run aipet install-hook or set a token budget)")
        }
        if lower.contains("rate-limit reading is older") { return prefixed("rate-limit reading is stale; percent may lag") }
        if lower.contains("corrected downward") {
            let window = lower.contains("weekly") ? "weekly " : (lower.contains("5h") || lower.contains("5-hour") ? "5-hour " : "")
            return prefixed("\(window)usage percent corrected downward")
        }
        if lower.hasPrefix("refresh skipped") {
            return lower.contains("in progress")
                ? "Refresh skipped: another refresh was already in progress"
                : "Refresh skipped: another process held the data lock"
        }
        // 未知/被注入的字串 → 通用訊息,絕不回傳原字串(fail-closed)。
        return "A data-quality note was recorded."
    }

    /// 「像本機路徑」判定(保守 / fail-closed):任何 `/` 或 `\` 區隔、`~` 開頭,或
    /// Windows 磁碟機前綴(`C:`)。涵蓋 POSIX / Windows / UNC,避免非 macOS 形狀的路徑漏出。
    static func looksLikePath(_ s: String) -> Bool {
        s.contains("/") || s.contains("\\") || s.hasPrefix("~")
            || s.range(of: "^[A-Za-z]:", options: .regularExpression) != nil
    }

    /// 取路徑最後一段(同時以 `/` 與 `\` 切),涵蓋 POSIX / Windows / UNC。
    static func lastPathSegment(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? ""
    }

    /// 取字串中第一段連續數字;無則 nil。
    static func firstInt(_ s: String) -> Int? {
        guard let range = s.range(of: "[0-9]+", options: .regularExpression) else { return nil }
        return Int(s[range])
    }

    /// 「unparsable line」**緊前**的整數(app 樣板 `N unparsable line(s)` 的固定位置);
    /// 其他位置的數字(如被嵌入路徑裡的)一律不取。
    static func countBeforeUnparsable(_ s: String) -> Int? {
        guard let r = s.range(of: #"[0-9]+\s+unparsable line"#,
                              options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = s[r]
        guard let d = match.range(of: "[0-9]+", options: .regularExpression) else { return nil }
        return Int(match[d])
    }

    /// 字串**任何位置**是否內嵌「絕對路徑形狀」(grok r2/r3 + codex catch-up 迭代)。兩道掃描:
    /// 1. **原字串**直接掃「分隔字元(或開頭)後緊接路徑起始」:`/x`、`~/`、`~user/`、`C:\`、
    ///    `\\`(UNC)。一般 URL 不會誤中(其 `/` 前是字母或 `//`,如 `https://example.com/docs`),
    ///    但 URL query 裡挾帶的本機路徑(`?local=/Users/…`)會被 `=` 分隔符抓到 —— 絕不可先把
    ///    URL 整串移除再掃(codex catch-up SEV1:`\S*` 會把 query 裡的路徑一併吞掉造成繞過)。
    /// 2. `file:` URL 剝掉 scheme+authority(`file:///…`、`file://localhost/…`)後**再掃一次**,
    ///    讓路徑主體受測。
    /// 不誤中:`vendor/model`、`anthropic.com/pricing`、`https://example.com/docs`、`~5 min`。
    static func containsAbsolutePath(_ s: String) -> Bool {
        let pathStart = #"(^|[\s=:'"`(<\[{])(/[^\s/]|~[/\\]|~[A-Za-z_][A-Za-z0-9_.\-]*[/\\]|[A-Za-z]:[/\\]|\\\\)"#
        if s.range(of: pathStart, options: .regularExpression) != nil { return true }
        let defiled = s.replacingOccurrences(of: #"(?i)\bfile://[^/\s]*"#,
                                             with: " ", options: .regularExpression)
        return defiled != s && defiled.range(of: pathStart, options: .regularExpression) != nil
    }

    /// 模型 ID 的 sink 端防護:合法 ID(`claude-fable-5`、`vendor/model` 相對形)原樣;
    /// 內嵌**絕對路徑形狀**的 ID(損壞/惡意日誌、覆寫檔筆誤、`file://` URL)→ basename。
    public static func displayModelId(_ s: String) -> String {
        guard containsAbsolutePath(s) else { return s }
        let base = lastPathSegment(s)
        return base.isEmpty ? "(redacted path)" : base
    }

    /// 描述性標籤(定價來源、effectiveFrom 等,含使用者覆寫檔的任意字串)的 sink 端防護:
    /// 內嵌絕對路徑(含 `file://` 形)→ 整串收斂為固定字樣(fail-closed;標籤只具參考性,
    /// 不值得為了保留部分字面而冒路徑外洩險)。合法內建標籤(`anthropic.com/pricing …`)不受影響。
    public static func safeLabel(_ s: String, fallback: String = "custom (path redacted)") -> String {
        containsAbsolutePath(s) ? fallback : s
    }
}
