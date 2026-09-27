import Foundation
@testable import UsageCore   // ledgerForEachWalkCount / projectPageLookupCount are internal tests-only seams

// Usage-M3 B — standalone Models tab (owner contract 2026-09-27). Red-first tests A–J:
//   A  modelPage = exactly ONE ledger walk                 F  different EFFECTIVE range invalidates
//   B  projectPage = exactly TWO ledger walks (was 3)      G  normalization/clamp happens BEFORE the cache key
//   C  same effective cache key → NO extra walk            H  stale older reloadModelPage completion can't replace newer
//   D  revision change invalidates                        I  Models range changes don't mutate/disturb Projects
//   E  pricingStamp change invalidates                    J  Projects still produces projectModels (A1 hover source)
// Reuses the m2b fixture (6 events @ 2026-07-25T05:00Z across codex / claude-code / grok-code / opencode) and the
// m2bBridge / m2bTempDir helpers. Every walk assertion is a DELTA on the coordinator's forEachEvent counter — proven,
// not inferred (M-WALK mutants: add a second walk to modelPage / restore the modelSummaries walk in projectPage → RED).

private let m3bRangeAll = DateInterval(start: date("2026-07-01T00:00:00Z"), end: date("2026-08-01T00:00:00Z"))   // all 6 events
private let m3bRangeNone = DateInterval(start: date("2026-07-25T06:00:00Z"), end: date("2026-08-01T00:00:00Z"))  // start after every event
private let m3bFixtureTotal = m2bFixtureEvents().reduce(0) { $0 + $1.tokens.total }   // Σ m2bTk A..F = 6930 (independent of aggregation code)

/// read-only coordinator over an on-disk copy of the m2b fixture (same wiring as testM2b_ProjectionBuiltOncePerPage).
private func m3bCoordinator(retentionDays: Int = 3650, events: [UsageEvent] = m2bFixtureEvents()) -> UsageCoordinator {
    let dir = m2bTempDir()
    _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl")).append(events)
    var settings = CoreSettings(enabledProviders: ["codex", "grok-code", "claude-code", "opencode", "mock"])
    settings.retentionDays = retentionDays
    return UsageCoordinator(dataDir: dir, settings: settings, adapters: [], readOnly: true)
}

private func m3bWalks(_ coord: UsageCoordinator) -> Int { m2bBridge { await coord.ledgerForEachWalkCount } }
private func m3bModelPage(_ coord: UsageCoordinator, _ range: DateInterval, now: Date? = nil) -> ModelPageData {
    m2bBridge {
        if let now { return await coord.modelPage(range: range, now: now) }
        return await coord.modelPage(range: range)
    }
}
private func m3bProjectPage(_ coord: UsageCoordinator, _ range: DateInterval) -> ProjectPageData {
    m2bBridge { await coord.projectPage(range: range) }
}

private func m3bMockEvent(_ id: String, _ ts: Date, tokens: Int, model: String? = "m") -> UsageEvent {
    UsageEvent(id: id, providerId: "mock", projectId: "/p/a", projectName: "a", modelId: model,
               timestamp: ts, tokens: TokenBreakdown(input: tokens), sourceKind: "mock")
}

final class ModelPageM3BTests: XCTestCase {
    private final class EventBox { var events: [UsageEvent] = [] }

    /// live (non-readOnly) coordinator fed by a MockAdapter — revision advances via `refresh()`.
    private func liveCoordinator(_ box: EventBox, retentionDays: Int = 3650) -> UsageCoordinator {
        let mock = MockAdapter("mock") { state in
            (AdapterRefreshResult(events: box.events, completeness: .complete), state)
        }
        var settings = CoreSettings()
        settings.enabledProviders = ["mock"]
        settings.retentionDays = retentionDays
        return UsageCoordinator(dataDir: m2bTempDir(), settings: settings, adapters: [mock])
    }
    private func refresh(_ coord: UsageCoordinator) { _ = m2bBridge { await coord.refresh() } }

    // A — modelPage performs EXACTLY ONE ledger walk end-to-end, and that single walk yields a conserving projection:
    // Σ row tokens == page.totals (every event lands in exactly one provider×attribution row) == Projects' totals for
    // the SAME range (the two tabs describe the same event set — split UI, not split truth).
    func testM3B_ModelPageExactlyOneWalkAndRowSumConservation() {
        let coord = m3bCoordinator()
        let before = m3bWalks(coord)
        let page = m3bModelPage(coord, m3bRangeAll)
        XCTAssertEqual(m3bWalks(coord) - before, 1, "modelPage must be exactly one event walk")
        XCTAssertEqual(page.totals.total, m3bFixtureTotal)
        XCTAssertEqual(page.models.reduce(0) { $0 + $1.tokens.total }, page.totals.total)
        XCTAssertEqual(page.models.reduce(TokenBreakdown.zero) { $0 + $1.tokens }, page.totals)   // per-component, not total-only
        XCTAssertEqual(page.models.reduce(CostResult.zero) { $0 + $1.cost }, page.cost)
        XCTAssertFalse(page.models.isEmpty)
        XCTAssertEqual(page.range, m3bRangeAll)                              // no clamp with 3650d retention
        // provider rows are contiguous (the view groups Provider share by linear runs — order is the builder's §2 total order)
        var seen: Set<String> = []
        var previous: String? = nil
        for m in page.models where m.providerId != previous {
            XCTAssertFalse(seen.contains(m.providerId), "provider \(m.providerId) must not reappear after a different provider")
            seen.insert(m.providerId); previous = m.providerId
        }
        XCTAssertEqual(seen, Set(["codex", "claude-code", "grok-code", "opencode"]))
        // same range through Projects → same totals (Projects=2 walks + Models=1 walk describe one event set)
        let projects = m3bProjectPage(coord, m3bRangeAll)
        XCTAssertEqual(projects.totals, page.totals)
        XCTAssertEqual(projects.cost, page.cost)
        // within-provider share denominators: each provider's rows sum to that provider's tokens (the table's contract)
        let codexRows = page.models.filter { $0.providerId == "codex" }
        XCTAssertEqual(codexRows.reduce(0) { $0 + $1.tokens.total }, 1650 + 760 + 3000)   // p1-sol + p1-nil + p2-sol
        XCTAssertEqual(codexRows.count, 2, "codex: gpt-5.6-sol (merged across projects) + unattributed")
    }

    // B — projectPage performs EXACTLY TWO ledger walks (totals + projectSummariesWithModels); the global
    // modelSummaries walk moved to modelPage. Owner watch-point #1: "Projects=2 walks + Models=1 walk", not "UI split
    // but still 3 (or 4) walks behind it". Both pages for the same range = 3 walks total, never more.
    func testM3B_ProjectPageExactlyTwoWalks() {
        let coord = m3bCoordinator()
        let before = m3bWalks(coord)
        let page = m3bProjectPage(coord, m3bRangeAll)
        XCTAssertEqual(m3bWalks(coord) - before, 2, "projectPage must be exactly two event walks after Usage-M3 B")
        XCTAssertEqual(page.totals.total, m3bFixtureTotal)
        _ = m3bModelPage(coord, m3bRangeAll)
        XCTAssertEqual(m3bWalks(coord) - before, 3, "Projects (2) + Models (1) = 3 walks for the same range, no more")
    }

    // C — same EFFECTIVE cache key → zero extra walks: identical range; a later `end` when both ends are strictly after
    // the newest event (today/all-time end=now moves every call); and the cache-hit path returns the requested range.
    func testM3B_SameEffectiveKeyNoExtraWalk() {
        let coord = m3bCoordinator()
        let first = m3bModelPage(coord, m3bRangeAll)
        let after1 = m3bWalks(coord)
        let second = m3bModelPage(coord, m3bRangeAll)
        XCTAssertEqual(m3bWalks(coord), after1, "identical range must hit the Models cache")
        XCTAssertEqual(second.totals, first.totals)
        XCTAssertEqual(second.models.map { $0.id }, first.models.map { $0.id })
        // end moves later, both ends strictly after the newest event (05:00Z) → same event set → hit, range updated
        let laterEnd = DateInterval(start: m3bRangeAll.start, end: date("2026-08-02T00:00:00Z"))
        let third = m3bModelPage(coord, laterEnd)
        XCTAssertEqual(m3bWalks(coord), after1, "end later than newest on both sides ⇒ equivalent key ⇒ no walk")
        XCTAssertEqual(third.range.end, laterEnd.end)                       // range follows the request even on a hit
        XCTAssertEqual(third.totals.total, m3bFixtureTotal)
        // end BEFORE the newest event → event set differs → must recompute (stale data is a data error)
        let earlyEnd = DateInterval(start: m3bRangeAll.start, end: date("2026-07-25T04:00:00Z"))
        let fourth = m3bModelPage(coord, earlyEnd)
        XCTAssertEqual(m3bWalks(coord), after1 + 1)
        XCTAssertEqual(fourth.totals.total, 0)
        XCTAssertTrue(fourth.models.isEmpty)
    }

    // D — revision change (new events landed) invalidates: a second modelPage after refresh walks again and sees the
    // new payload; the page carries the advanced revision (the identity stamp the view keys on).
    func testM3B_RevisionChangeInvalidates() {
        let box = EventBox()
        box.events = [m3bMockEvent("e1", date("2026-02-01T10:00:00Z"), tokens: 100)]
        let coord = liveCoordinator(box)
        refresh(coord)
        let range = DateInterval(start: date("2026-02-01T00:00:00Z"), end: date("2026-02-01T23:00:00Z"))
        let p1 = m3bModelPage(coord, range)
        XCTAssertEqual(p1.totals.total, 100)
        let afterFirst = m3bWalks(coord)
        _ = m3bModelPage(coord, range)
        XCTAssertEqual(m3bWalks(coord), afterFirst)                         // hit before the change
        box.events.append(m3bMockEvent("e2", date("2026-02-01T11:00:00Z"), tokens: 50))
        refresh(coord)                                                       // revision advances
        let walksBeforeReread = m3bWalks(coord)
        let p2 = m3bModelPage(coord, range)
        XCTAssertEqual(m3bWalks(coord) - walksBeforeReread, 1, "revision change must force exactly one recompute walk")
        XCTAssertEqual(p2.totals.total, 150, "revision 推進後不得回過期 Models 投影")
        XCTAssertTrue(p2.revision != p1.revision)
        XCTAssertEqual(p2.models.first { $0.modelId == "m" }?.tokens.total, 150)
    }

    // E — pricingStamp change invalidates: the same events, same range, same revision — a user pricing override must
    // recompute (cost changes from "unpriced" to a known USD figure) and the page's pricingStamp advances.
    func testM3B_PricingStampChangeInvalidates() {
        let box = EventBox()
        box.events = [m3bMockEvent("e1", date("2026-02-01T10:00:00Z"), tokens: 1_000_000)]   // 1M input tokens of mock/m
        let coord = liveCoordinator(box)
        refresh(coord)
        let range = DateInterval(start: date("2026-02-01T00:00:00Z"), end: date("2026-02-01T23:00:00Z"))
        let p1 = m3bModelPage(coord, range)
        XCTAssertEqual(p1.cost.knownUSD, 0, accuracy: 1e-9)                 // mock/m is unpriced by default
        XCTAssertEqual(p1.cost.unknownModelTokens, 1_000_000)
        let afterFirst = m3bWalks(coord)
        _ = m3bModelPage(coord, range)
        XCTAssertEqual(m3bWalks(coord), afterFirst)
        _ = m2bBridge { () -> Bool in
            await coord.addPricingOverride(ModelPrice(providerId: "mock", modelId: "m", displayName: "m",
                                                      inputPerMillion: 3.0, outputPerMillion: 15.0,
                                                      effectiveFrom: "2026-01-01", source: "test"))
            return true
        }
        let p2 = m3bModelPage(coord, range)
        XCTAssertEqual(m3bWalks(coord) - afterFirst, 1, "pricing change must force exactly one recompute walk")
        XCTAssertEqual(p2.cost.knownUSD, 3.0, accuracy: 1e-9)               // 1M input × $3/M
        XCTAssertEqual(p2.cost.unknownModelTokens, 0)
        XCTAssertTrue(p2.pricingStamp != p1.pricingStamp)
        XCTAssertEqual(p2.revision, p1.revision, "no new events — only pricing moved")
        XCTAssertEqual(p2.models.first?.cost.knownUSD ?? -1, 3.0, accuracy: 1e-9)
    }

    // F — a different EFFECTIVE range (start cuts events / end before newest) invalidates and yields the right set;
    // the slot is single-entry, so returning to the previous range recomputes (one walk, correct data).
    func testM3B_DifferentEffectiveRangeInvalidates() {
        let coord = m3bCoordinator()
        let all = m3bModelPage(coord, m3bRangeAll)
        let after1 = m3bWalks(coord)
        XCTAssertEqual(all.totals.total, m3bFixtureTotal)
        let none = m3bModelPage(coord, m3bRangeNone)
        XCTAssertEqual(m3bWalks(coord), after1 + 1, "start moved past the events ⇒ different key ⇒ recompute")
        XCTAssertEqual(none.totals.total, 0)
        XCTAssertTrue(none.models.isEmpty)
        XCTAssertEqual(none.range, m3bRangeNone)
        let back = m3bModelPage(coord, m3bRangeAll)
        XCTAssertEqual(m3bWalks(coord), after1 + 2, "back to the first range ⇒ recompute (single slot), never stale")
        XCTAssertEqual(back.totals.total, m3bFixtureTotal)
        XCTAssertEqual(back.models.map { $0.id }, all.models.map { $0.id })
    }

    // G — normalization BEFORE the cache key: the retained-window clamp defines the EFFECTIVE range; two raw requests
    // whose starts both precede the cutoff are the same query (same clamped key → hit), and the returned range is the
    // clamped one. Mutant "key from the raw range" makes the second call MISS (raw now−8d > oldest now−10d breaks the
    // start-equivalence rule) → RED. Mutant "no clamp" includes the expired event (1010) and returns start=now−100d → RED.
    // Fixture: retention 7d; expired-but-physically-retained event at now−10d (read-only load: no compaction), live event
    // at now−1d. `now` is injected so the cutoff is fixed for the whole test.
    func testM3B_NormalizationBeforeCacheKeyIdentity() {
        let now = Date()
        let old = m3bMockEvent("old", now.addingTimeInterval(-10 * 86400), tokens: 1000)
        let new = m3bMockEvent("new", now.addingTimeInterval(-1 * 86400), tokens: 10)
        let coord = m3bCoordinator(retentionDays: 7, events: [old, new])
        let cutoff = UsageLedger.retentionCutoff(retentionDays: 7, now: now)
        let before = m3bWalks(coord)
        let p1 = m3bModelPage(coord, DateInterval(start: now.addingTimeInterval(-100 * 86400), end: now), now: now)
        XCTAssertEqual(m3bWalks(coord) - before, 1)
        XCTAssertEqual(p1.totals.total, 10, "expired event must be logically invisible (clamped out)")
        XCTAssertEqual(p1.range.start, cutoff, "returned range is the EFFECTIVE (clamped) range")
        XCTAssertEqual(p1.range.end, now)
        // second raw request with a DIFFERENT raw start, same clamped start → same key → hit (no walk)
        let p2 = m3bModelPage(coord, DateInterval(start: now.addingTimeInterval(-8 * 86400), end: now), now: now)
        XCTAssertEqual(m3bWalks(coord) - before, 1, "clamp must happen before the key: same effective range ⇒ hit")
        XCTAssertEqual(p2.range.start, cutoff)
        XCTAssertEqual(p2.totals.total, 10)
        // a start INSIDE the retained window is a genuinely different effective range → recompute, start preserved
        let inside = now.addingTimeInterval(-3 * 86400)
        let p3 = m3bModelPage(coord, DateInterval(start: inside, end: now), now: now)
        XCTAssertEqual(m3bWalks(coord) - before, 2)
        XCTAssertEqual(p3.range.start, inside)
        XCTAssertEqual(p3.totals.total, 10)
        // consistency with Projects' clamp (same helper): Projects' effective start for the same raw request is the cutoff
        // too (Projects clamps at Date(); assert on the invariant that its start is ≥ p1's fixed cutoff, i.e. never earlier).
        let projects = m3bProjectPage(coord, DateInterval(start: now.addingTimeInterval(-100 * 86400), end: now))
        XCTAssertTrue(projects.range.start >= cutoff)
        XCTAssertEqual(projects.totals.total, 10)
    }

    // H — stale older completion can't replace newer: the Models reload guard lives INSIDE `SequencedSlot.publish`,
    // so a call site cannot bypass it. Two reloads begin in order (t1 then t2); if t2's result lands first, t1's later
    // (stale) completion is rejected and the published value stays t2's. Mutant "drop the ticket check" → RED.
    func testM3B_StaleOlderReloadCompletionCannotReplaceNewer() {
        var slot = SequencedSlot<Int>()
        XCTAssertNil(slot.value)
        let t1 = slot.begin()
        let t2 = slot.begin()
        XCTAssertTrue(t2 > t1)
        XCTAssertTrue(slot.publish(t2, 2))                                   // newer completes first
        XCTAssertEqual(slot.value, 2)
        XCTAssertFalse(slot.publish(t1, 1), "older ticket must be rejected even though it completes later")
        XCTAssertEqual(slot.value, 2)
        // in-order completion still publishes; and a superseded ticket stays dead forever (not just until the next begin)
        let t3 = slot.begin()
        XCTAssertFalse(slot.publish(t2, 22))
        XCTAssertEqual(slot.value, 2)
        XCTAssertTrue(slot.publish(t3, 3))
        XCTAssertEqual(slot.value, 3)
        XCTAssertFalse(slot.publish(t1, 111))
        XCTAssertEqual(slot.value, 3)
        // re-publishing the latest ticket is allowed (idempotent latest)
        XCTAssertTrue(slot.publish(t3, 33))
        XCTAssertEqual(slot.value, 33)
        // end-to-end shape with the real projection type: an older Models reload (range A) resolving AFTER a newer one
        // (range B) must not put A's page back — the slot keeps B.
        let coord = m3bCoordinator()
        var pages = SequencedSlot<ModelPageData>()
        let older = pages.begin()
        let newer = pages.begin()
        let pageB = m3bModelPage(coord, m3bRangeNone)
        let pageA = m3bModelPage(coord, m3bRangeAll)
        XCTAssertTrue(pages.publish(newer, pageB))
        XCTAssertFalse(pages.publish(older, pageA))
        XCTAssertEqual(pages.value?.range, m3bRangeNone)
        XCTAssertEqual(pages.value?.totals.total, 0)
    }

    // I — Models range changes don't mutate or disturb Projects. Three layers, all separate:
    //  (1) state ownership: two RangeSelection VALUES — mutating one cannot touch the other;
    //  (2) the pure range helper is shared (one implementation) yet evaluated per-selection;
    //  (3) coordinator cache slots: Models lookups (any range) never evict/miss Projects' slot and vice versa.
    // Mutant "couple the slots" (modelPage clears/overwrites cachedProjectPage) → RED at the +0 assertions.
    func testM3B_ModelsRangeIndependentFromProjectsRange() {
        // (1)+(2) value independence + one helper
        let now = date("2026-07-25T15:30:00Z")
        var projects = RangeSelection(now: now)
        var models = projects
        XCTAssertEqual(projects, models)
        models.preset = .allTime
        XCTAssertEqual(projects.preset, .today)
        XCTAssertTrue(projects != models)
        XCTAssertEqual(projects.interval(now: now).start, Calendar.current.startOfDay(for: now))
        XCTAssertEqual(projects.interval(now: now).end, now)
        XCTAssertEqual(models.interval(now: now).start, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(models.interval(now: now).end, now)
        projects.preset = .custom
        projects.customStart = date("2026-07-20T12:00:00Z")
        projects.customEnd = date("2026-07-22T12:00:00Z")
        let custom = projects.interval(now: now)
        XCTAssertEqual(custom.start, Calendar.current.startOfDay(for: projects.customStart))
        XCTAssertEqual(custom.end, Calendar.current.startOfDay(for: projects.customEnd).addingTimeInterval(86400))
        XCTAssertEqual(models.preset, .allTime, "editing Projects' custom dates must not touch Models")
        // custom end is bounded by `now` (not by the wall clock) — the moved helper is pure
        projects.customEnd = date("2026-07-30T12:00:00Z")
        XCTAssertEqual(projects.interval(now: now).end, now)
        // (3) coordinator: independent cache slots
        let coord = m3bCoordinator()
        let w0 = m3bWalks(coord)
        let pA = m3bProjectPage(coord, m3bRangeAll)                          // Projects: range A
        XCTAssertEqual(m3bWalks(coord) - w0, 2)
        let mB = m3bModelPage(coord, m3bRangeNone)                           // Models: range B (different, simultaneously)
        XCTAssertEqual(m3bWalks(coord) - w0, 3)
        XCTAssertEqual(pA.totals.total, m3bFixtureTotal)
        XCTAssertEqual(mB.totals.total, 0)
        XCTAssertTrue(pA.range != mB.range, "two ranges live at once — Models did not change Projects' range")
        _ = m3bProjectPage(coord, m3bRangeAll)
        XCTAssertEqual(m3bWalks(coord) - w0, 3, "a Models lookup must not evict Projects' cached page")
        _ = m3bModelPage(coord, m3bRangeNone)
        XCTAssertEqual(m3bWalks(coord) - w0, 3, "a Projects lookup must not evict Models' cached page")
        let mA = m3bModelPage(coord, m3bRangeAll)                            // Models switches to A
        XCTAssertEqual(m3bWalks(coord) - w0, 4)
        XCTAssertEqual(mA.totals.total, m3bFixtureTotal)
        let pA2 = m3bProjectPage(coord, m3bRangeAll)
        XCTAssertEqual(m3bWalks(coord) - w0, 4, "Models switching range must not disturb Projects' slot")
        XCTAssertEqual(pA2.range, m3bRangeAll)
        let pB = m3bProjectPage(coord, m3bRangeNone)                         // Projects switches to B
        XCTAssertEqual(m3bWalks(coord) - w0, 6)
        XCTAssertEqual(pB.totals.total, 0)
        _ = m3bModelPage(coord, m3bRangeAll)
        XCTAssertEqual(m3bWalks(coord) - w0, 6, "Projects switching range must not disturb Models' slot")
    }

    // J — Projects still produces `projectModels` (the A1 hover preview data source) with the same content as the
    // ledger's fold-in walk; ModelPageData carries no per-project slice (the split is by responsibility, not a copy).
    func testM3B_ProjectPageStillProducesProjectModelsForA1Hover() {
        let coord = m3bCoordinator()
        let page = m3bProjectPage(coord, m3bRangeAll)
        XCTAssertFalse(page.projectModels.isEmpty, "projectModels must survive the removal of ProjectPageData.models")
        XCTAssertEqual(Set(page.projectModels.keys), Set(page.projects.map { $0.projectId ?? m2bUnknownKey }))
        let (_, reference) = m2bLedger().projectSummariesWithModels(in: m3bRangeAll, pricing: m0Pricing())
        for (key, rows) in reference {
            XCTAssertEqual(page.projectModels[key]?.map { $0.id }, rows.map { $0.id }, "slice for \(key) must match the fold-in walk")
            XCTAssertEqual(page.projectModels[key]?.reduce(0) { $0 + $1.tokens.total }, rows.reduce(0) { $0 + $1.tokens.total })
        }
        XCTAssertEqual(page.projectModelRows(forKey: "proj-alpha").count, 3)   // codex/sol + codex/nil + claude-code/fable
        XCTAssertTrue(page.projectModelRows(forKey: "no-such-project").isEmpty)
        // the per-project slice is NOT the global model aggregation: proj-alpha's codex/gpt-5.6-sol row is project-scoped
        // (1650), while the Models tab's row for the same provider/model merges both projects (1650 + 3000).
        let hoverSol = page.projectModelRows(forKey: "proj-alpha").first { $0.providerId == "codex" && $0.modelId == "gpt-5.6-sol" }
        XCTAssertEqual(hoverSol?.tokens.total, 1650)
        let globalSol = m3bModelPage(coord, m3bRangeAll).models.first { $0.providerId == "codex" && $0.modelId == "gpt-5.6-sol" }
        XCTAssertEqual(globalSol?.tokens.total, 4650)
    }
}
