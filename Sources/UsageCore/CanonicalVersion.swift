import Foundation

/// 正式版號通道(prerelease channel)。穩定度 alpha < beta < rc < stable —— 同時是排序鍵的一段,
/// 也是 updater「通道下限」的依據(docs/release/VERSIONING.md §Ordering / §Updater channel policy)。
/// 注意:這是**發行通道**,與 Info.plist 的 `AIPetUsageBuildChannel`(release/source/dev = 建置來源)是兩回事。
public enum ReleaseChannel: String, Sendable, CaseIterable {
    case alpha, beta, rc, stable

    public var stabilityRank: Int {
        switch self {
        case .alpha: return 0
        case .beta: return 1
        case .rc: return 2
        case .stable: return 3
        }
    }
}

/// Canonical 發行版本(docs/release/VERSIONING.md 為規範來源)。
///
/// 文法(tag):`v` MAJOR `.` MINOR `.` PATCH [ `-` (alpha|beta|rc) `.` N ]
/// - 只接受 ASCII 數字;不得有前導零(單一 `0` 除外);N ≥ 1。
/// - 每個數字欄位最多 9 位(實作上限,與 `Scripts/release-version.sh`、Homebrew tap 的 jq 選擇器一致 ——
///   jq 的數字是 IEEE double,9 位內各實作的判定才能完全相同)。
/// - channel 只接受小寫;不接受 build metadata(`+…`)或任何其他 prerelease 識別字。
/// - **退役的 legacy `alpha-vX.Y.Z` 命名空間一律拒絕**:產品程式碼不含 legacy parser,legacy 版號不參與
///   canonical 排序、最新版挑選或任何版號產生。
///
/// 以逐位元組掃描實作(不用 regex):錨點、Unicode 數字(全形 / 阿拉伯-印度)、`Int("+1") == 1` 等
/// 跨引擎陷阱在結構上不存在。
public struct CanonicalVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// 每個數字欄位的位數上限(見型別註解)。
    public static let maxDigits = 9

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let channel: ReleaseChannel
    /// prerelease 的 N(≥ 1);stable 為 nil。
    public let iteration: Int?

    /// 解析 release **tag**(含前導 `v`)。不符文法 → nil(fail closed)。
    public init?(tag: String) {
        var s = ByteScanner(tag)
        guard s.consume("v"),
              let major = s.number(allowZero: true), s.consume("."),
              let minor = s.number(allowZero: true), s.consume("."),
              let patch = s.number(allowZero: true)
        else { return nil }
        var channel = ReleaseChannel.stable
        var iteration: Int?
        if !s.atEnd {
            guard s.consume("-") else { return nil }
            if s.consume("alpha") { channel = .alpha }
            else if s.consume("beta") { channel = .beta }
            else if s.consume("rc") { channel = .rc }
            else { return nil }
            guard s.consume("."), let n = s.number(allowZero: false) else { return nil }
            iteration = n
        }
        guard s.atEnd else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.channel = channel
        self.iteration = iteration
    }

    /// 解析顯示版號(tag 去掉 `v`,例如 `0.1.0-beta.1`、`0.1.0`)。與 tag 同一套文法。
    public init?(displayVersion: String) {
        self.init(tag: "v" + displayVersion)
    }

    /// `X.Y.Z`(= `CFBundleShortVersionString`)。
    public var core: String { "\(major).\(minor).\(patch)" }

    /// 顯示版號:`X.Y.Z` 或 `X.Y.Z-<channel>.<N>`(= Homebrew cask `version`)。
    public var displayVersion: String {
        guard let n = iteration else { return core }
        return "\(core)-\(channel.rawValue).\(n)"
    }

    /// canonical tag:`v` + 顯示版號。
    public var tag: String { "v" + displayVersion }

    /// alpha / beta / rc → true;stable → false(GitHub Release 的 `prerelease` 旗標必須與此一致)。
    public var isPrerelease: Bool { channel != .stable }

    /// 發行資產檔名:`AI-Pet-Usage-<tag>-arm64.zip`(tag 原樣、含 `v`)。
    public var assetName: String { "AI-Pet-Usage-\(tag)-arm64.zip" }

    public var description: String { tag }

    /// 排序鍵:(major, minor, patch, 通道穩定度, N)逐欄整數比較;stable 的 N 記為 0。
    /// core 先於通道:`v0.1.1-alpha.1 > v0.1.0`;同通道比 N 的數值:`.10 > .2`。
    var orderingKey: [Int] { [major, minor, patch, channel.stabilityRank, iteration ?? 0] }

    public static func < (a: CanonicalVersion, b: CanonicalVersion) -> Bool {
        a.orderingKey.lexicographicallyPrecedes(b.orderingKey)
    }
}

/// 只認 ASCII 的逐位元組掃描器(CanonicalVersion 專用)。
private struct ByteScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    var atEnd: Bool { index == bytes.count }

    mutating func consume(_ literal: String) -> Bool {
        let want = Array(literal.utf8)
        guard bytes.count - index >= want.count,
              bytes[index..<(index + want.count)].elementsEqual(want) else { return false }
        index += want.count
        return true
    }

    /// 十進位欄位:`0`(僅在 allowZero 時)或 `[1-9][0-9]{0,8}`;只吃 ASCII 0x30–0x39。
    mutating func number(allowZero: Bool) -> Int? {
        let start = index
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        let length = index - start
        guard length >= 1, length <= CanonicalVersion.maxDigits else { return nil }
        if bytes[start] == 0x30 {
            guard length == 1, allowZero else { return nil }   // 前導零 / N=0
            return 0
        }
        var value = 0
        for k in start..<index { value = value * 10 + Int(bytes[k] - 0x30) }
        return value
    }
}
