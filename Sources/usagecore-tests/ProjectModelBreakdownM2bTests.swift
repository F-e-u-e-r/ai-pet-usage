import Foundation
@testable import UsageCore   // projectPageLookupCount is an internal tests-only seam (同 trendsRecomputeCount)

// Usage-M2b additions — project → provider → model drill-down (design §3/§9.3/§10/§11/§12, frozen v0.7).
// Reuses the m0*/m2a* helpers from the same target. Fixtures here carry projectId — M2b partitions BY project,
// and the shipped M2a substrate (ModelAttribution / shared modelRows builder) is a DEPENDENCY, not re-litigated.
//
// Projects: "proj-alpha" (P1), "proj-beta" (P2), plus a nil-project event → "(unknown project)".
// Cross-cutting coverage baked into the fixture:
//   - same (provider, model) in two projects (P1 & P2 both codex/gpt-5.6-sol) → must NOT merge across projects.
//   - unattributed rows in different providers/projects (P1 codex/nil, P2 grok-code/nil) → provider+project scoped.
//   - an unattributed event carrying providerCostUSD in the nil-project bucket → INV-6 providerReportedUSD teeth.

let m2bInterval = DateInterval(start: date("2026-07-25T00:00:00Z"), end: date("2026-07-26T00:00:00Z"))
let m2bUnknownKey = "(unknown project)"

func m2bEv(_ id: String, project: String?, provider: String, model: String?, _ tk: TokenBreakdown,
           providerCostUSD: Double? = nil) -> UsageEvent {
    UsageEvent(id: id, providerId: provider, projectId: project, projectName: project, modelId: model,
               timestamp: date("2026-07-25T05:00:00Z"), tokens: tk, sourceKind: "test",
               providerCostUSD: providerCostUSD)
}

// Token breakdowns carry non-zero cacheRead + cacheWrite sub-components so INV-2 is per-component, not total-only.
let m2bTkA = TokenBreakdown(input: 1000, output: 200, cacheRead: 300, cacheWrite5m: 40, cacheWrite1h: 50, cacheWriteUnknown: 60) // total 1650
let m2bTkB = TokenBreakdown(input: 500, output: 100, cacheRead: 150, cacheWrite5m: 10)                                           // total 760
let m2bTkC = TokenBreakdown(input: 800, output: 90)                                                                              // total 890
let m2bTkD = TokenBreakdown(input: 2000, output: 400, cacheRead: 600)                                                            // total 3000
let m2bTkE = TokenBreakdown(input: 300, output: 30)                                                                              // total 360
let m2bTkF = TokenBreakdown(input: 250, output: 25, cacheRead: 25)                                                               // total 300

// P1 "proj-alpha": codex/gpt-5.6-sol (priced) + codex/nil (unattributed) + claude-code/claude-fable-5.
let m2bP1Sol = m2bEv("p1-sol", project: "proj-alpha", provider: "codex", model: "gpt-5.6-sol", m2bTkA)
let m2bP1Nil = m2bEv("p1-nil", project: "proj-alpha", provider: "codex", model: nil, m2bTkB)
let m2bP1Fab = m2bEv("p1-fab", project: "proj-alpha", provider: "claude-code", model: "claude-fable-5", m2bTkC)
// P2 "proj-beta": codex/gpt-5.6-sol (SAME provider+model as P1, different project) + grok-code/nil (unattributed).
let m2bP2Sol = m2bEv("p2-sol", project: "proj-beta", provider: "codex", model: "gpt-5.6-sol", m2bTkD)
let m2bP2Nil = m2bEv("p2-nil", project: "proj-beta", provider: "grok-code", model: nil, m2bTkE)
// nil project → "(unknown project)": opencode/nil unattributed carrying a provider-reported cost.
let m2bUnkOc = m2bEv("unk-oc", project: nil, provider: "opencode", model: nil, m2bTkF, providerCostUSD: 0.37)

func m2bFixtureEvents() -> [UsageEvent] { [m2bP1Sol, m2bP1Nil, m2bP1Fab, m2bP2Sol, m2bP2Nil, m2bUnkOc] }
func m2bLedger() -> UsageLedger { let l = UsageLedger(fileURL: nil); _ = l.append(m2bFixtureEvents()); return l }

// Bridge the actor-isolated coordinator synchronously (same pattern as ModelBreakdownM2aTests / Tests.swift).
func m2bBridge<T>(_ body: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    var out: T!
    Task { out = await body(); sem.signal() }
    sem.wait()
    return out
}

func m2bTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aipet-m2b-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

final class ProjectModelBreakdownM2bTests: XCTestCase {

    // INV-2 (§6) — for EACH project, Σ its M2b rows conserves each token component against ProjectSummary.tokens.
    // Primary target of M-PROJ-OMIT / M-PROJ-DOUBLE (drop/double a project-model → this sum diverges).
    func testM2b_ProjectModelTokenSumEqualsProjectTotal() {
        let pricing = m0Pricing()
        let (projects, projectModels) = m2bLedger().projectSummariesWithModels(in: m2bInterval, pricing: pricing)
        XCTAssertFalse(projectModels.isEmpty)
        // every project summary has a matching model slice, keyed identically (projectId ?? "(unknown project)").
        for p in projects {
            let rows = projectModels[p.projectId]
            XCTAssertNotNil(rows, "missing projectModels for \(p.projectId)")
            let sum = (rows ?? []).reduce(TokenBreakdown.zero) { $0 + $1.tokens }
            XCTAssertEqual(sum.input, p.tokens.input)
            XCTAssertEqual(sum.output, p.tokens.output)
            XCTAssertEqual(sum.cacheRead + sum.cacheWrite, p.tokens.cacheRead + p.tokens.cacheWrite)   // "cache" component
            XCTAssertEqual(sum.total, p.tokens.total)
        }
        // concrete anchors — P1 = A+B+C, P2 = D+E, unknown = F (independently computed from the fixture).
        XCTAssertEqual((projectModels["proj-alpha"] ?? []).reduce(0) { $0 + $1.tokens.total }, m2bTkA.total + m2bTkB.total + m2bTkC.total)
        XCTAssertEqual((projectModels["proj-beta"] ?? []).reduce(0) { $0 + $1.tokens.total }, m2bTkD.total + m2bTkE.total)
        XCTAssertEqual((projectModels[m2bUnknownKey] ?? []).reduce(0) { $0 + $1.tokens.total }, m2bTkF.total)
        // INV-6 — per-project cost conservation, per CostResult field (token conservation does not imply cost).
        for p in projects {
            let rowCost = (projectModels[p.projectId] ?? []).reduce(CostResult.zero) { $0 + $1.cost }
            XCTAssertEqual(rowCost.knownUSD, p.cost.knownUSD, accuracy: 1e-6)
            XCTAssertEqual(rowCost.providerReportedUSD, p.cost.providerReportedUSD, accuracy: 1e-6)
            XCTAssertEqual(rowCost.unknownModelTokens, p.cost.unknownModelTokens)
            XCTAssertEqual(rowCost.isEstimated, p.cost.isEstimated)
        }
        // the nil-project opencode row is provider-priced (INV-6 providerReportedUSD has real teeth, not all-zero).
        let unkCost = (projectModels[m2bUnknownKey] ?? []).reduce(CostResult.zero) { $0 + $1.cost }
        XCTAssertEqual(unkCost.providerReportedUSD, 0.37, accuracy: 1e-9)
    }

    // Parity (§4/§11 M7) — M2b rows for a project == an INDEPENDENT per-project reference built by the ONE shared
    // row builder on that project's events only. Equal attribution / tokens / each CostResult field (float-tol).
    // Share is NOT compared (per-group denominator differs). Primary target of M-DIVERGE.
    func testM2b_ProjectModelUsesSameRowSemanticsAsGlobal() {
        let pricing = m0Pricing()
        let (_, projectModels) = m2bLedger().projectSummariesWithModels(in: m2bInterval, pricing: pricing)
        let byProject: [String: [UsageEvent]] = [
            "proj-alpha": [m2bP1Sol, m2bP1Nil, m2bP1Fab],
            "proj-beta": [m2bP2Sol, m2bP2Nil],
            m2bUnknownKey: [m2bUnkOc],
        ]
        for (key, events) in byProject {
            // independent reference: a fresh ledger of ONLY this project's events → global modelSummaries == this
            // project's breakdown (same shared modelRows builder). Match order-independently by row id.
            let refLedger = UsageLedger(fileURL: nil); _ = refLedger.append(events)
            let reference = refLedger.modelSummaries(in: m2bInterval, pricing: pricing)
            let actual = projectModels[key] ?? []
            XCTAssertEqual(actual.count, reference.count, "row count mismatch for \(key)")
            let refByID = Dictionary(uniqueKeysWithValues: reference.map { ($0.id, $0) })
            for row in actual {
                guard let ref = refByID[row.id] else { XCTAssertNotNil(nil, "no reference row for \(row.id)"); continue }
                XCTAssertEqual(row.attribution, ref.attribution)
                XCTAssertEqual(row.tokens, ref.tokens)                                  // full TokenBreakdown parity (M-DIVERGE bites here)
                XCTAssertEqual(row.cost.knownUSD, ref.cost.knownUSD, accuracy: 1e-6)
                XCTAssertEqual(row.cost.providerReportedUSD, ref.cost.providerReportedUSD, accuracy: 1e-6)
                XCTAssertEqual(row.cost.unknownModelTokens, ref.cost.unknownModelTokens)
                XCTAssertEqual(row.cost.isEstimated, ref.cost.isEstimated)
            }
            // share sums to ≤1000‰ within THIS project (own denominator) — the M2b within-project quota.
            let shares = ReportGenerator.rowShares(rows: actual.map { $0.tokens.total },
                                                   periodTotal: actual.reduce(0) { $0 + $1.tokens.total }, scale: 1000)
            XCTAssertTrue(shares.reduce(0, +) <= 1000)
        }
    }

    // §3/§5 — a project's unattributed bucket is provider-scoped AND project-scoped: no cross-project or
    // cross-provider merge. P1 codex/nil, P2 grok-code/nil, unknown opencode/nil stay three distinct rows.
    func testM2b_UnattributedPerProjectProviderScoped() {
        let (_, projectModels) = m2bLedger().projectSummariesWithModels(in: m2bInterval, pricing: m0Pricing())
        // P1: exactly one unattributed row, codex, total B — NOT mixed with P2's grok unattributed.
        let p1Unattr = (projectModels["proj-alpha"] ?? []).filter { $0.attribution == .unattributed }
        XCTAssertEqual(p1Unattr.count, 1)
        XCTAssertEqual(p1Unattr.first?.providerId, "codex")
        XCTAssertEqual(p1Unattr.first?.tokens.total, m2bTkB.total)
        // P2: exactly one unattributed row, grok-code, total E.
        let p2Unattr = (projectModels["proj-beta"] ?? []).filter { $0.attribution == .unattributed }
        XCTAssertEqual(p2Unattr.count, 1)
        XCTAssertEqual(p2Unattr.first?.providerId, "grok-code")
        XCTAssertEqual(p2Unattr.first?.tokens.total, m2bTkE.total)
        // the SAME (provider, model) in two projects does NOT merge — P1's codex/gpt-5.6-sol has total A, P2's has D.
        let p1Sol = (projectModels["proj-alpha"] ?? []).first { $0.providerId == "codex" && $0.modelId == "gpt-5.6-sol" }
        let p2Sol = (projectModels["proj-beta"] ?? []).first { $0.providerId == "codex" && $0.modelId == "gpt-5.6-sol" }
        XCTAssertEqual(p1Sol?.tokens.total, m2bTkA.total)
        XCTAssertEqual(p2Sol?.tokens.total, m2bTkD.total)
        // no unattributed row leaks into a project that had none in a given provider.
        XCTAssertFalse((projectModels["proj-alpha"] ?? []).contains { $0.providerId == "grok-code" })
        XCTAssertFalse((projectModels["proj-beta"] ?? []).contains { $0.providerId == "codex" && $0.attribution == .unattributed })
        // the SAME provider (codex) UNATTRIBUTED in TWO projects must NOT merge — project-scoped, not just
        // provider-scoped (impl-xcheck sol: the fixture above only had DIFFERENT-provider unattributed rows).
        let l2 = UsageLedger(fileURL: nil)
        _ = l2.append([
            m2bEv("aa-nil", project: "aa", provider: "codex", model: nil, TokenBreakdown(input: 100)),
            m2bEv("bb-nil", project: "bb", provider: "codex", model: nil, TokenBreakdown(input: 200)),
        ])
        let (_, pm2) = l2.projectSummariesWithModels(in: m2bInterval, pricing: emptyPricing)
        XCTAssertEqual((pm2["aa"] ?? []).first { $0.attribution == .unattributed }?.tokens.total, 100)
        XCTAssertEqual((pm2["bb"] ?? []).first { $0.attribution == .unattributed }?.tokens.total, 200)   // NOT merged to 300
        XCTAssertEqual((pm2["aa"] ?? []).filter { $0.attribution == .unattributed }.count, 1)
    }

    // §10 — the drill-down slice is built ONCE at page-build; reading it (hover/click/open) invokes ZERO further
    // coordinator/page lookups. Seam = coordinator projectPage-lookup invocation counter (r3-D). M-HOVERSCAN flips.
    func testM2b_ProjectionBuiltOncePerPage_NotPerHover() {
        let dir = m2bTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL).append(m2bFixtureEvents())
        var settings = CoreSettings(enabledProviders: ["codex", "grok-code", "claude-code", "opencode"])
        settings.retentionDays = 3650   // 固定歷史日期 fixture:不讓 retention clamp 掉 2026-07 事件(同既有 projectPage 測試)
        let coord = UsageCoordinator(dataDir: dir, settings: settings, adapters: [], readOnly: true)
        let range = DateInterval(start: date("2026-07-01T00:00:00Z"), end: date("2026-08-01T00:00:00Z"))
        // build the page ONCE — and prove it performs EXACTLY 3 ledger walks END-TO-END (§10 perf gate:
        // totals + projectSummariesWithModels + modelSummaries; M2b fold-in adds no 4th walk in projectPage itself).
        let walksBefore = m2bBridge { await coord.ledgerForEachWalkCount }
        let page = m2bBridge { await coord.projectPage(range: range) }
        XCTAssertEqual(m2bBridge { await coord.ledgerForEachWalkCount } - walksBefore, 3)
        let afterBuild = m2bBridge { await coord.projectPageLookupCount }
        XCTAssertEqual(afterBuild, 1)                                  // exactly one projectPage lookup so far
        XCTAssertFalse(page.projectModels.isEmpty)                     // slice pre-built → popover needs no further call
        // simulate MANY hovers / popover opens reading the pre-built slice via the seam (miss included).
        for _ in 0..<100 {
            for key in page.projectModels.keys { _ = page.projectModelRows(forKey: key) }
            XCTAssertTrue(page.projectModelRows(forKey: "no-such-project").isEmpty)   // n7 miss → empty, never a fetch
        }
        // the seam returns exactly the pre-built slice (a miss is empty).
        XCTAssertEqual(page.projectModelRows(forKey: "proj-alpha").map { $0.id }, (page.projectModels["proj-alpha"] ?? []).map { $0.id })
        // ZERO coordinator/page lookups happened on interaction — the counter never moved past the single build.
        XCTAssertEqual(m2bBridge { await coord.projectPageLookupCount }, afterBuild)
    }

    // UI-contract seam #1 (owner load-bearing) — deterministic cross-provider FLAT order + stable top-12 selection.
    // Order key = (−total, providerId, unattributedLast, exactModelIdOrEmpty), a TOTAL order across providers.
    // Ordering mutant (remove the providerId tie-break) makes this RED.
    func testM2b_DeterministicCrossProviderOrderingAndTop12Selection() {
        // two unattributed rows from different providers at EQUAL total — only providerId separates them.
        func row(_ provider: String, _ model: String?, _ total: Int) -> ModelUsageSummary {
            ModelUsageSummary(providerId: provider,
                              attribution: model.map { ModelAttribution.model(id: $0) } ?? .unattributed,
                              tokens: TokenBreakdown(input: total), cost: .zero)
        }
        let tieA = row("aaa", nil, 500)      // provider aaa, unattributed, 500
        let tieB = row("bbb", nil, 500)      // provider bbb, unattributed, 500 — ties on total; providerId asc → aaa first
        let big = row("zzz", "big-model", 900)
        let input = [tieB, big, tieA]
        let ordered = UsageLedger.projectDrilldownOrder(input)
        XCTAssertEqual(ordered.map { $0.id }, [big.id, tieA.id, tieB.id])   // 900 first; then aaa before bbb (providerId tie-break)
        // stable across a shuffled append order (total order → same result).
        XCTAssertEqual(UsageLedger.projectDrilldownOrder([tieA, tieB, big]).map { $0.id }, ordered.map { $0.id })
        XCTAssertEqual(UsageLedger.projectDrilldownOrder(input.reversed()).map { $0.id }, ordered.map { $0.id })
        // same-provider EQUAL-total: attributed by modelId asc, then unattributed LAST — exercises the
        // unattributedLast + exactModelId tie-breaks (impl-xcheck sol: the cross-provider ties above alone
        // leave those two comparator lines unguarded).
        let sp = [row("ccc", "m-b", 300), row("ccc", nil, 300), row("ccc", "m-a", 300)]
        let spOrder = UsageLedger.projectDrilldownOrder(sp).map { "\($0.providerId)/\($0.modelId ?? "∅")" }
        XCTAssertEqual(spOrder, ["ccc/m-a", "ccc/m-b", "ccc/∅"])
        // top-12 selection is a STABLE set because the order is total: build 15 distinct-total rows, shuffle, prefix(12) equal.
        var many: [ModelUsageSummary] = []
        for i in 0..<15 { many.append(row("p\(i % 3)", "m\(i)", 100 + i * 10)) }
        let top12a = Array(UsageLedger.projectDrilldownOrder(many).prefix(12)).map { $0.id }
        let top12b = Array(UsageLedger.projectDrilldownOrder(many.reversed()).prefix(12)).map { $0.id }
        XCTAssertEqual(top12a, top12b)
        XCTAssertEqual(top12a.count, 12)
        // and the drill-down slice stored in the page IS in this flat order (view renders it as-is).
        let (_, projectModels) = m2bLedger().projectSummariesWithModels(in: m2bInterval, pricing: m0Pricing())
        let p1 = projectModels["proj-alpha"] ?? []
        XCTAssertEqual(p1.map { $0.id }, UsageLedger.projectDrilldownOrder(p1).map { $0.id })   // already ordered (idempotent)
    }

    // UI-contract seam #2 (owner load-bearing) — visible Provider identity survives same-model / unattributed
    // cross-provider rows. The drill-down spans providers; providerId is identity-bearing and must stay per-row
    // (the popover shows a visible Provider column). Two providers' unattributed rows, or the same model id under
    // two providers, are DISTINCT rows with distinct ids — never visually or structurally merged.
    func testM2b_VisibleProviderIdentitySurvivesSameModelCrossProvider() {
        // a single project spanning two providers with the SAME model id + both providers' unattributed rows.
        let events = [
            m2bEv("x-cx-shared", project: "multi", provider: "codex", model: "shared-model", TokenBreakdown(input: 100)),
            m2bEv("x-oc-shared", project: "multi", provider: "opencode", model: "shared-model", TokenBreakdown(input: 100)),
            m2bEv("x-cx-nil", project: "multi", provider: "codex", model: nil, TokenBreakdown(input: 50)),
            m2bEv("x-oc-nil", project: "multi", provider: "opencode", model: nil, TokenBreakdown(input: 50)),
        ]
        let l = UsageLedger(fileURL: nil); _ = l.append(events)
        let (_, projectModels) = l.projectSummariesWithModels(in: m2bInterval, pricing: emptyPricing)
        let rows = projectModels["multi"] ?? []
        // same model id "shared-model" under two providers → two distinct rows, distinct ids, each carrying its provider.
        let shared = rows.filter { $0.modelId == "shared-model" }
        XCTAssertEqual(shared.count, 2)
        XCTAssertEqual(Set(shared.map { $0.providerId }), Set(["codex", "opencode"]))
        XCTAssertEqual(Set(shared.map { $0.id }).count, 2)                    // distinct Identifiable.id (provider-bearing)
        // two providers' unattributed rows do NOT merge — distinct providerId, distinct id.
        let unattr = rows.filter { $0.attribution == .unattributed }
        XCTAssertEqual(unattr.count, 2)
        XCTAssertEqual(Set(unattr.map { $0.providerId }), Set(["codex", "opencode"]))
        XCTAssertEqual(Set(unattr.map { $0.id }).count, 2)
        // provider is recoverable from every row (the visible Provider column source) — never nil/blank.
        XCTAssertFalse(rows.contains { $0.providerId.isEmpty })
    }

    // §10 perf gate — M2b folds into projectSummaries' walk: ZERO extra ledger walks; projectPage stays 3.
    // Proven, not inferred: count forEachEvent invocations. (projectPage = totals-loop + projectSummariesWithModels
    // + modelSummaries; this proves each ledger fn is exactly 1 walk, and M2b's fold-in keeps it at 1.)
    func testM2b_PerformanceFoldsInNoExtraWalks() {
        let ledger = m2bLedger()
        let pricing = m0Pricing()
        // (1) M2a baseline: projectSummaries = exactly 1 walk.
        ledger.forEachEventWalkCount = 0
        _ = ledger.projectSummaries(in: m2bInterval, pricing: pricing)
        XCTAssertEqual(ledger.forEachEventWalkCount, 1)
        // (2) M2b: projectSummariesWithModels = STILL exactly 1 walk (folded in — NOT a sibling pass).
        ledger.forEachEventWalkCount = 0
        let (_, projectModels) = ledger.projectSummariesWithModels(in: m2bInterval, pricing: pricing)
        XCTAssertEqual(ledger.forEachEventWalkCount, 1)
        // (3) modelSummaries = exactly 1 walk. → projectPage's three components sum to 3 walks, unchanged by M2b.
        ledger.forEachEventWalkCount = 0
        _ = ledger.modelSummaries(in: m2bInterval, pricing: pricing)
        XCTAssertEqual(ledger.forEachEventWalkCount, 1)
        // (4) interaction: reading the pre-built slice performs ZERO ledger walks (a dict read, not aggregation).
        ledger.forEachEventWalkCount = 0
        for _ in 0..<50 { for key in projectModels.keys { _ = projectModels[key] } }
        XCTAssertEqual(ledger.forEachEventWalkCount, 0)
    }
}
