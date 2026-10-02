import Foundation
import UsageCore

// AppVersionInfo — the single reader of the bundle's version identity (docs/release/VERSIONING.md §Bundle).
// Release builds: CFBundleShortVersionString = X.Y.Z, AIPetUsageBuildChannel = release, AIPetUsageReleaseTag =
// full canonical tag. Source/dev builds carry no AIPetUsageReleaseTag. Malformed release metadata fails closed.

private func info(short: String? = nil, channel: String? = nil, tag: String? = nil) -> [String: Any] {
    var d: [String: Any] = [:]
    if let short { d["CFBundleShortVersionString"] = short }
    if let channel { d["AIPetUsageBuildChannel"] = channel }
    if let tag { d["AIPetUsageReleaseTag"] = tag }
    return d
}

final class AppVersionInfoTests: XCTestCase {
    func testReleaseBuildWithCanonicalTagHasFullIdentity() {
        let v = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: "release", tag: "v0.1.0-beta.1"))
        XCTAssertEqual(v.releaseVersion?.tag, "v0.1.0-beta.1")
        XCTAssertEqual(v.releaseVersion?.channel, .beta)
        XCTAssertEqual(v.releaseVersion?.iteration, 1)
        XCTAssertEqual(v.displayVersion, "0.1.0-beta.1")
        XCTAssertEqual(v.buildChannel, .release)
        XCTAssertFalse(v.isDevBuild)
        XCTAssertFalse(v.hasMalformedReleaseMetadata)
        let stable = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: "release", tag: "v0.1.0"))
        XCTAssertEqual(stable.releaseVersion?.channel, .stable)
        XCTAssertEqual(stable.displayVersion, "0.1.0")
    }

    func testReleaseBuildWithMissingTagFailsClosed() {
        let v = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: "release"))
        XCTAssertNil(v.releaseVersion)
        XCTAssertTrue(v.hasMalformedReleaseMetadata)
        XCTAssertFalse(v.isDevBuild)
        XCTAssertEqual(v.displayVersion, "0.1.0", "display falls back to the numeric core")
    }

    func testReleaseBuildWithMalformedOrLegacyTagFailsClosed() {
        for bad in ["v0.1.0-beta.01", "v0.1.0-beta.0", "alpha-v0.4.0", "0.1.0-beta.1", "V0.1.0-beta.1", "", "v0.1.0-preview.1"] {
            let v = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: "release", tag: bad))
            XCTAssertNil(v.releaseVersion, "accepted malformed release tag [\(bad)]")
            XCTAssertTrue(v.hasMalformedReleaseMetadata, bad)
        }
    }

    func testReleaseTagWhoseCoreDisagreesWithShortVersionFailsClosed() {
        let v = AppVersionInfo(infoDictionary: info(short: "0.1.1", channel: "release", tag: "v0.1.0-beta.1"))
        XCTAssertNil(v.releaseVersion)
        XCTAssertTrue(v.hasMalformedReleaseMetadata)
        let missingShort = AppVersionInfo(infoDictionary: info(channel: "release", tag: "v0.1.0-beta.1"))
        XCTAssertNil(missingShort.releaseVersion)
    }

    func testSourceAndDevBuildsNeverCarryAReleaseIdentity() {
        for ch in ["source", "dev"] {
            let plain = AppVersionInfo(infoDictionary: info(short: "0.0.0", channel: ch))
            XCTAssertTrue(plain.isDevBuild)
            XCTAssertNil(plain.releaseVersion)
            XCTAssertFalse(plain.hasMalformedReleaseMetadata)
            XCTAssertEqual(plain.displayVersion, "0.0.0")
            // a stray tag on a non-release build is ignored, never promoted to a release identity
            let stray = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: ch, tag: "v0.1.0-beta.1"))
            XCTAssertNil(stray.releaseVersion)
            XCTAssertEqual(stray.displayVersion, "0.1.0")
        }
    }

    func testUnknownOrMissingBuildChannelHasNoReleaseIdentity() {
        let none = AppVersionInfo(infoDictionary: info(short: "0.4.0"))
        XCTAssertNil(none.buildChannel)
        XCTAssertNil(none.releaseVersion)
        XCTAssertFalse(none.isDevBuild)
        XCTAssertFalse(none.hasMalformedReleaseMetadata)
        let odd = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: "beta", tag: "v0.1.0-beta.1"))
        XCTAssertNil(odd.buildChannel, "release channel names are not build channels")
        XCTAssertNil(odd.releaseVersion)
        let empty = AppVersionInfo(infoDictionary: nil)
        XCTAssertNil(empty.displayVersion)
        XCTAssertNil(empty.releaseVersion)
    }

    func testDisplayVersionRejectsNonCanonicalShortVersion() {
        for short in ["0.1", "0.1.0-beta.1", "01.0.0", "０.1.0", "0.1.0 ", ""] {
            let v = AppVersionInfo(infoDictionary: info(short: short, channel: "source"))
            XCTAssertNil(v.displayVersion, "non-canonical CFBundleShortVersionString [\(short)] leaked into displayVersion")
        }
    }

    // G1: the Grok kill marker / UA identity must change between prerelease iterations of the same core.
    func testDisplayVersionDiffersAcrossPrereleaseIterations() {
        let b1 = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: "release", tag: "v0.1.0-beta.1"))
        let b2 = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: "release", tag: "v0.1.0-beta.2"))
        let rc = AppVersionInfo(infoDictionary: info(short: "0.1.0", channel: "release", tag: "v0.1.0-rc.1"))
        XCTAssertEqual(b1.shortVersion, b2.shortVersion, "precondition: same numeric core")
        XCTAssertTrue(b1.displayVersion != b2.displayVersion)
        XCTAssertTrue(b2.displayVersion != rc.displayVersion)
    }
}

/// Wiring guards for code usagecore-tests cannot execute (app target / CLI): every reader of the version identity
/// goes through AppVersionInfo. These pin wiring shape only; behavior is covered by the tests above.
final class VersionIdentityWiringGuardTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// No direct Info.plist version reads remain in the app target or the CLI.
    func testAppAndCLIReadVersionOnlyThroughAppVersionInfo() throws {
        let files = ["Sources/AIPetUsage/UpdateChecker.swift", "Sources/AIPetUsage/GrokQuotaChecker.swift",
                     "Sources/AIPetUsage/OpenRouterCreditsChecker.swift", "Sources/aipet/main.swift"]
        for f in files {
            let text = try source(f)
            XCTAssertFalse(text.contains("infoDictionary"), "\(f) reads Info.plist directly")
            XCTAssertFalse(text.contains("\"CFBundleShortVersionString\""), "\(f) reads CFBundleShortVersionString directly")
            XCTAssertFalse(text.contains("\"AIPetUsageBuildChannel\""), "\(f) reads AIPetUsageBuildChannel directly")
            XCTAssertTrue(text.contains("AppVersionInfo"), "\(f) must use AppVersionInfo")
        }
        let dirs = ["Sources/AIPetUsage", "Sources/aipet"]
        for d in dirs {
            let dir = repoRoot().appendingPathComponent(d)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            XCTAssertFalse(names.isEmpty, "no sources found under \(d)")
            for n in names where n.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)
                XCTAssertFalse(text.contains("\"CFBundleShortVersionString\""), "\(d)/\(n) reads the short version directly")
            }
        }
    }

    /// The Grok kill marker compares AppVersionInfo.displayVersion (changes per prerelease iteration).
    func testGrokKillMarkerUsesDisplayVersion() throws {
        let text = try source("Sources/AIPetUsage/GrokQuotaChecker.swift")
        XCTAssertTrue(text.contains("let currentVersion = AppVersionInfo.current.displayVersion ?? \"dev\""))
        XCTAssertTrue(text.contains("killedAtVersion.set(currentVersion)"))
    }

    /// The updater compares the canonical release identity and paginates through UpdateModel.
    func testUpdateCheckerUsesCanonicalIdentityAndBoundedPagination() throws {
        let text = try source("Sources/AIPetUsage/UpdateChecker.swift")
        XCTAssertTrue(text.contains("guard let installed = versionInfo.releaseVersion else"))
        XCTAssertTrue(text.contains("installed: installed"))
        XCTAssertTrue(text.contains("UpdateModel.collectReleases"))
        XCTAssertTrue(text.contains("UpdateModel.releasesPageURL(page: page)"))
        XCTAssertFalse(text.contains("api.github.com"), "the endpoint lives only in UpdateModel.releasesPageURL")
    }
}
