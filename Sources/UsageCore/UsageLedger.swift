import Foundation

/// 帳本檔的身分指紋:偵測「其他行程改寫」用。只比 size 會被同大小內容替換騙過(codex C4),
/// 故納入 dev+inode+mtime(#44 契約 D)。
struct FileFingerprint: Equatable {
    let dev: Int64
    let ino: UInt64
    let size: Int64
    let mtimeSec: Int64
    let mtimeNsec: Int64
}

/// 本機用量帳本:彙整所有 provider 的正規化事件,為三個頁面與報告提供查詢。
/// 帳本是「provider 全域」的聚合,而非單一終端面板的即時值(規格核心要求)。
public final class UsageLedger {
    public private(set) var events: [UsageEvent] = []
    private var ids: Set<String> = []
    private let fileURL: URL?
    /// 記憶體事件集的單調世代號:load / append / compact / replace / reset 成功提交時 +1。
    /// 供上層(coordinator)做聚合快取的失效鍵 —— 世代未變 ⇒ 事件集完全相同。
    public private(set) var revision: UInt64 = 0
    /// 字串駐留池:provider/model/project/sourceKind 等欄位在 9 萬+ 事件間大量重複,
    /// 逐筆解碼各自持有一份會放大常駐記憶體;駐留讓相同值共用同一 String 緩衝。
    /// 只駐留低基數欄位,id(唯一值)不駐留。
    private var internPool: [String: String] = [:]

    private func intern(_ s: String?) -> String? {
        guard let s else { return nil }
        if let hit = internPool[s] { return hit }
        internPool[s] = s
        return s
    }

    /// 事件欄位駐留(低基數欄位共用緩衝;id/timestamp/tokens 原樣)。
    private func interned(_ e: UsageEvent) -> UsageEvent {
        var e = e
        e.providerId = intern(e.providerId) ?? e.providerId
        e.accountId = intern(e.accountId)
        e.projectId = intern(e.projectId)
        e.projectName = intern(e.projectName)
        e.modelId = intern(e.modelId)
        e.sourceKind = intern(e.sourceKind) ?? e.sourceKind
        e.sourcePath = intern(e.sourcePath)
        return e
    }

    /// 池重建:清空後只重插現存事件仍引用的字串(原地重繫,無新配置)。
    /// compact / replaceProviderSlice 移除事件後呼叫 —— 池的上界因此恆為
    /// 「現存事件的 distinct 欄位值」,已被保留期淘汰的字串不再永駐(xcheck r1)。
    private func rebuildInternPool() {
        internPool = [:]
        for i in events.indices { events[i] = interned(events[i]) }
    }

    /// 駐留池大小(diag / 測試觀察 boundedness 用;池為實作細節,勿據以編程)。
    public var internedStringCount: Int { internPool.count }
    /// 我們上次讀寫後帳本檔的身分指紋(dev,ino,size,mtime);不符表示其他行程動過 → 重新載入。
    /// 只比大小會被「同大小內容替換」騙過(codex C4);故比完整指紋(#44 契約 D)。
    private var expectedFingerprint: FileFingerprint?
    /// 非 nil 表示帳本檔存在但讀不到 / 中段損壞(poisoned)。此時記憶體不當空、寫入拒絕、
    /// coordinator 中止刷新,避免以空/半份資料覆寫使用者仍可救回的檔案(#44 契約 A/B)。
    public private(set) var loadError: Error?
    /// 最近一次 append 落盤失敗(交易式:記憶體未提交,無 split-brain)。每次 append 起始清空;
    /// coordinator 於 append 後檢查並上拋到 per-provider catch,不推進該 provider 的 watermark(契約 B/M5)。
    public private(set) var writeError: Error?
    /// 明確的「下一次 reloadIfChanged 必須重載」旗標(R2-MF5):append 半寫 / 讀取不穩時設。
    /// 比 expectedFingerprint=nil 哨兵可靠——後者在檔案同時 unstatable(currentFingerprint 亦 nil)時
    /// `nil != nil` 為 false 會漏掉重載。
    private var needsReload = false

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    /// 讀入帳本。三態:不存在(空帳本合法)、存在但 I/O 失敗(unreadable→poisoned)、
    /// 內容已收尾/中段行損壞(malformed→poisoned)。尾端未收尾片段(部分 append)可容忍。
    private func load() {
        loadError = nil
        needsReload = false
        events = []
        ids = []
        internPool = [:]
        revision &+= 1   // 任何重建都推進世代(過度失效安全;失效不足才是 bug)
        guard let fileURL else { return }
        // C-MF3:讀資料與取指紋之間可能被併發(持鎖)寫入夾擊 → 記憶體配到過期位元組卻標成新指紋。
        // 讀前後各取指紋,重試取穩定快照;仍不穩則 expectedFingerprint=nil 強制下一輪重載對帳。
        let data: Data
        var stableFingerprint: FileFingerprint?
        var attempt = 0
        while true {
            let fpBefore = currentFingerprint()
            let d: Data
            do {
                d = try Data(contentsOf: fileURL)
            } catch {
                // xcheck r1(sol MF1):讀不到時必須清掉舊指紋,否則「檔案被暫時移走→
                // 空帳本→同一 inode 移回(指紋不變)」會讓 reloadIfChanged 永遠跳過重載,
                // 帳本從此永空。清成 nil 後:檔案持續缺失 → nil==nil 穩態不重載(正確);
                // 檔案再現(任何指紋)→ nil != fp 觸發重載恢復。unreadable 分支由
                // reloadIfChanged 的 loadError 保護恢復 prior 指紋,不受影響。
                expectedFingerprint = nil
                if !AtomicJSON.pathIsGenuinelyMissing(fileURL.path) {
                    loadError = StateReadError.unreadable(underlying: error)   // 存在但讀不到/斷 symlink → poisoned
                }
                return   // 真的不存在 → 空帳本(合法)
            }
            let fpAfter = currentFingerprint()
            attempt += 1
            if fpBefore == fpAfter { data = d; stableFingerprint = fpAfter; break }
            if attempt >= 3 { data = d; stableFingerprint = fpAfter; needsReload = true; break }   // R2-MF5:仍不穩 → needsReload 強制下輪重載(不靠 nil 哨兵)
        }
        expectedFingerprint = stableFingerprint
        let decoder = AtomicJSON.decoder()
        var loaded: [UsageEvent] = []
        var firstDecodeError: Error?
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        loaded.reserveCapacity(lines.count)
        ids.reserveCapacity(lines.count)
        for line in lines {
            do {
                let e = try decoder.decode(UsageEvent.self, from: Data(line))
                if ids.insert(e.id).inserted { loaded.append(interned(e)) }
            } catch {
                // 零星無法解碼行(部分 append 的斷尾/斷頭)容忍——維持既有「斷尾→續寫復原」;僅記首錯。
                if firstDecodeError == nil { firstDecodeError = error }
            }
        }
        // 契約 A:非空內容卻解不出任何有效事件(含只有換行位元組的損壞檔)→ malformed(poisoned,不覆寫;C-MF7b)。
        if loaded.isEmpty && !data.isEmpty {
            loadError = StateReadError.malformed(underlying: firstDecodeError ?? JSONCodecError.notADictionary)
            return
        }
        events = loaded.sorted { $0.timestamp < $1.timestamp }
    }

    /// 目前磁碟檔的身分指紋(dev,ino,size,mtime);檔案不存在或 stat 失敗回 nil。
    private func currentFingerprint() -> FileFingerprint? {
        guard let fileURL else { return nil }
        var st = stat()
        guard stat(fileURL.path, &st) == 0 else { return nil }
        return FileFingerprint(dev: Int64(st.st_dev), ino: UInt64(st.st_ino), size: Int64(st.st_size),
                               mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec))
    }

    /// 其他行程(app ↔ CLI)寫入過帳本時,重新載入以收斂。
    /// ID 為內容穩定鍵,重載後去重保證不重複計費。
    public func reloadIfChanged() {
        // R2-MF5:needsReload 為明確的強制重載旗標(append 半寫 / 讀取不穩時設),優先於指紋比較。
        guard fileURL != nil, needsReload || currentFingerprint() != expectedFingerprint else { return }
        let priorEvents = events, priorIds = ids, priorFingerprint = expectedFingerprint
        load()
        if loadError != nil {
            // 非破壞式:讀取失敗不得清掉既有記憶體(否則後續寫入會覆寫好資料)。
            // 保留舊狀態;coordinator 見 loadError 會中止本輪寫入(#44 契約 A)。
            events = priorEvents
            ids = priorIds
            expectedFingerprint = priorFingerprint
            needsReload = true   // 讀取失敗 → 保持強制重載,下輪再試
            revision &+= 1       // 狀態又換回舊集 → 再推進一次世代(只多不少)
        }
    }

    /// 去重後併入新事件(keep-first,串流重複行不會重複計費),回傳實際新增數。
    /// 交易式 append(契約 B):先落盤成功才提交記憶體;失敗則**記憶體完全不變**(無 split-brain),
    /// 並設 `writeError` 供 coordinator 檢查後上拋。poisoned(loadError)時亦拒絕寫入。回傳實際新增數
    /// (落盤失敗回 0——0 可能是全去重或落盤失敗,呼叫端須以 `writeError` 區分,不可只看回傳值)。
    @discardableResult
    public func append(_ newEvents: [UsageEvent]) -> Int {
        writeError = nil
        if let loadError { writeError = loadError; return 0 }
        var inserted: [UsageEvent] = []
        var batchIds: Set<String> = []
        for e in newEvents where !ids.contains(e.id) && batchIds.insert(e.id).inserted {
            inserted.append(e)
        }
        guard !inserted.isEmpty else { return 0 }
        do {
            try persistAppend(inserted)          // 先落盤
        } catch {
            writeError = error                    // 失敗:記憶體不提交(無 split-brain),上報旗標
            needsReload = true                    // C-MF4/R2-MF5:部分寫入可能已改磁碟 → 強制下一次 reloadIfChanged 對帳
            return 0
        }
        // 落盤成功才提交記憶體;駐留也在此時才做(xcheck r1:失敗的 append 不得污染池,
        // 否則不可寫的帳本會讓連續失敗批次的字串無事件背書地永駐)。
        for e in inserted {
            ids.insert(e.id)
            events.append(interned(e))
        }
        events.sort { $0.timestamp < $1.timestamp }
        revision &+= 1
        return inserted.count
    }

    /// 清除上一輪的落盤失敗旗標(coordinator 於每輪刷新起始呼叫,避免陳舊 writeError 誤觸後續 break;R2-NIT)。
    public func clearWriteError() {
        writeError = nil
    }

    /// 落盤新增行。失敗即 throw(不再吞錯);呼叫端據此不提交記憶體(契約 B)。
    private func persistAppend(_ newEvents: [UsageEvent]) throws {
        guard let fileURL else { return }   // 記憶體模式:視為成功
        try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        let encoder = AtomicJSON.encoder()
        var blob = Data()
        for e in newEvents {
            blob.append(try encoder.encode(e))
            blob.append(0x0A)
        }
        // R2-MF6 / round-3 P1-A(tri-state fail-closed):原子「整檔建立」只在「確認缺檔」或「stat 成功且 size==0」;
        // stat 失敗 / 狀態不明一律不整檔覆寫(否則會把既有非空帳本清成只剩本批次 → 史料遺失)。其餘走 FileHandle
        // 續尾,且**開檔後以實際 end 為準**(不信任先前 stat),`if end > 0` 亦避免 stat/open 間被截斷至 0 造成 end-1 underflow。
        let fp = currentFingerprint()
        if AtomicJSON.pathIsGenuinelyMissing(fileURL.path) {
            try blob.write(to: fileURL, options: .atomic)                 // 確認缺檔 → 原子建立
            expectedFingerprint = currentFingerprint()
        } else if let fp {
            if fp.size == 0 {
                try blob.write(to: fileURL, options: .atomic)            // stat 成功且確認空檔 → 原子建立
                expectedFingerprint = currentFingerprint()
            } else {
                // stat 成功且非空 → FileHandle 續尾。開檔後以**實際** end 為準(不信任先前 stat),
                // `if end > 0` 亦避免 stat/open 間被截斷至 0 造成 end-1 underflow。
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
                try handle.synchronize()   // fsync:落盤耐久(契約 B)
                expectedFingerprint = currentFingerprint()
            }
        } else {
            // stat 失敗但非「確認缺檔」(權限/IO/斷 symlink…)→ fail-closed:不覆寫、不冒險,拋錯讓上層(writeError)對帳。
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 丟棄保留期以外的舊事件並重寫帳本檔。交易式(契約 B):先落盤成功才提交記憶體;
    /// 失敗則舊記憶體與舊檔案皆保留(acceptance #5)。poisoned 時不動。
    public func compact(retentionDays: Int, now: Date = Date()) {
        guard loadError == nil else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        // O(1) 短路:最舊事件仍在保留期內 → 無事可壓縮(原本每輪 refresh 都 filter
        // 整個 9 萬+ 陣列,只為發現「沒東西可丟」)。
        if let oldest = events.first, oldest.timestamp >= cutoff { return }
        let kept = events.filter { $0.timestamp >= cutoff }
        guard kept.count != events.count else { return }
        guard let fileURL else {   // 記憶體模式:直接套用
            events = kept
            ids = Set(kept.map(\.id))
            rebuildInternPool()    // 事件被移除 → 池重建才有界(xcheck r1)
            revision &+= 1
            return
        }
        do {
            _ = try Self.writeAllAtomic(kept, to: fileURL)   // 先落盤(可能 throw)
            events = kept                                     // 成功才提交記憶體
            ids = Set(kept.map(\.id))
            rebuildInternPool()                               // 事件被移除 → 池重建才有界(xcheck r1)
            expectedFingerprint = currentFingerprint()
            revision &+= 1
        } catch {
            // 落盤失敗 → 舊記憶體與舊檔案皆保留
        }
    }

    /// 全量原子重寫帳本檔:整份 encode(任一失敗即 throw,不做半份重寫)後 `.atomic`(temp→rename)
    /// 替換,回傳新檔位元組數。供 compact 與(step 6)切片取代共用。
    static func writeAllAtomic(_ events: [UsageEvent], to url: URL) throws -> Int64 {
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = AtomicJSON.encoder()
        var blob = Data()
        for e in events {
            blob.append(try encoder.encode(e))
            blob.append(0x0A)
        }
        try blob.write(to: url, options: .atomic)
        return Int64(blob.count)
    }

    /// 交易式切片取代(契約 F / codex C11):新帳本 = {其他 provider 事件} ∪ {此 provider 重掃事件},
    /// keep-first 去重、依時間排序,先原子落盤成功才提交記憶體;失敗即 throw(記憶體與檔案皆不變)。
    /// poisoned 時拒絕。取代「先 clearProviders 再 append」——後者因去重會變成無操作(codex M2/C11)。
    @discardableResult
    public func replaceProviderSlice(_ providerId: String, with freshEvents: [UsageEvent]) throws -> Int {
        if let loadError { throw loadError }
        let kept = events.filter { $0.providerId != providerId }
        var merged = kept
        var seen = Set(kept.map(\.id))
        var accepted = 0   // 實際採納(去重後)數;供 coordinator 正確計數(codex NIT)
        // 不預先 intern(xcheck r2):落盤失敗時 throw、記憶體不變,預駐留的字串卻會殘留
        // 池中(反覆失敗的 reindex 會無事件背書地養大池)。提交後 rebuildInternPool()
        // 統一駐留(append 的「成功才駐留」同一原則)。
        for e in freshEvents where seen.insert(e.id).inserted { merged.append(e); accepted += 1 }
        merged.sort { $0.timestamp < $1.timestamp }
        guard let fileURL else {   // 記憶體模式
            events = merged
            ids = seen
            rebuildInternPool()    // 舊切片事件被移除 → 池重建才有界(xcheck r1)
            revision &+= 1
            return accepted
        }
        _ = try Self.writeAllAtomic(merged, to: fileURL)   // 先落盤;throw → 記憶體不變(舊切片保留)
        events = merged
        ids = seen
        rebuildInternPool()                                // 舊切片事件被移除 → 池重建才有界(xcheck r1)
        expectedFingerprint = currentFingerprint()
        revision &+= 1
        return accepted
    }

    /// 清空(全量重建索引前呼叫)。
    public func reset() {
        events = []
        ids = []
        internPool = [:]
        expectedFingerprint = nil
        revision &+= 1
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - 查詢

    /// 依時間排序的 events 中,timestamp ∈ [interval.start, interval.end) 的索引範圍(雙端二分)。
    private func indexRange(of interval: DateInterval) -> Range<Int> {
        func lowerBound(_ t: Date) -> Int {
            var lo = 0, hi = events.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if events[mid].timestamp < t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        let lo = lowerBound(interval.start)
        let hi = lowerBound(interval.end)
        return lo..<max(lo, hi)
    }

    /// 免複製走訪:大範圍(如 All time 的 9 萬+ 筆)不再為每個聚合 materialize 子陣列
    /// (2026-08-08 量測:重複的全陣列複製是 92 天查詢 12.4s / RSS 高水位的主因之一)。
    /// 走訪的是「進入時的快照」:`snapshot` 是 COW 借用(無 mutation 時零複製),
    /// 若 body 重入而變異 ledger(append/reset/…),self.events 換新緩衝、快照仍完整
    /// 有效 —— 不會越界 trap,也不會走訪到混合狀態(xcheck r1)。
    public func forEachEvent(in interval: DateInterval, providerId: String? = nil,
                             _ body: (UsageEvent) -> Void) {
        let snapshot = events
        for i in indexRange(of: interval) {
            let e = snapshot[i]
            if providerId == nil || e.providerId == providerId { body(e) }
        }
    }

    public func events(in interval: DateInterval, providerId: String? = nil) -> [UsageEvent] {
        let range = indexRange(of: interval)
        if providerId == nil { return Array(events[range]) }
        return events[range].filter { $0.providerId == providerId }
    }

    public func totals(in interval: DateInterval, providerId: String? = nil) -> TokenBreakdown {
        var acc = TokenBreakdown.zero
        forEachEvent(in: interval, providerId: providerId) { acc = acc + $0.tokens }
        return acc
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
        var buckets: [Date: Acc] = [:]
        forEachEvent(in: interval) { e in
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: e.timestamp)
            guard let hourStart = calendar.date(from: comps) else { return }
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

    /// 依行事曆本地日聚合事件(hourlyBuckets 的日粒度版本);只回傳有用量的日、依日升序。
    /// 熱圖需要含零用量的日,由呼叫端在日期範圍上逐日查表補零。
    public func dailyBuckets(in interval: DateInterval, calendar: Calendar = .current,
                             pricing: PricingRegistry? = nil) -> [DayBucket] {
        struct Acc {
            var tokens = 0
            var byProvider: [String: Int] = [:]
            var byProject: [String: Int] = [:]
            var byModel: [String: Int] = [:]
            var cost = CostResult.zero
        }
        var buckets: [Date: Acc] = [:]
        forEachEvent(in: interval) { e in
            let day = calendar.startOfDay(for: e.timestamp)
            var acc = buckets[day] ?? Acc()
            acc.tokens += e.tokens.total
            acc.byProvider[e.providerId, default: 0] += e.tokens.total
            acc.byProject[e.projectName ?? "(unknown)", default: 0] += e.tokens.total
            acc.byModel[e.modelId ?? "unknown", default: 0] += e.tokens.total
            if let pricing { acc.cost = acc.cost + pricing.cost(of: e) }   // 逐筆累加 ≡ cost(of: [events])
            buckets[day] = acc
        }
        return buckets.keys.sorted().map { day in
            let acc = buckets[day]!
            return DayBucket(day: day, tokens: acc.tokens, byProvider: acc.byProvider,
                             topProject: acc.byProject.max { $0.value < $1.value }?.key,
                             topModel: acc.byModel.max { $0.value < $1.value }?.key,
                             cost: acc.cost)
        }
    }

    /// 使用連續天數(current + longest)。以「有事件的本地日」集合計算;
    /// 相鄰判斷用日差(對 DST 安全),current 允許今天尚未使用時以昨天結尾。
    public func usageStreak(now: Date = Date(), calendar: Calendar = .current) -> UsageStreak {
        var days = Set<Date>()
        for e in events { days.insert(calendar.startOfDay(for: e.timestamp)) }   // 免中間陣列
        guard !days.isEmpty else { return UsageStreak(current: 0, longest: 0) }

        let sorted = days.sorted()
        var longest = 1, run = 1
        if sorted.count > 1 {
            for i in 1..<sorted.count {
                if calendar.dateComponents([.day], from: sorted[i - 1], to: sorted[i]).day == 1 {
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 1
                }
            }
        }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var cursor: Date
        if days.contains(today) { cursor = today }
        else if days.contains(yesterday) { cursor = yesterday }
        else { return UsageStreak(current: 0, longest: longest) }

        var current = 0
        while days.contains(cursor) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return UsageStreak(current: current, longest: longest)
    }

    public func projectSummaries(in interval: DateInterval, pricing: PricingRegistry) -> [ProjectSummary] {
        // 單趟累加(取代「分組保留整組事件再各自 reduce」):All time 下不再把 9 萬+ 筆
        // 複製進 per-project 陣列;成本逐筆累加 ≡ cost(of: [events])(定義即 reduce)。
        struct Acc {
            var tokens = TokenBreakdown.zero
            var cost = CostResult.zero
            var modelTokens: [String: Int] = [:]
            var providers: Set<String> = []
            var lastActive: Date?
            var lastProjectName: String??   // 語意同舊 group.last?.projectName(最後一筆,可為 nil)
        }
        var periodTotal = 0
        var groups: [String: Acc] = [:]
        forEachEvent(in: interval) { e in
            periodTotal += e.tokens.total
            var acc = groups[e.projectId ?? "(unknown project)"] ?? Acc()
            acc.tokens = acc.tokens + e.tokens
            acc.cost = acc.cost + pricing.cost(of: e)
            acc.modelTokens[e.modelId ?? "unknown", default: 0] += e.tokens.total
            acc.providers.insert(e.providerId)
            acc.lastActive = max(acc.lastActive ?? .distantPast, e.timestamp)
            acc.lastProjectName = .some(e.projectName)
            groups[e.projectId ?? "(unknown project)"] = acc
        }
        let denom = max(1, periodTotal)
        return groups.map { projectId, acc in
            ProjectSummary(
                projectId: projectId,
                // 隱私:顯示名一律 basename 化(缺名或被塞入路徑時絕不外洩完整 cwd);
                // projectId 仍保留完整值供穩定分組。UI 與 HTML 皆消費此已淨化的 projectName。
                projectName: PrivacyRedaction.displayProjectName(projectName: acc.lastProjectName ?? nil, projectId: projectId),
                tokens: acc.tokens,
                cost: acc.cost,
                providers: acc.providers.sorted(),
                topModel: acc.modelTokens.max { $0.value < $1.value }?.key,
                lastActive: acc.lastActive,
                shareOfPeriod: Double(acc.tokens.total) / Double(denom)
            )
        }
        .sorted { $0.tokens.total > $1.tokens.total }
    }

    public func modelSummaries(in interval: DateInterval, pricing: PricingRegistry) -> [ModelUsageSummary] {
        struct Acc {
            var providerId: String
            var modelId: String
            var tokens = TokenBreakdown.zero
            var cost = CostResult.zero
        }
        var groups: [String: Acc] = [:]
        forEachEvent(in: interval) { e in
            let key = e.providerId + "/" + (e.modelId ?? "unknown")
            var acc = groups[key] ?? Acc(providerId: e.providerId, modelId: e.modelId ?? "unknown")
            acc.tokens = acc.tokens + e.tokens
            acc.cost = acc.cost + pricing.cost(of: e)
            groups[key] = acc
        }
        return groups.values.map {
            ModelUsageSummary(providerId: $0.providerId, modelId: $0.modelId, tokens: $0.tokens, cost: $0.cost)
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
