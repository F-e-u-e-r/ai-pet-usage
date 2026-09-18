import Foundation
import UsageCore

// Usage-M2a additions — global provider-scoped "By model" breakdown (design §11, frozen v0.7).
// Reuses the m0* fixture/helpers from UnattributedModelTests.swift (same module).

let emptyPricing = PricingRegistry(entries: [])

func m2aEv(_ id: String, _ provider: String, _ model: String, _ inputTokens: Int) -> UsageEvent {
    UsageEvent(id: id, providerId: provider, modelId: model, timestamp: date("2026-07-25T05:00:00Z"),
               tokens: TokenBreakdown(input: inputTokens), sourceKind: "test")
}

func m2aTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aipet-m2a-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

final class ModelBreakdownM2aTests: XCTestCase {

    // Exact model identity — fable-5 vs fable-5-1 distinct; + normalization twin (M8).
    func testM2a_ExactModelIds_Fable5NotMergedWithFable51() {
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([
            m2aEv("f1", "claude-code", "claude-fable-5", 100),
            m2aEv("f2", "claude-code", "claude-fable-5-1", 200),
        ])
        let rows = ledger.modelSummaries(in: m0Interval, pricing: emptyPricing)
        XCTAssertEqual(rows.first { $0.modelId == "claude-fable-5" }?.tokens.total, 100)
        XCTAssertEqual(rows.first { $0.modelId == "claude-fable-5-1" }?.tokens.total, 200)
        // normalization twin (M8): case + trailing space + date suffix stay THREE distinct rows.
        let l2 = UsageLedger(fileURL: nil)
        _ = l2.append([
            m2aEv("n1", "claude-code", "claude-fable-5", 10),
            m2aEv("n2", "claude-code", "Claude-Fable-5 ", 20),
            m2aEv("n3", "claude-code", "claude-fable-5-2026-01-01", 30),
        ])
        let claudeRows = l2.modelSummaries(in: m0Interval, pricing: emptyPricing).filter { $0.providerId == "claude-code" }
        XCTAssertEqual(claudeRows.count, 3)
        XCTAssertEqual(Set(claudeRows.map { $0.modelId }),
                       Set([Optional("claude-fable-5"), Optional("Claude-Fable-5 "), Optional("claude-fable-5-2026-01-01")]))
    }

    // Exact model identity — a slash-bearing modelId must not collide under (provider, model) reshuffle.
    func testM2a_ExactModelIds_SlashModelIdDoesNotCollide() {
        let a = ModelUsageSummary(providerId: "opencode", attribution: .model(id: "moonshotai/kimi-k3"), tokens: .zero, cost: .zero)
        let b = ModelUsageSummary(providerId: "opencode/moonshotai", attribution: .model(id: "kimi-k3"), tokens: .zero, cost: .zero)
        XCTAssertTrue(a.id != b.id)
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([m2aEv("k", "opencode", "moonshotai/kimi-k3", 500)])
        let rows = ledger.modelSummaries(in: m0Interval, pricing: emptyPricing)
        XCTAssertEqual(rows.first { $0.providerId == "opencode" }?.modelId, "moonshotai/kimi-k3")
    }

    // M10 — the pricing-settings feed never manufactures a pseudo-model "unknown" for nil-model events.
    func testM2a_UnattributedNotListedAsPseudoModelInPricingSettings() {
        let dir = m2aTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL).append([
            UsageEvent(id: "u", providerId: "codex", modelId: nil, timestamp: date("2026-07-25T02:00:00Z"),
                       tokens: TokenBreakdown(input: 100), sourceKind: "codex-rollout"),
            UsageEvent(id: "a", providerId: "codex", modelId: "gpt-5.6-sol", timestamp: date("2026-07-25T02:01:00Z"),
                       tokens: TokenBreakdown(input: 50), sourceKind: "codex-rollout"),
        ])
        let coord = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                     adapters: [], readOnly: true)
        // UsageCoordinator is an actor — bridge the isolated call synchronously (same pattern as runRefresh).
        let sem = DispatchSemaphore(value: 0)
        var seen: [(model: ModelUsageSummary, price: ModelPrice?)] = []
        Task { seen = await coord.modelsSeenWithPricing(days: 3, now: date("2026-07-26T00:00:00Z")); sem.signal() }
        sem.wait()
        XCTAssertFalse(seen.contains { $0.model.modelId == "unknown" })   // no pseudo-model "unknown"
        XCTAssertFalse(seen.contains { $0.model.modelId == nil })         // .unattributed is not priceable (D1)
        XCTAssertTrue(seen.contains { $0.model.modelId == "gpt-5.6-sol" })
    }

    // INV-1 over the M2a builder — per-component conservation (§6: NOT total alone; a component swap must fail).
    func testM2a_GlobalModelTokenSumEqualsProviderTotal() {
        let events = m0FixtureEvents()
        let rows = m0Ledger().modelSummaries(in: m0Interval, pricing: m0Pricing())
        for provider in ["codex", "grok-code"] {
            let evSum = events.filter { $0.providerId == provider }.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
            let rowSum = rows.filter { $0.providerId == provider }.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
            XCTAssertEqual(rowSum.input, evSum.input)
            XCTAssertEqual(rowSum.output, evSum.output)
            XCTAssertEqual(rowSum.cacheRead + rowSum.cacheWrite, evSum.cacheRead + evSum.cacheWrite)   // "cache" component
            XCTAssertEqual(rowSum.total, evSum.total)
        }
        XCTAssertEqual(rows.filter { $0.providerId == "codex" }.reduce(0) { $0 + $1.tokens.total }, m0CodexTotal)
        XCTAssertEqual(rows.filter { $0.providerId == "grok-code" }.reduce(0) { $0 + $1.tokens.total }, m0GrokUnattributedTotal)
    }

    // Deterministic total order — stable across runs and shuffled append order.
    func testM2a_DeterministicOrdering_TotalOrderStableAcrossRuns() {
        let events = m0FixtureEvents()
        let l1 = UsageLedger(fileURL: nil); _ = l1.append(events)
        let l2 = UsageLedger(fileURL: nil); _ = l2.append(events.reversed())
        let o1 = l1.modelSummaries(in: m0Interval, pricing: m0Pricing()).map { $0.id }
        let o2 = l2.modelSummaries(in: m0Interval, pricing: m0Pricing()).map { $0.id }
        XCTAssertEqual(o1, o2)
        XCTAssertEqual(o1, l1.modelSummaries(in: m0Interval, pricing: m0Pricing()).map { $0.id })   // build twice
        let full = l1.modelSummaries(in: m0Interval, pricing: m0Pricing())
        // providers by total desc: codex (93717) before grok-code (550).
        XCTAssertEqual(full.first?.providerId, "codex")
        XCTAssertEqual(full.last?.providerId, "grok-code")
        // within codex: total desc, unattributed after equal-total attributed, modelId asc.
        // totals — unattributed 92603 > gpt-5.6-sol 1100 > unknown 14.
        let codexModelIds = full.filter { $0.providerId == "codex" }.map { $0.modelId }
        XCTAssertEqual(codexModelIds, [nil, "gpt-5.6-sol", "unknown"])
    }

    // r4-C — each row component asserted against INDEPENDENT fixture values (not the internal identity).
    // Cache fixture carries non-zero cacheRead + all three cacheWrite* sub-components.
    func testM2a_InOutCacheTotalConservation() {
        let ledger = UsageLedger(fileURL: nil)
        let tk = TokenBreakdown(input: 111, output: 222, cacheRead: 333,
                                cacheWrite5m: 444, cacheWrite1h: 555, cacheWriteUnknown: 666)
        _ = ledger.append([UsageEvent(id: "c", providerId: "codex", modelId: "gpt-5.6-sol",
                                      timestamp: date("2026-07-25T02:00:00Z"), tokens: tk, sourceKind: "codex-rollout")])
        let row = ledger.modelSummaries(in: m0Interval, pricing: emptyPricing).first { $0.providerId == "codex" }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.tokens.input, 111)
        XCTAssertEqual(row?.tokens.output, 222)
        // "cache" column = cacheRead + cacheWrite (5m+1h+unknown); each against its known fixture value.
        XCTAssertEqual(row?.tokens.cacheRead, 333)
        XCTAssertEqual(row?.tokens.cacheWrite, 444 + 555 + 666)
        XCTAssertEqual((row?.tokens.cacheRead ?? 0) + (row?.tokens.cacheWrite ?? 0), 333 + 444 + 555 + 666)  // 1998
        XCTAssertEqual(row?.tokens.total, 111 + 222 + 333 + 444 + 555 + 666)                  // 2331
    }

    // Cost presentation — partial ("$X.XX+") vs all-unpriced ("Pricing unavailable"); assert the actual string.
    func testM2a_CostPartialAndUnavailable() {
        let pricing = m0Pricing()
        // partial: one priced (gpt-5.6-sol, large so knownUSD ≥ $0.005) + one unpriced attributed model.
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([
            UsageEvent(id: "p", providerId: "codex", modelId: "gpt-5.6-sol", timestamp: date("2026-07-25T02:00:00Z"),
                       tokens: TokenBreakdown(input: 1_000_000), sourceKind: "codex-rollout"),
            UsageEvent(id: "u", providerId: "codex", modelId: "totally-unpriced-model-xyz",
                       timestamp: date("2026-07-25T02:01:00Z"), tokens: TokenBreakdown(input: 500), sourceKind: "codex-rollout"),
        ])
        let groupCost = ledger.modelSummaries(in: m0Interval, pricing: pricing)
            .filter { $0.providerId == "codex" }.reduce(CostResult.zero) { $0 + $1.cost }
        XCTAssertGreaterThan(groupCost.knownUSD, 0.0)
        XCTAssertGreaterThan(groupCost.unknownModelTokens, 0)
        XCTAssertEqual(ReportGenerator.costDisplay(groupCost).value, ReportGenerator.fmtUSD(groupCost.knownUSD) + "+")
        // all-unpriced grok-code group → "Pricing unavailable" (never $0).
        let grokLedger = UsageLedger(fileURL: nil)
        _ = grokLedger.append([UsageEvent(id: "g", providerId: "grok-code", modelId: "grok-code-fast",
                                          timestamp: date("2026-07-25T02:00:00Z"),
                                          tokens: TokenBreakdown(input: 1000), sourceKind: "grok-code")])
        let grokCost = grokLedger.modelSummaries(in: m0Interval, pricing: pricing).reduce(CostResult.zero) { $0 + $1.cost }
        XCTAssertEqual(grokCost.knownUSD, 0.0, accuracy: 1e-9)
        XCTAssertEqual(ReportGenerator.costDisplay(grokCost).value, "Pricing unavailable")
    }

    // r4-A — an unattributed row carrying providerCostUSD is priced + provenanced (not "cost unavailable").
    func testM2a_UnattributedWithProviderCostIsPriced() {
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([
            UsageEvent(id: "oc", providerId: "opencode", modelId: nil, timestamp: date("2026-07-25T02:00:00Z"),
                       tokens: TokenBreakdown(input: 1000), sourceKind: "opencode", providerCostUSD: 0.42),
            UsageEvent(id: "cx", providerId: "codex", modelId: nil, timestamp: date("2026-07-25T02:01:00Z"),
                       tokens: TokenBreakdown(input: 500), sourceKind: "codex-rollout"),
        ])
        let rows = ledger.modelSummaries(in: m0Interval, pricing: m0Pricing())
        let oc = rows.first { $0.providerId == "opencode" && $0.attribution == .unattributed }
        XCTAssertNotNil(oc)
        XCTAssertEqual(oc?.cost.knownUSD ?? -1, 0.42, accuracy: 1e-9)              // r2-E: exact provider-reported cost
        XCTAssertEqual(oc?.cost.providerReportedUSD ?? -1, 0.42, accuracy: 1e-9)
        XCTAssertEqual(oc?.cost.unknownModelTokens, 0)
        // r2-E: per-FIELD provider-level cost conservation on a NONZERO providerReported fixture (INV-5) — a
        // misaggregation that doubled provider-reported cost would flip this (the all-zero m0 fixture could not).
        let ocEvents = [UsageEvent(id: "oc", providerId: "opencode", modelId: nil, timestamp: date("2026-07-25T02:00:00Z"),
                                   tokens: TokenBreakdown(input: 1000), sourceKind: "opencode", providerCostUSD: 0.42)]
        let ocProvCost = m0Pricing().cost(of: ocEvents)
        let ocRowCost = rows.filter { $0.providerId == "opencode" }.reduce(CostResult.zero) { $0 + $1.cost }
        XCTAssertEqual(ocProvCost.knownUSD, ocRowCost.knownUSD, accuracy: 1e-6)
        XCTAssertEqual(ocProvCost.providerReportedUSD, ocRowCost.providerReportedUSD, accuracy: 1e-6)
        XCTAssertEqual(ocProvCost.unknownModelTokens, ocRowCost.unknownModelTokens)
        XCTAssertEqual(ocProvCost.isEstimated, ocRowCost.isEstimated)
        let cx = rows.first { $0.providerId == "codex" && $0.attribution == .unattributed }
        XCTAssertNotNil(cx)
        XCTAssertEqual(cx?.cost.knownUSD ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertGreaterThan(cx?.cost.unknownModelTokens ?? -1, 0)
        // presentation (r4-A): report cost cell follows the row's CostResult — asserted ROW-SPECIFICALLY.
        let html = ReportGenerator.generateHTML(m0MinimalReport(models: rows))
        let ocRow = html.components(separatedBy: "<tr").first { $0.contains("opencode/unattributed") }
        XCTAssertNotNil(ocRow)
        XCTAssertTrue(ocRow?.contains("opencode-reported") == true)          // provenance on THIS row
        XCTAssertTrue(ocRow?.contains(ReportGenerator.fmtUSD(0.42)) == true) // r2-G: EXACT formatted known cost ($0.42), independent oracle
        XCTAssertFalse(ocRow?.contains("cost unavailable") == true)          // NOT the unavailable text
        let cxRow = html.components(separatedBy: "<tr").first { $0.contains("codex/unattributed") }
        XCTAssertNotNil(cxRow)
        XCTAssertTrue(cxRow?.contains("unattributed — cost unavailable") == true)
        XCTAssertFalse(cxRow?.contains("Add a user override") == true)       // never the override hint on unattributed
        // r2-G: costDisplay for the opencode-reported row — value + caption asserted EXACTLY (independent of the row).
        let ocDisplay = ReportGenerator.costDisplay(oc?.cost ?? .zero)
        XCTAssertEqual(ocDisplay.value, ReportGenerator.fmtUSD(0.42))
        XCTAssertEqual(ocDisplay.caption, "opencode-reported (models.dev rates, est.)")
    }

    // Guards D — the model row/type exposes no provider-limit percentage field.
    func testM2a_ProjectionCarriesNoProviderLimitPercent() {
        let row = ModelUsageSummary(providerId: "codex", attribution: .unattributed, tokens: .zero, cost: .zero)
        let fields = Set(Mirror(reflecting: row).children.compactMap { $0.label })
        XCTAssertFalse(fields.contains { $0.lowercased().contains("percent") || $0.lowercased().contains("limit") })
        XCTAssertEqual(fields, Set(["providerId", "attribution", "tokens", "cost"]))
    }

    // §8 — grok rows are session-level; input excludes cache (the F5 double-count trap).
    func testM2a_GrokRowsAreSessionLevel_InputExcludesCache() {
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([UsageEvent(id: "gk", providerId: "grok-code", modelId: "grok-code-fast",
                                      timestamp: date("2026-07-25T02:00:00Z"),
                                      tokens: TokenBreakdown(input: 1000, cacheRead: 500), sourceKind: "grok-code")])
        let row = ledger.modelSummaries(in: m0Interval, pricing: emptyPricing).first { $0.providerId == "grok-code" }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.tokens.input, 1000)                 // input == Σ event.input
        XCTAssertTrue(row?.tokens.input != 1000 + 500)          // input != input + cache
        XCTAssertEqual(row?.tokens.cacheRead, 500)              // cache tracked separately
    }

    // P-B co-fix — the "Top model" cell routes through attributedModelLabel (redacts path, "—" nil, empty-id).
    func testM2a_ProjectTableTopModelIsRedacted() {
        XCTAssertEqual(PrivacyRedaction.attributedModelLabel(modelId: "/Users/alice/Secret/model.bin"), "model.bin")
        XCTAssertEqual(PrivacyRedaction.attributedModelLabel(modelId: nil), "—")
        XCTAssertEqual(PrivacyRedaction.attributedModelLabel(modelId: ""), "empty model id")
        XCTAssertEqual(PrivacyRedaction.attributedModelLabel(modelId: "anthropic/claude-x"), "anthropic/claude-x")
        XCTAssertFalse(PrivacyRedaction.attributedModelLabel(modelId: "/Users/alice/Secret/model.bin").contains("/Users/"))
    }

    // r1-C — §2 total order tie-breaks (providerId asc, attributed-before-unattributed, exact modelId asc)
    // must all be exercised. Equal provider totals AND equal within-provider row totals.
    func testM2a_DeterministicOrdering_TieBreaks() {
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([
            m2aEv("b1", "bbb", "bbb-model", 150),                        // provider bbb total 150
            m2aEv("a1", "aaa", "m-b", 50),                               // aaa: m-b 50
            m2aEv("a2", "aaa", "m-a", 50),                               // aaa: m-a 50 (equal total → modelId asc)
            UsageEvent(id: "a3", providerId: "aaa", modelId: nil, timestamp: date("2026-07-25T05:00:00Z"),
                       tokens: TokenBreakdown(input: 50), sourceKind: "test"),   // aaa unattributed 50 (equal → last)
        ])                                                               // aaa total 150 == bbb total 150 → providerId asc
        let rows = ledger.modelSummaries(in: m0Interval, pricing: emptyPricing)
        let order = rows.map { "\($0.providerId)/\($0.modelId ?? "∅")" }
        // aaa before bbb (providerId tie-break); within aaa: m-a, m-b (modelId asc), then unattributed (last).
        XCTAssertEqual(order, ["aaa/m-a", "aaa/m-b", "aaa/∅", "bbb/bbb-model"])
    }

    // r1-D — slash + empty-id collision-freedom at AGGREGATION (accumulator key), not just constructed ids.
    func testM2a_SlashAndEmptyIdAggregationCollisionFree() {
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([
            m2aEv("s1", "opencode", "moonshotai/kimi-k3", 100),
            m2aEv("s2", "opencode/moonshotai", "kimi-k3", 200),          // must NOT merge with s1
            m2aEv("e1", "codex", "", 30),                               // .model(id: "") — a distinct attributed row
            UsageEvent(id: "e2", providerId: "codex", modelId: nil, timestamp: date("2026-07-25T05:00:00Z"),
                       tokens: TokenBreakdown(input: 40), sourceKind: "test"),   // .unattributed
        ])
        let rows = ledger.modelSummaries(in: m0Interval, pricing: emptyPricing)
        let s1 = rows.first { $0.providerId == "opencode" && $0.modelId == "moonshotai/kimi-k3" }
        let s2 = rows.first { $0.providerId == "opencode/moonshotai" && $0.modelId == "kimi-k3" }
        XCTAssertEqual(s1?.tokens.total, 100)
        XCTAssertEqual(s2?.tokens.total, 200)                            // reverting the accumulator KEY to concat → merge → flips
        XCTAssertTrue(s1?.id != s2?.id)
        let emptyId = rows.first { $0.providerId == "codex" && $0.attribution == .model(id: "") }
        let unattr = rows.first { $0.providerId == "codex" && $0.attribution == .unattributed }
        XCTAssertEqual(emptyId?.tokens.total, 30)                        // "" is a distinct attributed model, not unattributed
        XCTAssertEqual(unattr?.tokens.total, 40)
        XCTAssertTrue(emptyId?.id != unattr?.id)
    }

    // r1-B — row id equality is consistent with ModelAttributionKey equality (Swift canonical String ==).
    func testM2a_RowIdIsCanonicalEqualityConsistent() {
        // LIVE guard: canonical-equal providerIds must yield equal id. Without provider NFC the utf8.count
        // length-prefix differs (2 vs 3) → ids Swift-unequal. (Falsified by M-NO-NFC.)
        let precomposed = ModelUsageSummary(providerId: "\u{00E9}", attribution: .model(id: "x"), tokens: .zero, cost: .zero)
        let decomposed = ModelUsageSummary(providerId: "e\u{0301}", attribution: .model(id: "x"), tokens: .zero, cost: .zero)
        XCTAssertTrue(precomposed.providerId == decomposed.providerId)   // Swift canonical equality (providerId)
        XCTAssertEqual(precomposed.id, decomposed.id)                    // provider NFC keeps the length-prefix consistent
        // Documentation (NOT an NFC guard): canonical-equal MODEL IDs also yield equal id — via Swift's canonical
        // String == of the whole id (the model id is the un-prefixed tail), so model-id NFC is redundant to the
        // invariant (impl-r2 falsification: M-NO-NFC-MODEL cannot flip this — nothing to guard).
        let mPre = ModelUsageSummary(providerId: "codex", attribution: .model(id: "caf\u{00E9}"), tokens: .zero, cost: .zero)
        let mDec = ModelUsageSummary(providerId: "codex", attribution: .model(id: "cafe\u{0301}"), tokens: .zero, cost: .zero)
        XCTAssertTrue(mPre.modelId == mDec.modelId)                      // Swift canonical equality (model id)
        XCTAssertEqual(mPre.id, mDec.id)                                 // holds via canonical String == of the whole id
        XCTAssertEqual(ModelUsageSummary(providerId: "codex", attribution: .model(id: "gpt-5"), tokens: .zero, cost: .zero).id,
                       "m:5:codex:gpt-5")                                // ASCII unchanged
    }

    // r1-A — the report's legacy topModel cell routes through attributedModelLabel (§4): "" → "empty model id".
    func testM2a_ReportTopModelEmptyIdRendersClosedLabel() {
        let empt = ProjectSummary(projectId: "p", projectName: "demo", tokens: TokenBreakdown(input: 100),
                                  cost: .zero, providers: ["codex"], topModel: "", lastActive: nil, shareOfPeriod: 1.0)
        let html = ReportGenerator.generateHTML(m0MinimalReport(models: [], projects: [empt]))
        XCTAssertTrue(html.contains("empty model id"))                   // not blank (was displayModelId(""))
        let pathy = ProjectSummary(projectId: "p2", projectName: "demo2", tokens: TokenBreakdown(input: 50),
                                   cost: .zero, providers: ["codex"], topModel: "/Users/x/Secret/model.bin",
                                   lastActive: nil, shareOfPeriod: 1.0)
        let html2 = ReportGenerator.generateHTML(m0MinimalReport(models: [], projects: [pathy]))
        XCTAssertTrue(html2.contains("model.bin"))                       // path-shaped → basename (still redacted)
        XCTAssertFalse(html2.contains("/Users/"))
    }
}
