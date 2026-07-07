import Foundation

/// 本機用量帳本:彙整所有 provider 的正規化事件,為三個頁面與報告提供查詢。
/// 帳本是「provider 全域」的聚合,而非單一終端面板的即時值(規格核心要求)。
public final class UsageLedger {
    public private(set) var events: [UsageEvent] = []
    private var ids: Set<String> = []
    private let fileURL: URL?
    /// 我們上次讀寫後帳本檔應有的大小;不符表示其他行程動過 → 重新載入。
    private var expectedFileSize: Int64 = 0

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        loadFromDisk()
    }

    private func loadFromDisk() {
        events = []
        ids = []
        expectedFileSize = 0
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        expectedFileSize = Int64(data.count)
        let decoder = AtomicJSON.decoder()
        var loaded: [UsageEvent] = []
        data.split(separator: 0x0A).forEach { line in
            if let e = try? decoder.decode(UsageEvent.self, from: Data(line)), !ids.contains(e.id) {
                ids.insert(e.id)
                loaded.append(e)
            }
        }
        events = loaded.sorted { $0.timestamp < $1.timestamp }
    }

    private func diskSize() -> Int64 {
        guard let fileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// 其他行程(app ↔ CLI)寫入過帳本時,重新載入以收斂。
    /// ID 為內容穩定鍵,重載後去重保證不重複計費。
    public func reloadIfChanged() {
        guard fileURL != nil, diskSize() != expectedFileSize else { return }
        loadFromDisk()
    }

    /// 去重後併入新事件(keep-first,串流重複行不會重複計費),回傳實際新增數。
    @discardableResult
    public func append(_ newEvents: [UsageEvent]) -> Int {
        var inserted: [UsageEvent] = []
        for e in newEvents where !ids.contains(e.id) {
            ids.insert(e.id)
            inserted.append(e)
        }
        guard !inserted.isEmpty else { return 0 }
        events.append(contentsOf: inserted)
        events.sort { $0.timestamp < $1.timestamp }
        persistAppend(inserted)
        return inserted.count
    }

    private func persistAppend(_ newEvents: [UsageEvent]) {
        guard let fileURL else { return }
        do {
            try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
            let encoder = AtomicJSON.encoder()
            var blob = Data()
            for e in newEvents {
                blob.append(try encoder.encode(e))
                blob.append(0x0A)
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                if end > 0 {
                    let reader = try FileHandle(forReadingFrom: fileURL)
                    defer { try? reader.close() }
                    try reader.seek(toOffset: end - 1)
                    if try reader.read(upToCount: 1)?.first != 0x0A {
                        blob.insert(0x0A, at: 0)
                    }
                }
                try handle.write(contentsOf: blob)
                expectedFileSize = Int64(end) + Int64(blob.count)
            } else {
                try blob.write(to: fileURL, options: .atomic)
                expectedFileSize = Int64(blob.count)
            }
        } catch {
            // 帳本寫入失敗不應中斷 UI;下次全量重建可恢復。
        }
    }

    /// 丟棄保留期以外的舊事件並重寫帳本檔。
    public func compact(retentionDays: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        let kept = events.filter { $0.timestamp >= cutoff }
        guard kept.count != events.count else { return }
        events = kept
        ids = Set(kept.map(\.id))
        guard let fileURL else { return }
        let encoder = AtomicJSON.encoder()
        var blob = Data()
        for e in kept {
            if let d = try? encoder.encode(e) { blob.append(d); blob.append(0x0A) }
        }
        try? blob.write(to: fileURL, options: .atomic)
        expectedFileSize = Int64(blob.count)
    }

    /// 清除指定 provider 的事件(全量重建索引時只重建目前可用的 provider)。
    public func clearProviders(_ providerIds: Set<String>) {
        guard !providerIds.isEmpty else { return }
        let kept = events.filter { !providerIds.contains($0.providerId) }
        guard kept.count != events.count else { return }
        events = kept
        ids = Set(kept.map(\.id))
        guard let fileURL else { return }
        let encoder = AtomicJSON.encoder()
        var blob = Data()
        for e in kept {
            if let d = try? encoder.encode(e) { blob.append(d); blob.append(0x0A) }
        }
        try? blob.write(to: fileURL, options: .atomic)
        expectedFileSize = Int64(blob.count)
    }

    /// 清空(全量重建索引前呼叫)。
    public func reset() {
        events = []
        ids = []
        expectedFileSize = 0
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - 查詢

    public func events(in interval: DateInterval, providerId: String? = nil) -> [UsageEvent] {
        // events 依時間排序,二分找下界。
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].timestamp < interval.start { lo = mid + 1 } else { hi = mid }
        }
        var out: [UsageEvent] = []
        var i = lo
        while i < events.count, events[i].timestamp < interval.end {
            if providerId == nil || events[i].providerId == providerId {
                out.append(events[i])
            }
            i += 1
        }
        return out
    }

    public func totals(in interval: DateInterval, providerId: String? = nil) -> TokenBreakdown {
        events(in: interval, providerId: providerId).reduce(.zero) { $0 + $1.tokens }
    }

    public func newestEvent(providerId: String? = nil) -> UsageEvent? {
        if providerId == nil { return events.last }
        return events.last(where: { $0.providerId == providerId })
    }

    /// 尾隨窗口的燃燒率(tokens/小時)。
    public func burnRatePerHour(providerId: String? = nil, window: TimeInterval = 3600, now: Date = Date()) -> Double {
        let interval = DateInterval(start: now.addingTimeInterval(-window), end: now)
        let total = totals(in: interval, providerId: providerId).total
        return Double(total) / (window / 3600)
    }

    public func hourlyBuckets(in interval: DateInterval, calendar: Calendar = .current) -> [HourBucket] {
        struct Acc {
            var breakdown = TokenBreakdown.zero
            var byProvider: [String: Int] = [:]
            var byProject: [String: Int] = [:]
        }
        let evs = events(in: interval)
        var buckets: [Date: Acc] = [:]
        for e in evs {
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: e.timestamp)
            guard let hourStart = calendar.date(from: comps) else { continue }
            var acc = buckets[hourStart] ?? Acc()
            acc.breakdown = acc.breakdown + e.tokens
            acc.byProvider[e.providerId, default: 0] += e.tokens.total
            acc.byProject[e.projectName ?? "(unknown)", default: 0] += e.tokens.total
            buckets[hourStart] = acc
        }
        return buckets.keys.sorted().map { start in
            let acc = buckets[start]!
            return HourBucket(start: start,
                              tokens: acc.breakdown.total,
                              byProvider: acc.byProvider,
                              breakdown: acc.breakdown,
                              topProject: acc.byProject.max { $0.value < $1.value }?.key)
        }
    }

    public func projectSummaries(in interval: DateInterval, pricing: PricingRegistry) -> [ProjectSummary] {
        let evs = events(in: interval)
        let periodTotal = max(1, evs.reduce(0) { $0 + $1.tokens.total })
        var groups: [String: [UsageEvent]] = [:]
        for e in evs {
            groups[e.projectId ?? "(unknown project)", default: []].append(e)
        }
        return groups.map { projectId, group in
            let tokens = group.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
            var modelTokens: [String: Int] = [:]
            for e in group { modelTokens[e.modelId ?? "unknown", default: 0] += e.tokens.total }
            let topModel = modelTokens.max { $0.value < $1.value }?.key
            return ProjectSummary(
                projectId: projectId,
                projectName: group.last?.projectName ?? projectId,
                tokens: tokens,
                cost: pricing.cost(of: group),
                providers: Array(Set(group.map(\.providerId))).sorted(),
                topModel: topModel,
                lastActive: group.map(\.timestamp).max(),
                shareOfPeriod: Double(tokens.total) / Double(periodTotal)
            )
        }
        .sorted { $0.tokens.total > $1.tokens.total }
    }

    public func modelSummaries(in interval: DateInterval, pricing: PricingRegistry) -> [ModelUsageSummary] {
        let evs = events(in: interval)
        var groups: [String: [UsageEvent]] = [:]
        for e in evs {
            let key = e.providerId + "/" + (e.modelId ?? "unknown")
            groups[key, default: []].append(e)
        }
        return groups.values.map { group in
            ModelUsageSummary(
                providerId: group[0].providerId,
                modelId: group[0].modelId ?? "unknown",
                tokens: group.reduce(.zero) { $0 + $1.tokens },
                cost: pricing.cost(of: group)
            )
        }
        .sorted { $0.tokens.total > $1.tokens.total }
    }
}

public extension DateInterval {
    static func today(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        return DateInterval(start: start, end: now)
    }

    static func day(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, duration: 86400)
    }

    static func trailing(days: Int, now: Date = Date()) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-Double(days) * 86400), end: now)
    }
}
