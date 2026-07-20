import Foundation

public struct ModelPrice: Codable, Sendable, Hashable, Identifiable {
    public var providerId: String
    /// 完整 model id,或以 `*` 結尾的前綴樣式(如 `claude-sonnet-4-5*`)。
    public var modelId: String
    public var displayName: String
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var cacheReadPerMillion: Double?
    public var cacheWrite5mPerMillion: Double?
    public var cacheWrite1hPerMillion: Double?
    public var currency: String
    public var effectiveFrom: String
    public var source: String
    public var userOverride: Bool

    public var id: String { providerId + "/" + modelId }

    public init(providerId: String, modelId: String, displayName: String,
                inputPerMillion: Double, outputPerMillion: Double,
                cacheReadPerMillion: Double? = nil,
                cacheWrite5mPerMillion: Double? = nil, cacheWrite1hPerMillion: Double? = nil,
                currency: String = "USD", effectiveFrom: String, source: String, userOverride: Bool = false) {
        self.providerId = providerId
        self.modelId = modelId
        self.displayName = displayName
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWrite5mPerMillion = cacheWrite5mPerMillion
        self.cacheWrite1hPerMillion = cacheWrite1hPerMillion
        self.currency = currency
        self.effectiveFrom = effectiveFrom
        self.source = source
        self.userOverride = userOverride
    }
}

/// 模型計價:內建預設 + 本機使用者覆寫檔。查無定價的模型不會套用預設價,
/// 而是回報 unknown,由 UI/報告明確標示(規格要求,避免默默算錯)。
public struct PricingRegistry: Sendable {
    public private(set) var entries: [ModelPrice]

    public init(entries: [ModelPrice]) {
        self.entries = entries
    }

    /// 四層載入:手動維護的價目 JSON(最可信)→ OpenRouter 生成的完整價目(長尾)
    /// → 內建 Swift 後備(資源遺失時)→ 使用者覆寫檔(最高優先)。
    public static func loadDefault(overridesURL: URL?) -> PricingRegistry {
        var entries = bundledPrices(named: "model-prices") ?? builtInDefaults
        if let generated = bundledPrices(named: "model-prices-generated") {
            let curatedKeys = Set(entries.map { $0.providerId + "|" + $0.modelId })
            // grok-code 不從生成價目自動計價:其 token 為 context-growth 低估值,
            // 自動套價會把粗估偽裝成精確成本(v1 刻意 unpriced;見 docs/DATA_SOURCES.md)。
            // 手動維護價目與使用者覆寫仍可刻意定價。
            entries += generated.filter {
                $0.providerId != "grok-code" && !curatedKeys.contains($0.providerId + "|" + $0.modelId)
            }
        }
        if let overridesURL, let overrides = AtomicJSON.read([ModelPrice].self, from: overridesURL) {
            for var o in overrides {
                o.userOverride = true
                entries.removeAll { $0.providerId == o.providerId && $0.modelId == o.modelId }
                entries.append(o)
            }
        }
        return PricingRegistry(entries: entries)
    }

    /// 讀取隨 app 打包的價目表(repo 的 Sources/UsageCore/Resources/*.json;
    /// generated 檔以 Scripts/update-price-list.py 重新產生)。
    /// 穩健定位 SwiftPM 資源包,不呼叫會在資源遺失時 fatalError 的 Bundle.module。
    /// 依序找 Bundle.main 的 resourceURL(合法 .app 結構的 Contents/Resources,app 主程式與
    /// 獨立執行的 aipet 皆解析於此;開發 / 測試時為 .build/release)與 bundleURL;
    /// 都找不到回 nil,交由呼叫端退回編譯內建價(不 crash)。
    static func resourceBundle() -> Bundle? {
        let name = "AIPetUsage_UsageCore.bundle"
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent(name)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            if let b = Bundle(url: c) { return b }
        }
        return nil
    }

    public static func bundledPrices(named name: String) -> [ModelPrice]? {
        guard let url = resourceBundle()?.url(forResource: name, withExtension: "json"),
              let prices = AtomicJSON.read([ModelPrice].self, from: url),
              !prices.isEmpty else { return nil }
        return prices
    }

    public func price(providerId: String, modelId: String?) -> ModelPrice? {
        guard let modelId, !modelId.isEmpty else { return nil }
        let candidates = entries.filter { $0.providerId == providerId }
        // 覆寫 > 精確 > 最長前綴。
        let ranked = candidates.sorted { a, b in
            if a.userOverride != b.userOverride { return a.userOverride }
            return a.modelId.count > b.modelId.count
        }
        for entry in ranked {
            if entry.modelId == modelId { return entry }
        }
        for entry in ranked where entry.modelId.hasSuffix("*") {
            let prefix = String(entry.modelId.dropLast())
            if modelId.hasPrefix(prefix) { return entry }
        }
        return nil
    }

    /// 計算單一事件成本。模型未知或無定價 → unknown token;快取欄位缺價 → 標記估計。
    public func cost(of event: UsageEvent) -> CostResult {
        // 單一優先序(R1 codex C4/grok G6):provider 自行回報的成本(如 opencode 的
        // session.cost 差額)存在且有效(adapter 端已保證有限、> 0、伴隨 token 差額)
        // → 該事件的成本就是它,token 不再走 registry 計價(不得雙重計費);
        // 一律標 estimated(models.dev 費率是估算,非發票),並記入 providerReportedUSD
        // 供 UI/報告標示出處。registry 對此事件的 unknown-model 判定同時解除。
        if let reported = event.providerCostUSD, reported.isFinite, reported > 0 {
            return CostResult(knownUSD: reported, unknownModelTokens: 0, isEstimated: true,
                              providerReportedUSD: reported)
        }
        guard let price = price(providerId: event.providerId, modelId: event.modelId) else {
            return CostResult(knownUSD: 0, unknownModelTokens: event.tokens.total, isEstimated: true)
        }
        let t = event.tokens
        var usd = Double(t.input) / 1e6 * price.inputPerMillion
        usd += Double(t.output) / 1e6 * price.outputPerMillion
        var estimated = false
        if t.cacheRead > 0 {
            if let p = price.cacheReadPerMillion { usd += Double(t.cacheRead) / 1e6 * p }
            else { estimated = true }
        }
        if t.cacheWrite5m > 0 {
            if let p = price.cacheWrite5mPerMillion { usd += Double(t.cacheWrite5m) / 1e6 * p }
            else { estimated = true }
        }
        if t.cacheWrite1h > 0 {
            if let p = price.cacheWrite1hPerMillion { usd += Double(t.cacheWrite1h) / 1e6 * p }
            else { estimated = true }
        }
        // TTL 未知的快取寫入無從逐類計價 → 該部分未入帳,結果標 estimated(下界;
        // R2 codex F11:不得呈現成「免費」的精確值)。
        if t.cacheWriteUnknown > 0 { estimated = true }
        return CostResult(knownUSD: usd, unknownModelTokens: 0, isEstimated: estimated)
    }

    public func cost(of events: [UsageEvent]) -> CostResult {
        events.reduce(.zero) { $0 + cost(of: $1) }
    }

    /// 後備價目:僅在打包資源 model-prices.json 遺失時使用。
    /// 正式價目以 Sources/UsageCore/Resources/model-prices.json 為準(較新且含來源)。
    public static let builtInDefaults: [ModelPrice] = [
        // Anthropic / Claude Code
        ModelPrice(providerId: "claude-code", modelId: "claude-opus-4-5*", displayName: "Claude Opus 4.5",
                   inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5,
                   cacheWrite5mPerMillion: 6.25, cacheWrite1hPerMillion: 10,
                   effectiveFrom: "2025-11-24", source: "anthropic.com/pricing built-in snapshot"),
        ModelPrice(providerId: "claude-code", modelId: "claude-opus-4-6*", displayName: "Claude Opus 4.6",
                   inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5,
                   cacheWrite5mPerMillion: 6.25, cacheWrite1hPerMillion: 10,
                   effectiveFrom: "2025-12-01", source: "anthropic.com/pricing built-in snapshot"),
        ModelPrice(providerId: "claude-code", modelId: "claude-sonnet-4-5*", displayName: "Claude Sonnet 4.5",
                   inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3,
                   cacheWrite5mPerMillion: 3.75, cacheWrite1hPerMillion: 6,
                   effectiveFrom: "2025-09-29", source: "anthropic.com/pricing built-in snapshot"),
        ModelPrice(providerId: "claude-code", modelId: "claude-haiku-4-5*", displayName: "Claude Haiku 4.5",
                   inputPerMillion: 1, outputPerMillion: 5, cacheReadPerMillion: 0.1,
                   cacheWrite5mPerMillion: 1.25, cacheWrite1hPerMillion: 2,
                   effectiveFrom: "2025-10-15", source: "anthropic.com/pricing built-in snapshot"),
        ModelPrice(providerId: "claude-code", modelId: "claude-opus-4-1*", displayName: "Claude Opus 4.1",
                   inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: 1.5,
                   cacheWrite5mPerMillion: 18.75, cacheWrite1hPerMillion: 30,
                   effectiveFrom: "2025-08-05", source: "anthropic.com/pricing built-in snapshot"),

        // OpenAI / Codex
        ModelPrice(providerId: "codex", modelId: "gpt-5", displayName: "GPT-5",
                   inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125,
                   effectiveFrom: "2025-08-07", source: "openai.com/api/pricing built-in snapshot"),
        ModelPrice(providerId: "codex", modelId: "gpt-5-codex*", displayName: "GPT-5 Codex",
                   inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125,
                   effectiveFrom: "2025-09-15", source: "openai.com/api/pricing built-in snapshot"),
        ModelPrice(providerId: "codex", modelId: "gpt-5.1*", displayName: "GPT-5.1",
                   inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125,
                   effectiveFrom: "2025-11-13", source: "openai.com/api/pricing built-in snapshot"),
        ModelPrice(providerId: "codex", modelId: "gpt-5-mini*", displayName: "GPT-5 mini",
                   inputPerMillion: 0.25, outputPerMillion: 2, cacheReadPerMillion: 0.025,
                   effectiveFrom: "2025-08-07", source: "openai.com/api/pricing built-in snapshot"),
    ]
}
