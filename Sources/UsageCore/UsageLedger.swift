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

/// #64 P5:durability syscall seam(internal、per-instance、不可變)。tests 以 `@testable` 經
/// internal init 注入失敗排程;production 只走 `.production`(public init 不暴露此參數,
/// 無全域可變狀態 → 平行測試不互染,production 代碼無法換掉 barrier;owner DP-3)。
/// 三槽 = P1/P2 barrier 的三個 syscalls;回傳值語義同 POSIX(0 成功、-1 失敗)。
struct DurabilityOps {
    var syncFile: (Int32) -> Int32
    var statFile: (Int32, UnsafeMutablePointer<stat>) -> Int32
    var renameFile: (String, String) -> Int32
    var syncDirectory: (String) -> Int32

    /// Darwin production 實作。syncFile = F_FULLFSYNC(application 所選的最強平台持久化屏障;
    /// Apple 文件亦標明其為 best-effort——本檔一律以「durable commit = 此屏障成功」為 commit
    /// boundary,不宣稱絕對斷電保證)。任何失敗(含 ENOTSUP/EINVAL)= mutation failed,
    /// 絕不降級 fsync、絕不 transparent downgrade(owner DP-1 hard-fail)。
    /// syncDirectory = 開啟目錄 fd + fsync(rename metadata 層級;owner 裁定 dir 不要求 FULLFSYNC)。
    static let production = DurabilityOps(
        syncFile: { fd in fcntl(fd, F_FULLFSYNC) },
        statFile: { fd, st in fstat(fd, st) },
        renameFile: { src, dst in Darwin.rename(src, dst) },
        syncDirectory: { path in
            let dirfd = open(path, O_RDONLY)
            guard dirfd >= 0 else { return -1 }
            let r = fsync(dirfd)
            close(dirfd)
            return r
        }
    )
}

/// 本機用量帳本:彙整所有 provider 的正規化事件,為三個頁面與報告提供查詢。
/// 帳本是「provider 全域」的聚合,而非單一終端面板的即時值(規格核心要求)。
public final class UsageLedger {
    public private(set) var events: [UsageEvent] = []
    private var ids: Set<String> = []
    /// #48 MF3 clearing twin (invariant-B):decoder 拒收但仍是完整 JSON、能可信抽出 stable id 的
    /// raw-only 行,其 id 保留為 collision-reserved——append/replace 不得重用(否則提交無法
    /// canonicalize 的重複)。於 load/reload/compact/replace/reset 隨檔案內容一致重建;append 熱路徑
    /// 只查此集合(不重掃檔),其可信度由 MF2 fingerprint preflight 在未漂移期間保證。
    private var reservedRawIDs: Set<String> = []
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

    /// #64 P5:本 instance 的 durability syscalls(不可變;production 恆為 `.production`)。
    private let durabilityOps: DurabilityOps

    public convenience init(fileURL: URL?) {
        self.init(fileURL: fileURL, durabilityOps: .production)
    }

    /// internal(tests-only via `@testable`):注入 barrier 失敗排程用;見 DurabilityOps 註解。
    init(fileURL: URL?, durabilityOps: DurabilityOps) {
        self.fileURL = fileURL
        self.durabilityOps = durabilityOps
        load()
    }

    /// 讀入帳本。三態:不存在(空帳本合法)、存在但 I/O 失敗(unreadable→poisoned)、
    /// 內容已收尾/中段行損壞(malformed→poisoned)。尾端未收尾片段(部分 append)可容忍。
    private func load() {
        loadError = nil
        needsReload = false
        events = []
        ids = []
        reservedRawIDs = []
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
                // #48 MF3 clearing twin:decoder 拒收但仍是完整 JSON 且能抽出 stable id 的行 ⇒ 保留
                // 為 collision-reserved(斷尾片段抽不出 id ⇒ 自然不納入,維持既有 torn-tail 容忍)。
                if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                   let rid = obj["id"] as? String { reservedRawIDs.insert(rid) }
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
        let priorReserved = reservedRawIDs
        load()
        if loadError != nil {
            // 非破壞式:讀取失敗不得清掉既有記憶體(否則後續寫入會覆寫好資料)。
            // 保留舊狀態;coordinator 見 loadError 會中止本輪寫入(#44 契約 A)。
            events = priorEvents
            ids = priorIds
            reservedRawIDs = priorReserved
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
        // #48 clearing-r1 (luna + sol MUST-FIX):漂移檢查必須在 dedup **之前**且涵蓋所有 persistAppend
        // 分支。否則:(sol) 撞陳舊 ids/reservedRawIDs 的 event 會在下方 dedup 就 SKIP、於 `guard
        // !inserted.isEmpty` 提早 return,persistAppend 的漂移檢查根本不跑 → 有效 event 靜默略過
        //(writeError==nil)+ coordinator 前進 watermark = 遺失(A);(luna) persistAppend 的
        // missing/zero-length 分支會盲寫 [new] 覆蓋他方 truncate/unlink 後的檔(記憶體/磁碟分歧、遮蔽漂移)。
        // #48 clearing-r2 (luna-max defensive-NIT):鏡射 rewritePreflightOK/casPreflight 的**完整**
        // tri-state——nil 指紋僅在「可證明缺檔」時才等同 expected nil;不可 stat 的既有檔不可信 ⇒
        // refuse(否則 nil==nil 誤判 no-drift,讓撞陳舊 id 的 skip 繞過 fail-closed)。此格在 open⟹stat
        // 下不可達(read 成功 ⟹ stat 必成功,故 load 不會留 expectedFingerprint=nil+非空帳本),純防禦式
        // 一致性,使兩個 append preflight 與既有 rewrite/cas preflight 共用同一 nil 語意。
        // fail-closed:設 needsReload + writeError、不寫入,下輪 reloadIfChanged 對帳(殘餘寫時微窗同 #64)。
        if let fileURL {
            let cur = currentFingerprint()
            if needsReload
               || (cur == nil && !AtomicJSON.pathIsGenuinelyMissing(fileURL.path))
               || cur != expectedFingerprint {
                needsReload = true
                writeError = CocoaError(.fileWriteUnknown)
                return 0
            }
        }
        var inserted: [UsageEvent] = []
        var batchIds: Set<String> = []
        // #48 MF3 clearing twin:knownIDs = ids ∪ reservedRawIDs;不得重用 raw-only 保留 id(否則
        // 提交無法 canonicalize 的重複)。與既有 keep-first 一致:碰撞即略過(不新增),不拋錯。
        for e in newEvents where !ids.contains(e.id) && !reservedRawIDs.contains(e.id) && batchIds.insert(e.id).inserted {
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
            expectedFingerprint = try atomicWriteCapturingFingerprint(blob, to: fileURL)   // 確認缺檔 → 原子建立
        } else if let fp {
            if fp.size == 0 {
                expectedFingerprint = try atomicWriteCapturingFingerprint(blob, to: fileURL)   // stat 成功且確認空檔 → 原子建立
            } else {
                // #48 gate-r5 sol MF2:續尾寫入前必須確認磁碟指紋未漂移(與 casPreflight/
                // rewritePreflightOK 同級的 tri-state)。否則 seekToEnd 之前落地的他方寫入會被
                // 吸收進 end,r4 size 檢查亦無法察覺 → 可提交重複 id(無法 canonicalize)的帳本。
                // 寫入當下重採指紋比對(縮小 race window);漂移 ⇒ fail-closed:設 needsReload、拋錯
                // 讓上層(writeError)對帳,不寫入。(重採→開檔→seek 的殘餘微窗同 stat→rename,#64。)
                guard !needsReload, currentFingerprint() == expectedFingerprint else {
                    needsReload = true
                    throw CocoaError(.fileWriteUnknown)
                }
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
                // #64 P2:F_FULLFSYNC(契約 B durable ack;plain fsync 只到 drive cache——斷電下
                // drive 亂序寫回可讓 un-synced watermark 落盤而 append bytes 消失 = watermark leads,
                // 違反 P3 invariant)。任何失敗(含 ENOTSUP)= append failed,不降級(DP-1)。
                // bytes 已出 → outcome unknown 非 rollback:不 ack、不提交記憶體、needsReload
                // 令下輪 reloadIfChanged 對帳({完整吸收 | torn-tail 容忍} 皆合法)。
                guard durabilityOps.syncFile(handle.fileDescriptor) == 0 else {
                    let err = errno
                    needsReload = true
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                }
                // sol r3 MF2:指紋必須描述**我們自己的寫入**——以 fstat(fd) 於寫入當下捕捉,
                // 不得事後 re-stat 路徑(write→stat 間他方落盤會把指紋毒化成「已含他方事件」,
                // 記憶體卻沒有 → reload 不觸發 → CAS 過檢 → 之後的 replace 刪掉他方事件)。
                // sol r4 MF5:fsync→fstat 之間他方 append 仍可混入——以「尺寸必須恰為 end+本批
                // bytes」驗證捕捉;不符 ⇒ 指紋不可信,清空並強制下輪對帳(fail closed,不採他方狀態)。
                let captured = Self.fingerprint(ofFD: handle.fileDescriptor)
                if let captured, captured.size == Int64(end) + Int64(blob.count) {
                    expectedFingerprint = captured
                } else {
                    expectedFingerprint = nil
                    needsReload = true
                }
            }
        } else {
            // stat 失敗但非「確認缺檔」(權限/IO/斷 symlink…)→ fail-closed:不覆寫、不冒險,拋錯讓上層(writeError)對帳。
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// compact 結果(#48 gate-r1 luna L2:contract step 4「compact 失敗則不得比較或 replacement」
    /// 需要呼叫端可見的失敗訊號;沿用既有安全行為,只補回報)。
    public enum CompactResult: Equatable, Sendable {
        case noop            // 無事可丟(未重寫;raw bytes 原封不動)
        case applied         // 已重寫並提交
        case skippedSuspectRaw   // 呼叫端判定 raw 層可疑而跳過(luna L1:不得在 gate 前消滅 raw 證據)
        case failed          // 落盤失敗(舊記憶體與舊檔案皆保留)
        case poisoned        // loadError,未動
    }

    /// 丟棄保留期以外的舊事件並重寫帳本檔。交易式(契約 B):先落盤成功才提交記憶體;
    /// 失敗則舊記憶體與舊檔案皆保留(acceptance #5)。poisoned 時不動。
    @discardableResult
    public func compact(retentionDays: Int, now: Date = Date()) -> CompactResult {
        guard loadError == nil else { return .poisoned }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        // O(1) 短路:最舊事件仍在保留期內 → 無事可壓縮(原本每輪 refresh 都 filter
        // 整個 9 萬+ 陣列,只為發現「沒東西可丟」)。
        if let oldest = events.first, oldest.timestamp >= cutoff { return .noop }
        let kept = events.filter { $0.timestamp >= cutoff }
        guard kept.count != events.count else { return .noop }
        guard let fileURL else {   // 記憶體模式:直接套用
            events = kept
            ids = Set(kept.map(\.id))
            reservedRawIDs = []   // #48 MF3 clearing twin:typed 重寫丟棄所有 raw-only 行
            rebuildInternPool()    // 事件被移除 → 池重建才有界(xcheck r1)
            revision &+= 1
            return .applied
        }
        // sol r3 MF1:compact 是「整檔破壞式重寫」,與 replace 同級——未對帳快照(unstable load /
        // append 半寫)或指紋不可驗/不符(穩定 reload 後他方落盤、或不可 stat)時,typed 記憶體
        // 不可信,一律拒絕重寫。compact 在 coordinator 中先於 gate 執行,缺 guard 即 gate 前 history-loss。
        guard rewritePreflightOK() else { return .failed }
        do {
            let fp = try writeAllAtomic(kept, to: fileURL)   // 先落盤(可能 throw);寫入當下捕捉指紋
            events = kept                                     // 成功才提交記憶體
            ids = Set(kept.map(\.id))
            reservedRawIDs = []   // #48 MF3 clearing twin:typed 重寫丟棄所有 raw-only 行
            rebuildInternPool()                               // 事件被移除 → 池重建才有界(xcheck r1)
            expectedFingerprint = fp   // 寫入當下捕捉(sol r3 MF2),取代事後 re-stat
            revision &+= 1
            return .applied
        } catch {
            // 落盤失敗 → 舊記憶體與舊檔案皆保留
            return .failed
        }
    }

    /// raw 保存式 compact(sol r3 MF3):在**已通過整檔 canonicalization** 的 raw bytes 上做行級手術——
    /// 只丟「可解析且確定過期」的行,其餘**逐位元組保留**(不經 typed decode→encode round-trip,
    /// 不改寫任何 provider 的 raw 表示;timestamp 無法解析 ⇒ fail-closed 保留)。
    /// caller(coordinator precheck)保證 raw 即目前磁碟內容且 canonicalization 成功。
    @discardableResult
    public func compactRawPreserving(retentionDays: Int, now: Date, raw: Data) -> CompactResult {
        guard loadError == nil else { return .poisoned }
        guard let fileURL else { return compact(retentionDays: retentionDays, now: now) }   // 記憶體模式無 raw 可保
        guard rewritePreflightOK() else { return .failed }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        var newData = Data()
        var dropped = 0
        for line in raw.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if line.isEmpty { continue }   // 尾端 trailing-newline 空段(canonicalization 已拒內部空白行)
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                return .failed   // 防禦性:caller 已 canonicalize 成功,解析失敗即拒絕重寫(不冒險)
            }
            // sol r4 MF2:丟棄判定必須用 strict 解析(整串消耗+明確時區)——lenient 解析接受
            // 垃圾後綴("…T00:00:00garbage"),會把 canonical 域視為 opaque 字串的行誤判為過期而刪除。
            if let ts = obj["timestamp"] as? String, let d = ISO8601.parse(ts, strict: true), d < cutoff {
                dropped += 1
                continue   // 唯一允許丟棄的行:timestamp 可解析且確定過期
            }
            newData.append(contentsOf: line)
            newData.append(0x0A)
        }
        guard dropped > 0 else { return .noop }
        // #48 clearing-final sol#1:先 re-decode newData 再決定是否寫入——若丟棄後只剩 canonical 但
        // decoder-拒收的 raw-only 行(load() 會判該檔 poison),**絕不提交該狀態**:return .failed、
        // 原檔逐位元組保留(否則 retention compaction 會把健康帳本變 poisoned)。typed 視角以寫前的
        // newData 重新解碼(不用 cutoff 近似,保證與 fresh load 一致;grok r4)。
        var reloaded: [UsageEvent] = []
        var reloadedIDs = Set<String>()
        var reloadedReserved = Set<String>()
        let decoder = AtomicJSON.decoder()
        for line in newData.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let e = try? decoder.decode(UsageEvent.self, from: Data(line)) {
                if reloadedIDs.insert(e.id).inserted { reloaded.append(e) }
            } else if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let rid = obj["id"] as? String {
                reloadedReserved.insert(rid)   // #48 MF3 clearing twin:保留的 raw-only 行 id ⇒ collision-reserved
            }
        }
        if reloaded.isEmpty && !newData.isEmpty {
            return .failed   // 全 raw-only ⇒ 不寫入、保留原檔(不提交 load()-poison 狀態)
        }
        do {
            let fp = try atomicWriteCapturingFingerprint(newData, to: fileURL)   // 通過 poison 檢查才寫
            events = reloaded.sorted { $0.timestamp < $1.timestamp }
            ids = reloadedIDs
            reservedRawIDs = reloadedReserved   // #48 MF3 clearing twin:保留的 raw-only id 隨檔案重建
            rebuildInternPool()   // 事件被移除 → 池重建才有界(xcheck r1;與 compact 同原則)
            expectedFingerprint = fp
            revision &+= 1        // 事件集已變 → 推進世代(聚合快取失效鍵)
            return .applied
        } catch {
            return .failed
        }
    }

    /// 破壞式整檔重寫的共同前置檢查(compact 兩型共用;luna/sol r4):
    /// needsReload ⇒ 拒絕;nil 指紋只在「可證明缺檔」時可與 expected nil 相等(不可 stat ⇒ 拒絕,
    /// 與 casPreflight/persistAppend 的 tri-state 一致);其餘要求指紋與載入時完全一致,
    /// 不符即設 needsReload 強制下輪對帳。
    private func rewritePreflightOK() -> Bool {
        guard !needsReload else { return false }
        let cur = currentFingerprint()
        if cur == nil, let fileURL, !AtomicJSON.pathIsGenuinelyMissing(fileURL.path) {
            needsReload = true
            return false
        }
        guard cur == expectedFingerprint else {
            needsReload = true   // 磁碟已前進:強制下輪 reloadIfChanged 對帳
            return false
        }
        return true
    }

    /// #48 gate-r1 luna L1:compact「將會動作」的廉價預判(typed 視角)。true ⇒ 呼叫端應先做
    /// raw 完整性 precheck——typed 重寫會消滅 malformed/duplicate/unknown-key raw 行,
    /// 不得在 monotonic gate 之前發生於可疑檔案上。
    public func compactWouldAct(retentionDays: Int, now: Date = Date()) -> Bool {
        guard loadError == nil else { return false }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        return events.contains { $0.timestamp < cutoff }
    }

    /// #48 CAS gate:帳本檔目前修訂(以 (dev,ino,size,mtime) 指紋為代理;nil = 檔缺/不可 stat)。
    /// 供「重讀 baseline → 比較 → 同一 revision 邊界內 replace」的 compare-and-swap 判定。
    public struct LedgerRevision: Equatable, Sendable {
        let fp: FileFingerprint?
    }
    public func currentRevision() -> LedgerRevision { LedgerRevision(fp: currentFingerprint()) }

    /// #48 gate-r1 luna L3(b) 修正:CAS 的 expected revision 必須取「typed 記憶體實際載入時」
    /// 的指紋(expectedFingerprint),而非事後 re-stat——否則 reload 與 stat 之間落盤的他人
    /// 寫入會讓 revision 捕捉到新指紋、記憶體卻停在舊態,CAS 過檢後以 stale 記憶體重寫、
    /// 丟失新事件。以此值作 expected ⇒ 「記憶體 == revision」成為不變量。
    public func loadedRevision() -> LedgerRevision { LedgerRevision(fp: expectedFingerprint) }

    /// #48 gate-r2 luna L3b-殘餘:load() 三次不穩定重試後會把 stale data 標上較新 fpAfter 並設
    /// needsReload(下輪對帳)——該狀態下 revision 看似最新、記憶體卻可能缺最新事件。
    /// destructive gate 必須據此 fail closed;CAS overload 亦雙層拒絕。
    public var hasUnreconciledSnapshot: Bool { needsReload }

    public enum CASError: Error, Equatable { case revisionChanged }

    /// CAS 版切片取代(#48 pivot §3):寫入前 re-stat;revision 與 compare 時不符 ⇒ throw
    /// `.revisionChanged`,呼叫端必須放棄並 preserve——不得覆寫比較後才落盤的較新帳本。
    /// (剩餘 stat→rename 微窗屬 #64 durability/commit-semantics 範圍,此處不擴。)
    public func replaceProviderSlice(_ providerId: String, with freshEvents: [UsageEvent],
                                     expectedRevision: LedgerRevision) throws -> Int {
        try casPreflight(expectedRevision)
        return try replaceProviderSlice(providerId, with: freshEvents)
    }

    /// CAS 共同前置檢查(順序固定):
    /// 1. gate-r2 luna L3b-殘餘:未對帳快照(unstable load / append 半寫)⇒ 記憶體不可信,一律拒絕。
    /// 2. luna r3 MF1(nil-split):「不可 stat」≠「確認缺檔」——nil 指紋只在**可證明缺檔**
    ///    (合法空 baseline 初始化)時可與 expected nil 相等;其餘 stat 失敗一律 fail closed
    ///    (與 persistAppend 的 tri-state 原則一致,#44)。
    /// 3. 指紋必須與 compare 時的 loadedRevision 完全一致。
    private func casPreflight(_ expectedRevision: LedgerRevision) throws {
        guard !needsReload else { throw CASError.revisionChanged }
        let cur = currentFingerprint()
        if cur == nil, let fileURL, !AtomicJSON.pathIsGenuinelyMissing(fileURL.path) {
            throw CASError.revisionChanged
        }
        guard cur == expectedRevision.fp else { throw CASError.revisionChanged }
    }

    /// raw 保存式 CAS 切片取代(sol r3 MF3):非目標 provider 的行從 `baselineRaw` **逐位元組保留**,
    /// 只有目標 provider 的切片以 production encoder 重新編碼——typed decode→encode round-trip
    /// 會改寫(小數秒 timestamp)或丟失(decoder 拒收但 canonicalizer 接受的行)其他 provider 的
    /// canonical 表示,違反 per-provider isolation(無需任何 race)。caller(gate)保證:
    /// baselineRaw 於 drift-guard 驗證後讀取、整檔 canonicalization 成功、revision 邊界由 CAS 把關。
    public func replaceProviderSlice(_ providerId: String, with freshEvents: [UsageEvent],
                                     expectedRevision: LedgerRevision, preservingRaw baselineRaw: Data) throws -> Int {
        try casPreflight(expectedRevision)
        if let loadError { throw loadError }
        guard let fileURL else { return try replaceProviderSlice(providerId, with: freshEvents) }   // 記憶體模式無 raw 可保
        var newData = Data()
        var preservedForeignIDs = Set<String>()
        for line in baselineRaw.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if line.isEmpty { continue }   // 尾端 trailing-newline 空段
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let pid = obj["providerId"] as? String, let lineID = obj["id"] as? String else {
                throw CocoaError(.fileWriteUnknown)   // 防禦性:gate 已 canonicalize 成功;解析失敗即拒絕(不重寫)
            }
            if pid != providerId {
                newData.append(contentsOf: line)
                newData.append(0x0A)
                preservedForeignIDs.insert(lineID)
            }
        }
        let encoder = AtomicJSON.encoder()
        let keptTyped = events.filter { $0.providerId != providerId }
        var seen = Set(keptTyped.map(\.id))
        var freshAccepted: [UsageEvent] = []
        for e in freshEvents.sorted(by: { $0.timestamp < $1.timestamp }) where seen.insert(e.id).inserted {
            // sol r4 MF6:candidate id 與「僅存在於 raw(decoder 拒收)的外來行」撞號時,寫出的檔案
            // 會含重複 id、立即無法 canonicalize——絕不提交已知不可驗證的帳本,整筆拒絕(preserve)。
            guard !preservedForeignIDs.contains(e.id) else { throw CocoaError(.fileWriteUnknown) }
            newData.append(try encoder.encode(e))
            newData.append(0x0A)
            freshAccepted.append(e)
        }
        let fp = try atomicWriteCapturingFingerprint(newData, to: fileURL)   // 先落盤;throw → 記憶體不變
        var merged = keptTyped + freshAccepted
        merged.sort { $0.timestamp < $1.timestamp }
        events = merged
        ids = seen
        reservedRawIDs = preservedForeignIDs.subtracting(seen)   // #48 MF3 clearing twin:保留的 foreign raw-only id 仍 collision-reserved
        rebuildInternPool()   // 舊切片事件被移除 → 池重建才有界(xcheck r1;與非-CAS 版同原則)
        expectedFingerprint = fp
        revision &+= 1        // 事件集已變 → 推進世代(聚合快取失效鍵)
        return freshAccepted.count
    }

    /// 全量原子重寫帳本檔:整份 encode(任一失敗即 throw,不做半份重寫)後走 #64 P1 durable
    /// barrier(temp→FULLFSYNC→rename→dir-fsync),回傳寫入當下捕捉的指紋。供 compact 與切片取代共用。
    func writeAllAtomic(_ events: [UsageEvent], to url: URL) throws -> FileFingerprint {
        let encoder = AtomicJSON.encoder()
        var blob = Data()
        for e in events {
            blob.append(try encoder.encode(e))
            blob.append(0x0A)
        }
        return try atomicWriteCapturingFingerprint(blob, to: url)
    }

    /// #64 P1 durable atomic rewrite(owner architecture verdict):
    ///   temp write(write-all)→ F_FULLFSYNC(temp fd)→ fstat 捕捉指紋 → rename → fsync(parent dir)
    /// 全部成功才回傳(= durable commit ack)。durable commit 的定義是「application 所選最強平台
    /// 持久化屏障成功」(F_FULLFSYNC file data + dir fsync rename metadata)——Apple 文件標明
    /// F_FULLFSYNC 亦為 best-effort,故不宣稱絕對斷電保證,只以此為 commit boundary。
    /// Success rule:任何 barrier 失敗 = mutation failed、不 ack;bytes 可能已改變檔案系統之後的
    /// 失敗(C7c dir-sync)= outcome-unknown + fail-closed(設 needsReload 令下輪對帳),
    /// 絕不假設 rollback、絕不動已 rename 的 destination。
    /// 指紋於 rename 前以 fstat(temp fd) 捕捉(sol r3 MF2 血統:rename 不改 dev/ino/size/mtime;
    /// 等價性由 testFingerprintEquivalenceAcrossRename 以測試鎖定,不只靠此推理)。
    func atomicWriteCapturingFingerprint(_ blob: Data, to url: URL) throws -> FileFingerprint {
        let parent = url.deletingLastPathComponent()
        try AppPaths.ensureDirectory(parent)
        // DP-2:temp 與 destination 同 parent(rename 同-filesystem 原子性前提)、O_EXCL unique。
        let tempURL = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // 6b-1 write-all:short write 續寫、EINTR 重試;write()==0 或其他 errno = pre-rename failure。
        var wrote = 0
        let total = blob.count
        var writeErrno: Int32 = 0
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while wrote < total {
                let n = write(fd, raw.baseAddress!.advanced(by: wrote), total - wrote)
                if n > 0 { wrote += n; continue }
                if n < 0 && errno == EINTR { continue }
                writeErrno = (n < 0) ? errno : EIO   // n==0:無進展,視為 I/O 失敗
                return
            }
        }
        guard wrote == total else {
            close(fd); unlink(tempURL.path)   // C7-pre:destination 未動,temp best-effort 清除
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(writeErrno))
        }
        // C7a:F_FULLFSYNC 任何失敗(含 ENOTSUP/EINVAL)= mutation failed;絕不降級 fsync、
        // 絕不 transparent downgrade(owner DP-1 hard fail)。destination 仍 old。
        guard durabilityOps.syncFile(fd) == 0 else {
            let err = errno
            close(fd); unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        // attempt-002 owner-accepted MUST-FIX:verify(fstat)是 P1 success sequence 的一步,
        // 失敗 = pre-rename failure(C7a 同腿)——destination 未動、可零歧義 abort;絕無理由在
        // 已知拿不到預期指紋時仍執行 destructive rename。(對照 P2 tail 的 post-commit fstat:
        // 那是 #48 sol r4 MF5 的 reconciliation 層,owner 裁定維持,兩者語義不同勿混。)
        var st = stat()
        guard durabilityOps.statFile(fd, &st) == 0 else {
            let err = errno
            close(fd); unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err == 0 ? EIO : err))
        }
        let fp = FileFingerprint(dev: Int64(st.st_dev), ino: UInt64(st.st_ino), size: Int64(st.st_size),
                                 mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec))
        close(fd)
        // C7b:rename 失敗 → destination 仍 old;temp best-effort 清除。
        guard durabilityOps.renameFile(tempURL.path, url.path) == 0 else {
            let err = errno
            unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        // C7c:rename 已可見 → commit outcome UNKNOWN。不得 unlink(可能毀掉已 commit 的 new)、
        // 不得回滾、不得 ack;設 needsReload 讓下輪 reloadIfChanged 對帳磁碟實況({old|new} 皆 valid)。
        guard durabilityOps.syncDirectory(parent.path) == 0 else {
            let err = errno
            needsReload = true
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        return fp
    }

    /// fstat 版指紋(append 路徑:對已開啟的 fd 取,描述我們自己的寫入)。
    static func fingerprint(ofFD fd: Int32) -> FileFingerprint? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return FileFingerprint(dev: Int64(st.st_dev), ino: UInt64(st.st_ino), size: Int64(st.st_size),
                               mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNsec: Int64(st.st_mtimespec.tv_nsec))
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
            reservedRawIDs = []   // #48 MF3 clearing twin:非-preservingRaw typed 重寫丟棄 raw-only 行
            rebuildInternPool()    // 舊切片事件被移除 → 池重建才有界(xcheck r1)
            revision &+= 1
            return accepted
        }
        let fp = try writeAllAtomic(merged, to: fileURL)   // 先落盤;throw → 記憶體不變(舊切片保留)
        events = merged
        ids = seen
        reservedRawIDs = []   // #48 MF3 clearing twin:非-preservingRaw typed 重寫丟棄 raw-only 行
        rebuildInternPool()                                // 舊切片事件被移除 → 池重建才有界(xcheck r1)
        expectedFingerprint = fp   // 寫入當下捕捉(sol r3 MF2),取代事後 re-stat
        revision &+= 1
        return accepted
    }

    /// 清空(全量重建索引前呼叫)。
    public func reset() {
        events = []
        ids = []
        reservedRawIDs = []
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
