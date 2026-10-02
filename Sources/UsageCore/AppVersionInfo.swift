import Foundation

/// app 版本身分的**唯一**讀取點(docs/release/VERSIONING.md §Bundle):UpdateChecker、Grok / OpenRouter 的 UA 與
/// Grok kill 標記、`aipet diag` 都經此,不再各自讀 Info.plist。純值型別,輸入是注入的 Info 字典(可測)。
///
/// Info.plist 契約(由 `Scripts/write-info-plist.sh` 產生並驗證):
/// - `CFBundleShortVersionString` = `X.Y.Z`(Apple 要求純數字;絕不含 `-beta.N`)
/// - `AIPetUsageBuildChannel` = `release` / `source` / `dev`(**建置來源**,不是發行通道)
/// - `AIPetUsageReleaseTag` = 完整 canonical tag(如 `v0.1.0-beta.1`),**只有 release build 才有**
public struct AppVersionInfo: Sendable, Equatable {
    public static let releaseTagKey = "AIPetUsageReleaseTag"
    public static let buildChannelKey = "AIPetUsageBuildChannel"
    public static let shortVersionKey = "CFBundleShortVersionString"

    /// 建置來源;key 缺或值不認得 → nil。
    public let buildChannel: BuildChannel?
    /// `CFBundleShortVersionString` 原值(未驗證)。
    public let shortVersion: String?
    /// `AIPetUsageReleaseTag` 原值(未驗證)。
    public let releaseTag: String?
    /// updater 可拿來比較的 canonical 身分。**只有**格式正確的 release build 才非 nil:建置來源 = release、
    /// tag 符合 canonical 文法、且 tag 的 core == `CFBundleShortVersionString`。其餘一律 nil(fail closed:
    /// 不猜通道、不拿純數字版號頂替)。
    public let releaseVersion: CanonicalVersion?

    public init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        buildChannel = BuildChannel(known: info[Self.buildChannelKey] as? String)
        shortVersion = info[Self.shortVersionKey] as? String
        releaseTag = info[Self.releaseTagKey] as? String
        if buildChannel == .release, let tag = releaseTag, let v = CanonicalVersion(tag: tag), v.core == shortVersion {
            releaseVersion = v
        } else {
            releaseVersion = nil
        }
    }

    /// 執行中 app(或 app bundle 內的 `aipet`)的版本身分。
    public static var current: AppVersionInfo { AppVersionInfo(infoDictionary: Bundle.main.infoDictionary) }

    /// source / dev 建置:不做更新比對(維持既有語意)。
    public var isDevBuild: Bool { buildChannel == .source || buildChannel == .dev }

    /// 建置來源是 release,但 release 身分缺漏 / 不合法 / 與 core 不一致 → updater fail closed。
    public var hasMalformedReleaseMetadata: Bool { buildChannel == .release && releaseVersion == nil }

    /// 對外顯示 / UA / Grok kill 標記用的版本字串:合法 release 身分 → 其顯示版號(`0.1.0-beta.1`,
    /// 每個 prerelease 迭代都不同);否則 → 符合 core 文法的 `CFBundleShortVersionString`(source build 的 `0.0.0`);
    /// 都不成立 → nil(呼叫端自行決定後援字樣)。
    public var displayVersion: String? {
        if let v = releaseVersion { return v.displayVersion }
        if let short = shortVersion, let v = CanonicalVersion(displayVersion: short), v.channel == .stable {
            return short
        }
        return nil
    }
}
