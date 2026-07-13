import Foundation

/// GitHub Releases API 的最小子集(app 更新檢查用;純資料,不含網路/UI)。
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease
        case htmlURL = "html_url"
    }

    public init(tagName: String, name: String? = nil, body: String? = nil,
                draft: Bool = false, prerelease: Bool = false, htmlURL: String = "") {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.draft = draft
        self.prerelease = prerelease
        self.htmlURL = htmlURL
    }
}

/// app 更新的純邏輯(版本解析/比較/挑選);決定性、無網路,供單元測試。
/// UI 與網路在 AIPetUsage 的 UpdateChecker(消費此模型)。
public enum UpdateModel {
    /// 嚴格解析接受的版本文法:選配前綴 `alpha-v` / `v`,其後必須是**整段** `N(.N)*`。
    /// fail-closed:任何非此文法(如 `docs-release-2026`、`0.2.0-dev.5`)或整數溢位 → nil,
    /// 不得把可疑字串當成版本而誤報更新。
    public static func parseVersion(_ raw: String) -> [Int]? {
        var s = Substring(raw)
        for prefix in ["alpha-v", "v"] where s.hasPrefix(prefix) {
            s = s.dropFirst(prefix.count)
            break
        }
        guard s.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        var parts: [Int] = []
        for seg in s.split(separator: ".") {
            guard let n = Int(seg) else { return nil } // 溢位/異常 → fail closed
            parts.append(n)
        }
        return parts.isEmpty ? nil : parts
    }

    /// 數字版本比較(逐段;缺段補 0,故 0.1 == 0.1.0)。a 是否「嚴格新於」b。
    public static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }

    /// 從 releases 挑「最適用的更新」:非 draft、tag 版本嚴格新於 current、且未被 skip 抑制。
    /// **Skip 語意**:跳過某版本代表「該版本**及更舊**都不再提示」,只有**更新**的版本才提示
    ///(否則跳過 0.1.4 後隔天又被更舊的 0.1.3 打擾)。多個符合取版本最高者。
    /// 回傳 nil = 已是最新 / 無可用更新 / current 無法解析(fail closed)。
    public static func latestApplicable(releases: [GitHubRelease], currentVersion: String,
                                        skippedTag: String?) -> GitHubRelease? {
        guard let current = parseVersion(currentVersion) else { return nil }
        let skippedFloor = skippedTag.flatMap { parseVersion($0) }
        var best: (release: GitHubRelease, version: [Int])?
        for r in releases where !r.draft {
            guard let v = parseVersion(r.tagName), isNewer(v, than: current) else { continue }
            if let floor = skippedFloor, !isNewer(v, than: floor) { continue } // v <= 已跳過版本 → 抑制
            if best == nil || isNewer(v, than: best!.version) { best = (r, v) }
        }
        return best?.release
    }
}
