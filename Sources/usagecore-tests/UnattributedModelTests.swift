import Foundation
import UsageCore

// M0-3 / Usage-M2a — provider-scoped `unattributed` contract.
// Base spec: reviews/usage-limits-m0/attempt-001/M0-3-TEST-SPEC.md (names fixed; renaming = review finding).
// Design: docs/USAGE_MODEL_BREAKDOWN.internal.md §5/§11 (frozen v0.7).
//
// Fixture = the 5 synthetic events (U1/U2/A1/X1/C1) copied in shape from the 64 live rows (values synthetic).
// In-memory ledger: UsageLedger(fileURL: nil) + append(_:), so no ingestion-level enrichment (#56) runs here.

let m0Interval = DateInterval(start: date("2026-07-25T00:00:00Z"), end: date("2026-07-26T00:00:00Z"))

var m0UTC: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

// U1/U2: codex, nil model (unattributed). A1: codex, real model, SAME file+stem as U1 (the tempting neighbour).
// X1: grok-code, nil model (cross-provider control). C1: codex, LITERAL "unknown" model (collision control).
let m0U1 = UsageEvent(id: "cx:rollout-T1:100", providerId: "codex", modelId: nil,
                      timestamp: date("2026-07-25T02:12:42Z"),
                      tokens: TokenBreakdown(input: 1080, output: 267, cacheRead: 18176),
                      sourceKind: "codex-rollout", sourcePath: "fixtures/rollout-T1.jsonl")
let m0U2 = UsageEvent(id: "cx:rollout-T2:100", providerId: "codex", modelId: nil,
                      timestamp: date("2026-07-25T12:07:10Z"),
                      tokens: TokenBreakdown(input: 12720, output: 968, cacheRead: 59392),
                      sourceKind: "codex-rollout", sourcePath: "fixtures/rollout-T2.jsonl")
let m0A1 = UsageEvent(id: "cx:rollout-T1:900", providerId: "codex", modelId: "gpt-5.6-sol",
                      timestamp: date("2026-07-25T02:12:51Z"),
                      tokens: TokenBreakdown(input: 1000, output: 100, cacheRead: 0),
                      sourceKind: "codex-rollout", sourcePath: "fixtures/rollout-T1.jsonl")
let m0X1 = UsageEvent(id: "gk:synthetic:1", providerId: "grok-code", modelId: nil,
                      timestamp: date("2026-07-25T03:00:00Z"),
                      tokens: TokenBreakdown(input: 500, output: 50, cacheRead: 0),
                      sourceKind: "grok-code", sourcePath: "fixtures/grok-synthetic.jsonl")
let m0C1 = UsageEvent(id: "cx:rollout-T3:100", providerId: "codex", modelId: "unknown",
                      timestamp: date("2026-07-25T04:00:00Z"),
                      tokens: TokenBreakdown(input: 7, output: 7, cacheRead: 0),
                      sourceKind: "codex-rollout", sourcePath: "fixtures/rollout-T3.jsonl")

func m0FixtureEvents() -> [UsageEvent] { [m0U1, m0U2, m0A1, m0X1, m0C1] }

// Derived constants (computed from the events, self-checking).
let m0CodexUnattributedTotal = m0U1.tokens.total + m0U2.tokens.total          // 92603
let m0CodexTotal = m0U1.tokens.total + m0U2.tokens.total + m0A1.tokens.total + m0C1.tokens.total  // 93717
let m0GrokUnattributedTotal = m0X1.tokens.total                                // 550

func m0Ledger() -> UsageLedger {
    let ledger = UsageLedger(fileURL: nil)
    _ = ledger.append(m0FixtureEvents())
    return ledger
}

func m0Pricing() -> PricingRegistry { PricingRegistry.loadDefault(overridesURL: nil) }

final class UnattributedModelTests: XCTestCase {

    // MARK: - Layer A — pin-current (names retained; REWRITTEN on landing to assert the NEW behaviour,
    // so the diff shows the flip — M0-3 §3. Each has a Layer B counterpart that supersedes it.)

    // Was: nil-model + literal-"unknown" merge under a magic key. NOW: they no longer merge.
    func testPinCurrent_NilModelRowsAreAggregatedUnderMagicUnknownKey() {
        let rows = m0Ledger().modelSummaries(in: m0Interval, pricing: m0Pricing())
        // nil-model rows form a provider-scoped .unattributed row (U1+U2), distinct from literal "unknown".
        let unattr = rows.first { $0.providerId == "codex" && $0.attribution == .unattributed }
        XCTAssertEqual(unattr?.tokens.total, m0CodexUnattributedTotal)
        let literalUnknown = rows.filter { $0.providerId == "codex" && $0.modelId == "unknown" }
        XCTAssertEqual(literalUnknown.count, 1)                          // C1 alone, NOT merged with the nils
        XCTAssertEqual(literalUnknown.first?.tokens.total, m0C1.tokens.total)
    }

    // Was: the merged "unknown" row's full total unpriced. NOW: the .unattributed row's own total unpriced.
    func testPinCurrent_NilModelCostIsUnpricedNotZeroTokens() {
        let rows = m0Ledger().modelSummaries(in: m0Interval, pricing: m0Pricing())
        let unattr = rows.first { $0.providerId == "codex" && $0.attribution == .unattributed }
        XCTAssertNotNil(unattr)                                         // graceful under mutation (no crash)
        XCTAssertEqual(unattr?.cost.knownUSD ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(unattr?.cost.unknownModelTokens, m0CodexUnattributedTotal)  // tokens counted, not $0
        XCTAssertTrue(unattr?.cost.isEstimated == true)
    }

    // Was: topModel reports the bare "unknown". NOW: topModel is attributed-only (the real gpt-5.6-sol).
    func testPinCurrent_TopModelReportsMagicStringWhenUnattributedDominates() {
        let ledger = m0Ledger()
        XCTAssertEqual(ledger.dailyBuckets(in: m0Interval, calendar: m0UTC).first?.topModel, "gpt-5.6-sol")
        XCTAssertEqual(ledger.projectSummaries(in: m0Interval, pricing: m0Pricing()).first?.topModel, "gpt-5.6-sol")
    }

    // MARK: - Layer B — target contract (RED until Usage-M2a; the 5 M0-3 clauses verbatim)

    // Clause 1 — no silent drop: Σ per-model tokens (incl. unattributed) == that provider's total.
    func testUnattributed_NoSilentDrop_PerModelSumEqualsProviderTotal() {
        let pricing = m0Pricing()
        let rows = m0Ledger().modelSummaries(in: m0Interval, pricing: pricing)
        let codexSum = rows.filter { $0.providerId == "codex" }.reduce(0) { $0 + $1.tokens.total }
        XCTAssertEqual(codexSum, m0CodexTotal)
        let grokSum = rows.filter { $0.providerId == "grok-code" }.reduce(0) { $0 + $1.tokens.total }
        XCTAssertEqual(grokSum, m0GrokUnattributedTotal)
        // and WITHOUT the unattributed rows (fixture minus the nil-model events) — the sum tracks the
        // ledger, never a filter.
        let ledger2 = UsageLedger(fileURL: nil)
        _ = ledger2.append([m0A1, m0C1])
        let rows2 = ledger2.modelSummaries(in: m0Interval, pricing: pricing)
        let codexSum2 = rows2.filter { $0.providerId == "codex" }.reduce(0) { $0 + $1.tokens.total }
        XCTAssertEqual(codexSum2, m0A1.tokens.total + m0C1.tokens.total)
    }

    // Clause 2 — no guessing: a nil modelId is never resolved from a same-file/neighbour event.
    func testUnattributed_NoGuessing_SameFileNeighbourDoesNotAbsorbNilRows() {
        let rows = m0Ledger().modelSummaries(in: m0Interval, pricing: m0Pricing())
        // A1 (gpt-5.6-sol) shares sourcePath + file stem with U1, but must NOT absorb U1's nil tokens.
        let sol = rows.first { $0.providerId == "codex" && $0.modelId == "gpt-5.6-sol" }
        XCTAssertEqual(sol?.tokens.total, m0A1.tokens.total)
        let unattr = rows.first { $0.providerId == "codex" && $0.modelId == nil }
        XCTAssertEqual(unattr?.tokens.total, m0CodexUnattributedTotal)
        // nothing invented: codex modelIds are exactly {gpt-5.6-sol, unknown} + the unattributed marker (nil).
        let codexModelIds = Set(rows.filter { $0.providerId == "codex" }.map { $0.modelId })
        XCTAssertEqual(codexModelIds, Set([Optional("gpt-5.6-sol"), Optional("unknown"), nil]))
    }

    // Clause 3 — provider-scoped bucket: one unattributed row per provider, never merged across providers.
    func testUnattributed_ProviderScopedBuckets_NeverMergeAcrossProviders() {
        let rows = m0Ledger().modelSummaries(in: m0Interval, pricing: m0Pricing())
        let unattrRows = rows.filter { $0.attribution == .unattributed }
        XCTAssertEqual(unattrRows.count, 2)
        let codexUnattr = unattrRows.first { $0.providerId == "codex" }
        let grokUnattr = unattrRows.first { $0.providerId == "grok-code" }
        XCTAssertEqual(codexUnattr?.tokens.total, m0CodexUnattributedTotal)
        XCTAssertEqual(grokUnattr?.tokens.total, m0GrokUnattributedTotal)
        XCTAssertFalse(unattrRows.contains { $0.providerId == "claude-code" || $0.providerId == "opencode" })
        XCTAssertTrue(codexUnattr?.id != grokUnattr?.id)   // distinct Identifiable.id
    }

    // Clause 4 — explicit attribution replaces the magic string (+ slash-id collision + topModel semantics).
    func testUnattributed_ExplicitAttributionReplacesMagicString() {
        let rows = m0Ledger().modelSummaries(in: m0Interval, pricing: m0Pricing())
        // C1 (literal "unknown") stays an attributed .model(id: "unknown") with exactly C1.total.
        let c1Row = rows.first { $0.providerId == "codex" && $0.attribution == .model(id: "unknown") }
        XCTAssertNotNil(c1Row)
        XCTAssertEqual(c1Row?.tokens.total, m0C1.tokens.total)
        // the unattributed row is .unattributed with codexUnattributedTotal — they NO LONGER merge.
        let unattr = rows.first { $0.providerId == "codex" && $0.attribution == .unattributed }
        XCTAssertNotNil(unattr)
        XCTAssertEqual(unattr?.tokens.total, m0CodexUnattributedTotal)
        // no row carries modelId "unknown" unless an event literally did (only C1).
        let unknownRows = rows.filter { $0.modelId == "unknown" }
        XCTAssertEqual(unknownRows.count, 1)
        XCTAssertEqual(unknownRows.first?.tokens.total, m0C1.tokens.total)
        // Identifiable.id is unambiguous for a modelId containing "/" (tuple/escaped, not bare concat).
        let a = ModelUsageSummary(providerId: "opencode", attribution: .model(id: "moonshotai/kimi-k3"), tokens: .zero, cost: .zero)
        let b = ModelUsageSummary(providerId: "opencode/moonshotai", attribution: .model(id: "kimi-k3"), tokens: .zero, cost: .zero)
        XCTAssertTrue(a.id != b.id)
        // topModel is no longer the bare "unknown" for unattributed-dominated periods.
        XCTAssertTrue(m0Ledger().dailyBuckets(in: m0Interval, calendar: m0UTC).first?.topModel != "unknown")
        XCTAssertTrue(m0Ledger().projectSummaries(in: m0Interval, pricing: m0Pricing()).first?.topModel != "unknown")
        // amendment #5: an unattributed-ONLY period → topModel nil (never a synthesized string).
        let unattrOnly = UsageLedger(fileURL: nil); _ = unattrOnly.append([m0U1, m0U2])
        XCTAssertNil(unattrOnly.dailyBuckets(in: m0Interval, calendar: m0UTC).first?.topModel)
        XCTAssertNil(unattrOnly.projectSummaries(in: m0Interval, pricing: m0Pricing()).first?.topModel)
        // a period whose only attributed model is the literal C1 "unknown" → topModel "unknown" (a real model).
        let c1Only = UsageLedger(fileURL: nil); _ = c1Only.append([m0C1])
        XCTAssertEqual(c1Only.dailyBuckets(in: m0Interval, calendar: m0UTC).first?.topModel, "unknown")
        XCTAssertEqual(c1Only.projectSummaries(in: m0Interval, pricing: m0Pricing()).first?.topModel, "unknown")
    }

    // Clause 5 — tokens counted; cost unpriced by the registry (+ full-breakdown + no double-count).
    func testUnattributed_TokensCountedCostUnavailable() {
        let pricing = m0Pricing()
        let rows = m0Ledger().modelSummaries(in: m0Interval, pricing: pricing)
        let unattr = rows.first { $0.providerId == "codex" && $0.attribution == .unattributed }
        XCTAssertNotNil(unattr)                                         // graceful under mutation (no crash)
        XCTAssertEqual(unattr?.tokens, m0U1.tokens + m0U2.tokens)   // full TokenBreakdown, not just total
        XCTAssertEqual(unattr?.cost.knownUSD ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(unattr?.cost.unknownModelTokens, m0CodexUnattributedTotal)
        XCTAssertTrue(unattr?.cost.isEstimated == true)
        XCTAssertEqual(unattr?.cost.providerReportedUSD ?? -1, 0.0, accuracy: 1e-9)
        let sol = rows.first { $0.providerId == "codex" && $0.modelId == "gpt-5.6-sol" }
        XCTAssertNotNil(sol)
        XCTAssertGreaterThan(sol?.cost.knownUSD ?? -1, 0.0)
        // provider-level cost == Σ row cost (no double-count, no omission).
        let codexEvents = m0FixtureEvents().filter { $0.providerId == "codex" }
        let provCost = pricing.cost(of: codexEvents)
        let rowCostSum = rows.filter { $0.providerId == "codex" }.reduce(CostResult.zero) { $0 + $1.cost }
        XCTAssertEqual(provCost.knownUSD, rowCostSum.knownUSD, accuracy: 1e-6)
        XCTAssertEqual(provCost.unknownModelTokens, rowCostSum.unknownModelTokens)
        XCTAssertEqual(provCost.providerReportedUSD, rowCostSum.providerReportedUSD, accuracy: 1e-6)  // INV-5 per-field
        XCTAssertEqual(provCost.isEstimated, rowCostSum.isEstimated)
        // presentation sink: a registry-unpriced unattributed-only report reads the closed vocabulary and
        // does NOT print the "Add a user override…" hint (an override cannot price a nil-model event).
        let unattrOnly = UsageLedger(fileURL: nil); _ = unattrOnly.append([m0U1, m0U2])
        let html = ReportGenerator.generateHTML(m0MinimalReport(models: unattrOnly.modelSummaries(in: m0Interval, pricing: pricing)))
        XCTAssertTrue(html.contains("unattributed — cost unavailable"))
        XCTAssertFalse(html.contains("Add a user override"))
    }
}

// Minimal ReportData wrapper so the presentation-sink assertions can exercise the HTML report.
func m0MinimalReport(models: [ModelUsageSummary], projects: [ProjectSummary] = []) -> ReportData {
    ReportData(
        title: "M0 Test", period: m0Interval, generatedAt: date("2026-07-26T00:00:00Z"),
        timezoneName: "UTC", totals: .zero, cost: .zero, byProvider: [], limitStates: [],
        projects: projects, models: models, buckets: [], pricingRows: [], unknownModels: [],
        dataQuality: [], petSummary: nil)
}
