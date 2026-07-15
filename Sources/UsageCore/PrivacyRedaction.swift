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
        let code = ["codex", "claude-code", "grok-code"].first { $0 == codePrefix }
        func prefixed(_ msg: String) -> String {
            if let code { return "\(code): \(msg)" }
            return msg
        }

        if lower.contains("unparsable line") {
            // fail-closed:**絕不** return raw(否則被塞入 "unparsable line SECRET /Users/…" 會原樣洩漏)。
            // 只結構化取出開頭整數 count,重建固定文字,其餘一律丟棄。
            let count = firstInt(raw)
            return prefixed(count.map { "\($0) unparsable line(s) skipped on last scan" }
                ?? "unparsable line(s) skipped on last scan")
        }
        if lower.contains("refresh error") { return prefixed("refresh error") }
        if lower.contains("history kept") { return prefixed("history kept (provider unavailable during reindex)") }
        if lower.contains("percent unavailable") {
            return prefixed("usage percent unavailable (install the statusline hook or set a token budget)")
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

    /// 取字串中第一段連續數字(供重建 count 用);無則 nil。
    static func firstInt(_ s: String) -> Int? {
        guard let range = s.range(of: "[0-9]+", options: .regularExpression) else { return nil }
        return Int(s[range])
    }
}
