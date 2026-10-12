import Foundation
import UsageCore

/// 回歸:HTML 報表「Model pricing assumptions」的顯示列必須以**最長匹配前綴**選價,與
/// `pricingRows` 迭代順序無關。重疊 glob(claude-opus-5* 與 claude-opus-5-5* 等)下,舊 `.first`
/// 會依順序顯示較短前綴的價(成本仍正確,但顯示錯)。本 test 走真實 `ReportGenerator.generateHTML`
/// 路徑,非複製 matcher。成本計算不在本 test 範圍。
final class ReportPricingDisplayTests: XCTestCase {

    private func price(_ id: String, _ input: Double) -> ModelPrice {
        ModelPrice(providerId: "claude-code", modelId: id, displayName: id,
                   inputPerMillion: input, outputPerMillion: input * 5,
                   cacheReadPerMillion: input * 0.05,
                   effectiveFrom: "2026-10-12", source: "test")
    }
    private func model(_ id: String) -> ModelUsageSummary {
        ModelUsageSummary(providerId: "claude-code", attribution: .model(id: id),
                          tokens: TokenBreakdown(input: 1_000, output: 1_000),
                          cost: CostResult(knownUSD: 1.0))
    }
    private func report(models: [ModelUsageSummary], pricingRows: [ModelPrice]) -> ReportData {
        ReportData(title: "t",
                   period: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400),
                   generatedAt: Date(timeIntervalSince1970: 0), timezoneName: "UTC",
                   totals: .zero, cost: .zero, byProvider: [], limitStates: [], projects: [],
                   models: models, buckets: [], pricingRows: pricingRows, unknownModels: [],
                   dataQuality: [], petSummary: nil)
    }
    /// 取出含 `label` 的那一列 `<tr>…</tr>`。
    private func row(_ label: String, _ html: String) -> String {
        guard let r = html.range(of: label) else { return "" }
        let start = html.range(of: "<tr", options: .backwards,
                               range: html.startIndex..<r.lowerBound)?.lowerBound ?? r.lowerBound
        let end = html.range(of: "</tr>", range: r.upperBound..<html.endIndex)?.upperBound ?? html.endIndex
        return String(html[start..<end])
    }

    private let opus55Id = "claude-opus-5-5-20260401"   // 長前綴模型
    private let opus5Id  = "claude-opus-5-20251101"      // 短前綴模型(與上重疊)
    private let sonnetId = "claude-sonnet-4-6-20251101"  // 非重疊控制組

    /// C + E:opus-5-5 顯示自身 $4(不得繼承 opus-5 的 $5);opus-5 顯示 $5;非重疊 sonnet-4-6 維持 $3。
    private func assertCorrectDisplay(_ html: String, _ ctx: String) {
        let r55 = row("claude-code/\(opus55Id)", html)
        XCTAssertTrue(r55.contains("$4.000"), "\(ctx): opus-5-5 列須顯示自身 $4 input")
        XCTAssertFalse(r55.contains("$5.000"), "\(ctx): opus-5-5 列不得繼承 opus-5 的 $5(first-match bug)")
        let r5 = row("claude-code/\(opus5Id)", html)
        XCTAssertTrue(r5.contains("$5.000"), "\(ctx): opus-5 列須顯示 $5")
        let rS = row("claude-code/\(sonnetId)", html)
        XCTAssertTrue(rS.contains("$3.000"), "\(ctx): 非重疊 sonnet-4-6 須維持 $3")
    }

    /// A(短前綴先置於 pricingRows)+ B(長前綴亦匹配)+ C(選最長)+ E(非重疊不變)。
    func testOverlappingPrefixDisplaysLongestMatch_shortPrefixFirst() {
        let rows = [price("claude-opus-5*", 5), price("claude-opus-5-5*", 4), price("claude-sonnet-4-6*", 3)]
        let html = ReportGenerator.generateHTML(
            report(models: [model(opus55Id), model(opus5Id), model(sonnetId)], pricingRows: rows))
        assertCorrectDisplay(html, "short-prefix-first")
    }

    /// D:反轉 pricingRows 與 models 順序 → 顯示價不變(與順序無關)。
    func testOverlappingPrefixDisplayOrderIndependent_longPrefixFirst() {
        let rows = [price("claude-opus-5-5*", 4), price("claude-opus-5*", 5), price("claude-sonnet-4-6*", 3)]
        let html = ReportGenerator.generateHTML(
            report(models: [model(opus5Id), model(opus55Id), model(sonnetId)], pricingRows: rows))
        assertCorrectDisplay(html, "long-prefix-first")
    }
}
