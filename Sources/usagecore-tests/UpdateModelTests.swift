import Foundation
import UsageCore

final class UpdateModelTests: XCTestCase {
    func testParseVersionIsStrictAndFailsClosed() {
        XCTAssertEqual(UpdateModel.parseVersion("alpha-v0.1.2"), [0, 1, 2])
        XCTAssertEqual(UpdateModel.parseVersion("v1.2"), [1, 2])
        XCTAssertEqual(UpdateModel.parseVersion("0.1.10"), [0, 1, 10])
        // fail-closed:非「(前綴)N(.N)*」整段文法者一律 nil,不得誤當版本
        XCTAssertNil(UpdateModel.parseVersion("0.2.0-dev.5"), "帶 -dev 後綴非嚴格版本")
        XCTAssertNil(UpdateModel.parseVersion("docs-release-2026"), "任意數字子串不得被當版本")
        XCTAssertNil(UpdateModel.parseVersion("0.1.99999999999999999999"), "整數溢位須 fail closed,不得靜默丟段")
        XCTAssertNil(UpdateModel.parseVersion("no-numbers-here"))
        XCTAssertNil(UpdateModel.parseVersion(""))
    }

    func testIsNewerIsNumericNotLexical() {
        XCTAssertTrue(UpdateModel.isNewer([0, 1, 3], than: [0, 1, 2]))
        XCTAssertTrue(UpdateModel.isNewer([0, 2], than: [0, 1, 9]))
        XCTAssertTrue(UpdateModel.isNewer([0, 1, 10], than: [0, 1, 9]), "10 應大於 9(數值,非字典序)")
        XCTAssertFalse(UpdateModel.isNewer([0, 1, 2], than: [0, 1, 2]))
        XCTAssertFalse(UpdateModel.isNewer([0, 1, 2], than: [0, 1, 3]))
        XCTAssertFalse(UpdateModel.isNewer([0, 1], than: [0, 1, 0]), "缺段補 0:0.1 == 0.1.0")
    }

    func testLatestApplicableSkipSuppressesThatVersionAndOlder() {
        let releases = [
            GitHubRelease(tagName: "alpha-v0.1.2", prerelease: true),
            GitHubRelease(tagName: "alpha-v0.1.4", prerelease: true),
            GitHubRelease(tagName: "alpha-v0.1.5", draft: true),       // draft:不採
            GitHubRelease(tagName: "alpha-v0.1.3", prerelease: true),
            GitHubRelease(tagName: "alpha-v0.1.6", prerelease: true),
        ]
        // 無 skip:取最高的非 draft 且 > current → 0.1.6
        XCTAssertEqual(UpdateModel.latestApplicable(releases: releases, currentVersion: "0.1.2",
                                                    skippedTag: nil)?.tagName, "alpha-v0.1.6")
        // 跳過 0.1.4:抑制「0.1.4 及更舊」(含 0.1.3),但更新的 0.1.6 仍提示 —— 不再被更舊版打擾
        XCTAssertEqual(UpdateModel.latestApplicable(releases: releases, currentVersion: "0.1.2",
                                                    skippedTag: "alpha-v0.1.4")?.tagName, "alpha-v0.1.6")
        // 跳過最高的 0.1.6:全部 <= 0.1.6 被抑制 → nil
        XCTAssertNil(UpdateModel.latestApplicable(releases: releases, currentVersion: "0.1.2", skippedTag: "alpha-v0.1.6"))
        // current 已是最新可見版本 → nil
        XCTAssertNil(UpdateModel.latestApplicable(releases: releases, currentVersion: "0.1.6", skippedTag: nil))
        // current 無法解析(如原始碼建置的 sentinel 版本)→ nil(fail closed,不誤報)
        XCTAssertNil(UpdateModel.latestApplicable(releases: releases, currentVersion: "0.0.0-source", skippedTag: nil))
    }
}
