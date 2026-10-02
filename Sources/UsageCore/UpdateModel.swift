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

/// app 更新的純邏輯(canonical 挑選、通道政策、分頁收集);決定性、無網路,供單元測試。
/// UI 與網路在 AIPetUsage 的 UpdateChecker(消費此模型)。規範:docs/release/VERSIONING.md。
public enum UpdateModel {
    // MARK: - 挑選

    /// 從 releases 挑「最適用的更新」。只看 canonical 版本線(legacy `alpha-v*` 與不合法 tag 一律忽略),
    /// 同時成立才算候選:
    /// - 非 draft;
    /// - tag 能以 canonical 文法解析;
    /// - GitHub 的 `prerelease` 旗標與 tag 的通道一致(alpha/beta/rc ⇔ true,stable ⇔ false;不一致 → 忽略);
    /// - **通道下限**:候選的通道穩定度 ≥ 已安裝 build 的通道(alpha → 全部;beta → beta/rc/stable;
    ///   rc → rc/stable;stable → 只有 stable)。跨 core 也適用:已裝 `v0.1.0` 不會被提示 `v0.2.0-alpha.1`;
    /// - 嚴格新於已安裝版本(canonical 語意排序,絕不依 API 回應順序或字串順序);
    /// - 嚴格新於 skip 下限 —— 跳過某版代表「該版**及更舊**都不再提示」。`skippedTag` 若不是 canonical
    ///   (例如舊版存在 UserDefaults 的 legacy `alpha-v0.4.0`)→ **忽略**,不解析進 canonical 排序。
    /// 多個候選取版本最高者。回傳 nil = 無可用更新。
    public static func latestApplicable(releases: [GitHubRelease], installed: CanonicalVersion,
                                        skippedTag: String?) -> GitHubRelease? {
        let skipFloor = skippedTag.flatMap { CanonicalVersion(tag: $0) }
        var best: (release: GitHubRelease, version: CanonicalVersion)?
        for r in releases where !r.draft {
            guard let v = CanonicalVersion(tag: r.tagName) else { continue }
            guard r.prerelease == v.isPrerelease else { continue }
            guard v.channel.stabilityRank >= installed.channel.stabilityRank else { continue }
            guard v > installed else { continue }
            if let floor = skipFloor, v <= floor { continue }
            if best == nil || v > best!.version { best = (r, v) }
        }
        return best?.release
    }

    // MARK: - 分頁收集(有界)

    /// 每頁筆數(GitHub 上限 100)。
    public static let releasesPerPage = 100
    /// 安全上限:最多抓 10 頁(1,000 個 release)。本專案遠低於此;上限保證每次檢查的請求數有界。
    /// 到上限時仍標示有下一頁 → 檢查失敗,不做更新決定(見 `collectReleases`)。
    public static let maxReleasePages = 10

    /// 固定端點上的第 `page` 頁(`per_page=100`)。
    public static func releasesPageURL(page: Int) -> URL {
        URL(string: "https://api.github.com/repos/F-e-u-e-r/ai-pet-usage/releases?per_page=\(releasesPerPage)&page=\(page)")!
    }

    public struct ReleasePage: Sendable {
        public let releases: [GitHubRelease]
        public let hasNextPage: Bool
        public init(releases: [GitHubRelease], hasNextPage: Bool) {
            self.releases = releases
            self.hasNextPage = hasNextPage
        }
    }

    /// 收集失敗:抓完 `maxPages` 頁時最後一頁仍標示有下一頁 —— 清單**已知不完整**,不得據以做更新決定
    ///(已知殘缺的集合被當成完整 = correctness 缺陷;owner 2026-10-02)。
    public enum CollectError: Error, Equatable, LocalizedError {
        case incompleteAtPageCap(maxPages: Int)

        public var errorDescription: String? {
            switch self {
            case .incompleteAtPageCap(let maxPages):
                return "The release list is longer than the \(maxPages)-page limit, so it can't be checked completely."
            }
        }
    }

    /// 依序抓第 1、2、… 頁,直到:沒有下一頁(回傳完整清單)、或達到 `maxPages`(有界終止)。空頁只要仍標示有
    /// 下一頁就繼續(契約只允許「沒有下一頁」或「達到上限」兩種停止條件;上限保證不會無限翻頁)。
    /// 只用「有沒有下一頁」這個訊號,**從不跟隨伺服器回傳的 URL**;頁碼一律由我方遞增、端點固定。
    /// 不以殘缺清單做決定:任一頁失敗 → throw;抓完第 `maxPages` 頁仍標示有下一頁(清單已知不完整)→ throw
    /// `CollectError.incompleteAtPageCap`(testCapReachedWithANextPageMakesNoDecision)。
    public static func collectReleases(maxPages: Int = maxReleasePages,
                                       fetchPage: (Int) async throws -> ReleasePage) async throws -> [GitHubRelease] {
        var all: [GitHubRelease] = []
        var page = 1
        while page <= maxPages {
            let result = try await fetchPage(page)
            all.append(contentsOf: result.releases)
            guard result.hasNextPage else { return all }
            page += 1
        }
        throw CollectError.incompleteAtPageCap(maxPages: maxPages)
    }

    /// RFC 8288 `Link` 標頭是否含 `rel="next"`(GitHub 分頁)。只回傳布林,不取出 URL。
    public static func linkHeaderHasNext(_ header: String?) -> Bool {
        guard let header else { return false }
        for link in header.split(separator: ",") {
            for param in link.split(separator: ";").dropFirst() {
                let parts = param.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "rel" else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if value.split(separator: " ").contains(where: { $0.lowercased() == "next" }) { return true }
            }
        }
        return false
    }
}
