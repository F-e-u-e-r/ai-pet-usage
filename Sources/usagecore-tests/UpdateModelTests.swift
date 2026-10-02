import Foundation
import UsageCore

// Updater contract (docs/release/VERSIONING.md §Updater): canonical-only selection, prerelease-flag
// consistency, channel floor (installed alpha → all; beta → beta/rc/stable; rc → rc/stable; stable → stable),
// canonical skip floor, legacy values ignored, and bounded pagination (per_page=100, ≤ maxReleasePages pages;
// a next page still advertised at the cap fails the check).

private func ver(_ tag: String) -> CanonicalVersion { CanonicalVersion(tag: tag)! }

/// A release whose `prerelease` flag agrees with its tag unless explicitly overridden.
private func rel(_ tag: String, prerelease: Bool? = nil, draft: Bool = false) -> GitHubRelease {
    GitHubRelease(tagName: tag, draft: draft,
                  prerelease: prerelease ?? (CanonicalVersion(tag: tag)?.isPrerelease ?? true))
}

private func pick(_ releases: [GitHubRelease], installed: String, skipped: String? = nil) -> String? {
    UpdateModel.latestApplicable(releases: releases, installed: ver(installed), skippedTag: skipped)?.tagName
}

private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

/// Runs an async operation to completion from a synchronous test (same bridge the coordinator tests use).
private func runBlocking<T>(_ op: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await op()) } catch { box.value = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.value!.get()
}

/// Fake paginated endpoint. Records every requested page number.
private final class FakePages: @unchecked Sendable {
    let pages: [[GitHubRelease]]
    let forceNext: Bool
    private(set) var requested: [Int] = []

    init(_ pages: [[GitHubRelease]], forceNext: Bool = false) {
        self.pages = pages
        self.forceNext = forceNext
    }

    convenience init(list: [GitHubRelease], perPage: Int) {
        self.init(stride(from: 0, to: list.count, by: perPage).map { Array(list[$0..<min($0 + perPage, list.count)]) })
    }

    func page(_ n: Int) async throws -> UpdateModel.ReleasePage {
        requested.append(n)
        if requested.count > 50 { throw PageFailure() }   // test-side backstop: a broken cap fails instead of hanging
        let items = n >= 1 && n <= pages.count ? pages[n - 1] : []
        return UpdateModel.ReleasePage(releases: items, hasNextPage: forceNext || n < pages.count)
    }
}

private final class Counter: @unchecked Sendable { var n = 0 }
private struct PageFailure: Error {}

/// The `CollectError` a collection threw; nil if it returned or threw anything else.
private func collectError(_ op: @escaping () async throws -> [GitHubRelease]) -> UpdateModel.CollectError? {
    do {
        _ = try runBlocking(op)
        return nil
    } catch {
        return error as? UpdateModel.CollectError
    }
}

final class UpdateModelTests: XCTestCase {
    // MARK: - channel policy and ordering (F7)

    func testUpdateOfferedAlongTheChannelLadder() {
        XCTAssertEqual(pick([rel("v0.1.0-beta.2")], installed: "v0.1.0-beta.1"), "v0.1.0-beta.2")   // U1
        XCTAssertEqual(pick([rel("v0.1.0-rc.1")], installed: "v0.1.0-beta.2"), "v0.1.0-rc.1")       // U2
        XCTAssertEqual(pick([rel("v0.1.0")], installed: "v0.1.0-rc.1"), "v0.1.0")                   // U3
    }

    func testChannelFloorAppliesAcrossCoreVersions() {
        // installed stable → stable only (U4; owner example v0.1.0 → v0.2.0-alpha.1 = no prompt)
        XCTAssertNil(pick([rel("v0.1.1-alpha.1")], installed: "v0.1.0"))
        XCTAssertNil(pick([rel("v0.1.1-beta.1")], installed: "v0.1.0"))
        XCTAssertNil(pick([rel("v0.1.1-rc.1")], installed: "v0.1.0"))
        XCTAssertNil(pick([rel("v0.2.0-alpha.1")], installed: "v0.1.0"))
        XCTAssertEqual(pick([rel("v0.1.1")], installed: "v0.1.0"), "v0.1.1")
        // installed rc → rc / stable
        XCTAssertNil(pick([rel("v0.2.0-alpha.1"), rel("v0.2.0-beta.1")], installed: "v0.1.0-rc.1"))
        XCTAssertEqual(pick([rel("v0.2.0-rc.1")], installed: "v0.1.0-rc.1"), "v0.2.0-rc.1")
        // installed beta → beta / rc / stable (U15)
        XCTAssertNil(pick([rel("v0.2.0-alpha.1")], installed: "v0.1.0-beta.2"))
        XCTAssertEqual(pick([rel("v0.2.0-beta.1")], installed: "v0.1.0-beta.2"), "v0.2.0-beta.1")
        // installed alpha → alpha / beta / rc / stable (U14)
        XCTAssertEqual(pick([rel("v0.1.0-alpha.4")], installed: "v0.1.0-alpha.3"), "v0.1.0-alpha.4")
        XCTAssertEqual(pick([rel("v0.1.0-beta.1")], installed: "v0.1.0-alpha.3"), "v0.1.0-beta.1")
    }

    func testMalformedCanonicalTagsAreIgnored() {   // U5
        let releases = ["v0.1.0-beta.01", "v0.1.0-beta.x", "v0.1.0-preview.1", "v0.1.0-beta.0",
                        "V0.1.0-beta.3", "v0.1.0-BETA.3", "v0.1.0-beta.3+build"].map { rel($0, prerelease: true) }
            + [rel("v0.1.0.1", prerelease: false), rel("v1.0", prerelease: false), rel("1.0.0", prerelease: false)]
        XCTAssertNil(pick(releases, installed: "v0.1.0-beta.1"))
    }

    func testLegacyAlphaTagsNeverEnterCanonicalOrdering() {   // U6
        let legacy = [rel("alpha-v0.4.0", prerelease: true), rel("alpha-v9.9.9", prerelease: true),
                      rel("alpha-v9.9.9", prerelease: false), rel("beta-v1.0.0", prerelease: true)]
        XCTAssertNil(pick(legacy, installed: "v0.1.0-beta.1"))
        XCTAssertNil(pick(legacy, installed: "v0.1.0-alpha.1"))
        XCTAssertEqual(pick(legacy + [rel("v0.1.0-beta.2")], installed: "v0.1.0-beta.1"), "v0.1.0-beta.2")
    }

    func testPrereleaseFlagMustAgreeWithTagChannel() {   // U7
        XCTAssertNil(pick([rel("v0.1.0-beta.2", prerelease: false)], installed: "v0.1.0-beta.1"))
        XCTAssertNil(pick([rel("v0.1.0", prerelease: true)], installed: "v0.1.0-beta.1"))
        XCTAssertEqual(pick([rel("v0.1.0", prerelease: true), rel("v0.1.0-rc.1")], installed: "v0.1.0-beta.1"),
                       "v0.1.0-rc.1")
    }

    func testIterationOrderingIsNumericNotLexical() {   // U8
        XCTAssertEqual(pick([rel("v0.1.0-beta.9"), rel("v0.1.0-beta.10"), rel("v0.1.0-beta.3")],
                            installed: "v0.1.0-beta.2"), "v0.1.0-beta.10")
    }

    func testDraftsAreIgnored() {   // U9
        XCTAssertNil(pick([rel("v0.1.0-beta.2", draft: true)], installed: "v0.1.0-beta.1"))
        XCTAssertEqual(pick([rel("v0.1.0-beta.3", draft: true), rel("v0.1.0-beta.2")], installed: "v0.1.0-beta.1"),
                       "v0.1.0-beta.2")
    }

    func testCanonicalSkipSuppressesThatVersionAndOlder() {   // U10
        let releases = [rel("v0.1.0-beta.2"), rel("v0.1.0-beta.3")]
        XCTAssertEqual(pick(releases, installed: "v0.1.0-beta.1", skipped: "v0.1.0-beta.2"), "v0.1.0-beta.3")
        XCTAssertNil(pick(releases, installed: "v0.1.0-beta.1", skipped: "v0.1.0-beta.3"))
        XCTAssertEqual(pick(releases + [rel("v0.1.0-rc.1")], installed: "v0.1.0-beta.1", skipped: "v0.1.0-beta.3"),
                       "v0.1.0-rc.1")
    }

    func testLegacySkippedTagDoesNotSuppressCanonicalUpdates() {   // U11
        for legacy in ["alpha-v0.4.0", "alpha-v9.9.9", "0.4.0", "v0.4", "v9.9.9-preview.1", "garbage", ""] {
            XCTAssertEqual(pick([rel("v0.1.0-beta.2")], installed: "v0.1.0-beta.1", skipped: legacy), "v0.1.0-beta.2",
                           "skippedTag [\(legacy)] must be ignored, not parsed into canonical ordering")
        }
    }

    func testHighestApplicableWins() {   // U13
        XCTAssertEqual(pick([rel("v0.1.0-beta.2"), rel("v0.1.0"), rel("v0.1.0-rc.1")], installed: "v0.1.0-beta.1"),
                       "v0.1.0")
    }

    func testEqualOrOlderIsNotAnUpdate() {   // U16
        XCTAssertNil(pick([rel("v0.1.0-beta.1")], installed: "v0.1.0-beta.1"))
        XCTAssertNil(pick([rel("v0.0.9")], installed: "v0.1.0-beta.1"))
        XCTAssertNil(pick([rel("v0.1.0-alpha.9")], installed: "v0.1.0-beta.1"))
    }

    // MARK: - bounded pagination

    func testReleasesPageURLRequestsHundredPerPageOnFixedEndpoint() {
        XCTAssertEqual(UpdateModel.releasesPerPage, 100)
        XCTAssertEqual(UpdateModel.maxReleasePages, 10)
        XCTAssertEqual(UpdateModel.releasesPageURL(page: 1).absoluteString,
                       "https://api.github.com/repos/F-e-u-e-r/ai-pet-usage/releases?per_page=100&page=1")
        XCTAssertEqual(UpdateModel.releasesPageURL(page: 7).absoluteString,
                       "https://api.github.com/repos/F-e-u-e-r/ai-pet-usage/releases?per_page=100&page=7")
    }

    /// (1) The applicable stable is found even behind > 30 (here 130) newer prereleases, on a later page.
    func testStableFoundBehindManyNewerPrereleasesAcrossPages() throws {
        var list = (1...130).reversed().map { rel("v0.2.0-beta.\($0)") }   // API order: newest created first
        list.append(rel("v0.1.1"))
        list.append(rel("v0.1.0"))
        let fake = FakePages(list: list, perPage: 100)
        let all = try runBlocking { try await UpdateModel.collectReleases(fetchPage: fake.page) }
        XCTAssertEqual(fake.requested, [1, 2])
        XCTAssertEqual(all.count, 132)
        XCTAssertEqual(pick(all, installed: "v0.1.0"), "v0.1.1", "stable install must find the stable on page 2")
        XCTAssertEqual(pick(all, installed: "v0.2.0-beta.1"), "v0.2.0-beta.130")
    }

    /// (2) Version ordering is semantic, never the API response order.
    func testSelectionIgnoresApiResponseOrder() throws {
        let apiOrder = [rel("v0.1.1"), rel("v0.2.0"), rel("v0.1.10"), rel("v0.1.9")]   // an older-line hotfix listed first
        XCTAssertEqual(pick(apiOrder, installed: "v0.1.0"), "v0.2.0")
        XCTAssertEqual(pick(apiOrder.reversed(), installed: "v0.1.0"), "v0.2.0")
        let fake = FakePages(list: apiOrder, perPage: 1)
        let all = try runBlocking { try await UpdateModel.collectReleases(fetchPage: fake.page) }
        XCTAssertEqual(fake.requested, [1, 2, 3, 4])
        XCTAssertEqual(pick(all, installed: "v0.1.0"), "v0.2.0")
    }

    /// (3) Pagination is bounded by the safety cap even if the server always claims a next page, and reaching the
    /// cap while a next page is still advertised FAILS the check: the fetched set is known to be incomplete.
    func testPaginationTerminatesAtTheSafetyCap() throws {
        let calls = Counter()
        let endless: (Int) async throws -> UpdateModel.ReleasePage = { page in
            calls.n += 1
            if calls.n > 50 { throw PageFailure() }   // test-side backstop: a broken cap fails instead of hanging
            return UpdateModel.ReleasePage(releases: (1...100).map { rel("v0.1.0-beta.\(page * 1000 + $0)") },
                                           hasNextPage: true)
        }
        XCTAssertEqual(collectError { try await UpdateModel.collectReleases(fetchPage: endless) },
                       .incompleteAtPageCap(maxPages: UpdateModel.maxReleasePages))
        XCTAssertEqual(calls.n, UpdateModel.maxReleasePages)
        calls.n = 0
        XCTAssertEqual(collectError { try await UpdateModel.collectReleases(maxPages: 3, fetchPage: endless) },
                       .incompleteAtPageCap(maxPages: 3))
        XCTAssertEqual(calls.n, 3)
    }

    /// Owner 2026-10-02: ten full pages with page 10 still advertising `rel="next"` are a KNOWN partial set and must
    /// not be treated as complete — the applicable stable on page 11 would be missed ("up to date", or a lower
    /// release offered). No update decision is made; page 11 is never requested.
    func testCapReachedWithANextPageMakesNoDecision() throws {
        let list = (1...1000).reversed().map { rel("v0.1.0-beta.\($0)") } + [rel("v0.2.0")]   // v0.2.0 on page 11
        let capped = FakePages(list: list, perPage: 100)
        XCTAssertEqual(collectError { try await UpdateModel.collectReleases(fetchPage: capped.page) },
                       .incompleteAtPageCap(maxPages: UpdateModel.maxReleasePages))
        XCTAssertEqual(capped.requested, Array(1...UpdateModel.maxReleasePages))
        XCTAssertEqual(pick(list, installed: "v0.1.0"), "v0.2.0", "the complete set has an applicable stable")
        // Boundary: exactly ten full pages with NO next link on page 10 is a complete set.
        let exact = FakePages(list: Array(list.prefix(1000)), perPage: 100)
        let all = try runBlocking { try await UpdateModel.collectReleases(fetchPage: exact.page) }
        XCTAssertEqual(exact.requested, Array(1...UpdateModel.maxReleasePages))
        XCTAssertEqual(all.count, 1000)
        XCTAssertEqual(pick(all, installed: "v0.1.0-beta.1"), "v0.1.0-beta.1000")
    }

    /// (4) Malformed / legacy pages cannot change the selected canonical result.
    func testMalformedAndLegacyPagesCannotChangeSelection() throws {
        let base = [rel("v0.1.0-beta.2"), rel("v0.1.0-rc.1")]
        let noise: [GitHubRelease] =
            ["alpha-v9.9.9", "alpha-v0.4.0", "v9.9.9-preview.1", "v09.0.0", "V9.9.9", "v9.9.9-beta.0",
             "v9.9.9-BETA.1", "v9.9.9+build"].map { rel($0, prerelease: false) }
            + [rel("v9.9.9", prerelease: true), rel("v9.9.9-rc.1", prerelease: false), rel("v9.9.9", draft: true)]
        let fake = FakePages([noise, base, Array(noise.reversed())])
        let all = try runBlocking { try await UpdateModel.collectReleases(fetchPage: fake.page) }
        XCTAssertEqual(fake.requested, [1, 2, 3])
        XCTAssertEqual(pick(base, installed: "v0.1.0-beta.1"), "v0.1.0-rc.1")
        XCTAssertEqual(pick(all, installed: "v0.1.0-beta.1"), "v0.1.0-rc.1")
        XCTAssertNil(pick(noise, installed: "v0.1.0-alpha.1"), "noise alone selects nothing")
    }

    /// The only stop conditions are "no next page" and the cap (§1): an empty page that still advertises a
    /// next page does not end the walk, and reaching the cap with a next page still advertised fails the check.
    func testPaginationStopsOnlyWithoutANextPageOrAtTheCap() throws {
        let twoPages = FakePages([[rel("v0.1.0-beta.2")], [rel("v0.1.0-beta.3")]])
        _ = try runBlocking { try await UpdateModel.collectReleases(fetchPage: twoPages.page) }
        XCTAssertEqual(twoPages.requested, [1, 2], "the page without a next link ends the walk")
        let gap = FakePages([[rel("v0.1.1")], [], [rel("v0.2.0")]])
        let all = try runBlocking { try await UpdateModel.collectReleases(fetchPage: gap.page) }
        XCTAssertEqual(gap.requested, [1, 2, 3], "an empty page that advertises a next page does not end the walk")
        XCTAssertEqual(all.map(\.tagName), ["v0.1.1", "v0.2.0"])
        XCTAssertEqual(UpdateModel.latestApplicable(releases: all, installed: ver("v0.1.0"), skippedTag: nil)?.tagName,
                       "v0.2.0")
        let emptyFirst = FakePages([[], [rel("v0.1.1")]])
        let found = try runBlocking { try await UpdateModel.collectReleases(fetchPage: emptyFirst.page) }
        XCTAssertEqual(emptyFirst.requested, [1, 2])
        XCTAssertEqual(found.map(\.tagName), ["v0.1.1"])
        let allEmpty = FakePages([[]], forceNext: true)   // every page empty, a next page always advertised
        XCTAssertEqual(collectError { try await UpdateModel.collectReleases(fetchPage: allEmpty.page) },
                       .incompleteAtPageCap(maxPages: UpdateModel.maxReleasePages),
                       "a next page still advertised at the cap fails the check")
        XCTAssertEqual(allEmpty.requested, Array(1...UpdateModel.maxReleasePages), "the cap still bounds an all-empty walk")
    }

    func testAFailedPageFailsTheWholeCheck() {
        let failing: (Int) async throws -> UpdateModel.ReleasePage = { page in
            if page == 2 { throw PageFailure() }
            return UpdateModel.ReleasePage(releases: [rel("v0.1.0-beta.2")], hasNextPage: true)
        }
        var threw = false
        do { _ = try runBlocking { try await UpdateModel.collectReleases(fetchPage: failing) } } catch { threw = true }
        XCTAssertTrue(threw, "a partial list must not be used for an update decision")
    }

    func testLinkHeaderNextDetection() {
        let github = "<https://api.github.com/repositories/1/releases?per_page=100&page=2>; rel=\"next\", "
            + "<https://api.github.com/repositories/1/releases?per_page=100&page=3>; rel=\"last\""
        XCTAssertTrue(UpdateModel.linkHeaderHasNext(github))
        XCTAssertFalse(UpdateModel.linkHeaderHasNext("<https://x/?page=1>; rel=\"prev\", <https://x/?page=1>; rel=\"first\""))
        XCTAssertFalse(UpdateModel.linkHeaderHasNext(nil))
        XCTAssertFalse(UpdateModel.linkHeaderHasNext(""))
        XCTAssertFalse(UpdateModel.linkHeaderHasNext("garbage"))
        XCTAssertTrue(UpdateModel.linkHeaderHasNext("<https://x/?page=2>; REL=NEXT"))
        XCTAssertFalse(UpdateModel.linkHeaderHasNext("<https://x/?rel=next>; rel=\"last\""),
                       "a 'rel=next' inside the URL is not a link relation")
    }
}
