import Foundation
import CryptoKit

// MARK: - #50 Authoritative Cumulative Accounting Authority
//
// 分工(勿混淆):
//   ScanState        = discovery / cursor 最佳化 —— 可落後、可遺失、可重建,**非 correctness authority**
//   CumulativeAnchor = accounting authority —— 必須挺過 ScanState 遺失與一般 ledger retention
//
// 三個 owner-locked contract 直接反映在型別上:
//   B  incarnation key 同時需要 sessionId 與 timeCreated。缺少 timeCreated 的 legacy 狀態
//      **在結構上就無法構成 key**,因此不可能自動升格為 authority。
//   A  Pending 攜帶**完整且不可變的 UsageEvent**,recovery 重播該事件本身,
//      不回頭向可能已消失的來源列重新導出。
//   D  authority bytes 必須通過 parse → integrity → semantic 三關才可參與計算。

/// 單一 session incarnation 的絕對計數器。
public struct AnchorCounters: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int          // tokens_output + tokens_reasoning(摺疊後)
    public var cacheRead: Int
    public var cacheWrite: Int
    public var cost: Double

    public var foldTotal: Int { input + output + cacheRead + cacheWrite }

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                cacheWrite: Int = 0, cost: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cost = cost
    }

    /// component-wise ≥。同 epoch 的成長必須逐項不減。
    public func dominates(_ o: AnchorCounters) -> Bool {
        input >= o.input && output >= o.output && cacheRead >= o.cacheRead && cacheWrite >= o.cacheWrite
    }
}

/// session incarnation 身分。**兩個欄位皆為必要** —— 這是 B contract 的結構性保證。
public struct IncarnationKey: Hashable, Sendable {
    public var sessionId: String
    public var timeCreatedMs: Int64

    public init(sessionId: String, timeCreatedMs: Int64) {
        self.sessionId = sessionId
        self.timeCreatedMs = timeCreatedMs
    }

    /// JSON 字典鍵編碼。以**第一個** `|` 分隔,故 sessionId 可含任意字元。
    public var encoded: String { "\(timeCreatedMs)|\(sessionId)" }

    /// R3(X2 修正,owner contract):canonical accounting-operation identity。
    ///
    /// 舊格式 `oc:<sid>:<epoch>:<from>` 不含 incarnation,同一 sessionId 的兩個 incarnation
    /// 會產生相同 id 而被 keep-first 吞掉。`oc2:` 進一步要求:**兩個會產生不同
    /// authoritative target / UsageEvent 的 operations 不得同 id;同一 operation 的 replay
    /// 必須產生完全相同的 id。** 因此 id 涵蓋完整 previous→target 座標(四類 token + cost;
    /// cost 用 bitPattern 保證無損 deterministic)—— 連續 cost-only 變化(token 不動)也
    /// 必然得到不同 id,不再需要 ad-hoc 型別後綴。`oc2:` 尚未 shipped ⇒ 直接修正其 contract,
    /// 不另開 `oc3:`;已 shipped 的 `oc:` 歷史保持不動。id 是 opaque dedup key,不設計為可
    /// parse(sessionId 可含任意字元)。X5 validator 以同一 helper 重算比對。
    public func eventId(epoch: Int, previous: AnchorCounters, target: AnchorCounters) -> String {
        let p = "\(previous.input),\(previous.output),\(previous.cacheRead),\(previous.cacheWrite),\(previous.cost.bitPattern)"
        let t = "\(target.input),\(target.output),\(target.cacheRead),\(target.cacheWrite),\(target.cost.bitPattern)"
        return "oc2:\(timeCreatedMs)~\(sessionId):\(epoch):\(p)>\(t)"
    }

    public init?(encoded: String) {
        guard let sep = encoded.firstIndex(of: "|") else { return nil }
        guard let tc = Int64(encoded[encoded.startIndex..<sep]) else { return nil }
        let sid = String(encoded[encoded.index(after: sep)...])
        guard !sid.isEmpty else { return nil }
        self.init(sessionId: sid, timeCreatedMs: tc)
    }
}

/// 顯式 durable reconciliation intent —— **自足**。
///
/// A contract:一旦 Pending durable,recovery 必須能在原始來源列永久消失的情況下完成,
/// 不得重新向來源猜測 operation。因此此處保存的是**當初準備好的那個 event 本身**,
/// 而非「足以重算的參數」。`UsageEvent: Hashable` 使 canonical equality 涵蓋未來新增欄位。
public struct PendingReconciliation: Codable, Hashable, Sendable {
    public var event: UsageEvent
    /// 本 operation 意圖把 authority 自 previous 推進到 target。
    public var previous: AnchorCounters
    public var target: AnchorCounters
    /// 本 operation 所屬的 epoch(必須等於 anchor 的 epoch)。
    public var epoch: Int

    public init(event: UsageEvent, previous: AnchorCounters, target: AnchorCounters, epoch: Int) {
        self.event = event
        self.previous = previous
        self.target = target
        self.epoch = epoch
    }
}

/// F4(grok-50-r2):epoch 已在合法演進上界 —— 再 +1 會產生 trap 或一個 load 必被
/// reject 的狀態。呼叫端必須 fail closed 並要求顯式恢復,不得讓行程 trap。
public struct EpochBoundExceeded: Error, CustomStringConvertible, Sendable {
    public let sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
    public var description: String {
        "session '\(sessionId)' accounting epoch is at its bound and cannot advance — explicit re-baseline required"
    }
}

public struct CumulativeAnchor: Codable, Hashable, Sendable {
    public var epoch: Int
    /// 已入帳的絕對計數器。**只在 durable ledger commit 之後才推進**。
    public var accountedThrough: AnchorCounters
    public var pending: PendingReconciliation?

    public init(epoch: Int = 1, accountedThrough: AnchorCounters = AnchorCounters(),
                pending: PendingReconciliation? = nil) {
        self.epoch = epoch
        self.accountedThrough = accountedThrough
        self.pending = pending
    }

    /// F4:epoch 的**唯一**合法演進途徑。合法域 = 1...(Int.max - 1)(validateSemantics 同界),
    /// 且演進結果必須仍在合法域內 —— 否則回 nil,呼叫端必須 fail closed。
    /// 兩道防線缺一不可:validator 擋住已損壞的 persisted 值,本 helper 保證即使
    /// 它被繞過也絕不 trap、絕不寫出一個下次 load 必被 reject 的 epoch。
    public static func nextEpoch(after current: Int) -> Int? {
        guard current > 0, current < Int.max - 1 else { return nil }
        return current + 1
    }
}

/// 整份 authority 檔的內容。
public struct CumulativeAuthority: Codable, Sendable {
    // X6(grok-50-r3,owner verdict):檔案不存在 = 尚無 authority(establishment 路徑);
    // 檔案存在但缺必要 schema 欄位(含 lastCompleteCensusMs)= invalid authority ⇒ decode
    // 失敗 ⇒ fail closed(D contract)。schema 尚未 shipped,**刻意不做 legacy migration**,
    // 也不把缺鍵寬容成空 —— 那會削弱 semantic fail-closed contract。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// R1:最後一次**完整成功** census 的來源時間邊界(ms)。
    ///
    /// 只有在一輪 census 完整成功、且該 provider 沒有未解決的 authority failure 時才推進。
    /// 它與 authoritative anchor 屬同一 correctness domain,是判斷「某個沒有 anchor 的
    /// incarnation 究竟是**觀測期後才建立**(可計首窗)還是**本應早已可見**(歧義,fail closed)」
    /// 的唯一依據 —— 不以 `time_created` 看起來新不新來猜。
    public var lastCompleteCensusMs: [String: Int64]
    /// canonical digest。用途是**偵測意外遺漏、部分語義變更、或內部不一致的 authority bytes**——
    /// 不是 authentication、不是防篡改;通過它之後仍必須跑完整 semantic validation。
    public var integrity: String
    /// providerId → IncarnationKey.encoded → anchor
    public var providers: [String: [String: CumulativeAnchor]]

    public init(schemaVersion: Int = CumulativeAuthority.currentSchemaVersion,
                integrity: String = "", providers: [String: [String: CumulativeAnchor]] = [:],
                lastCompleteCensusMs: [String: Int64] = [:]) {
        self.schemaVersion = schemaVersion
        self.integrity = integrity
        self.providers = providers
        self.lastCompleteCensusMs = lastCompleteCensusMs
    }
}

// MARK: - adapter seam

/// 單一 session incarnation 本輪的提案。
public struct CumulativeProposal: Sendable {
    /// 需寫入帳本的事件;nil = 本輪無事件(zero-delta 建立 / rollback epoch 邊界 / 零差額)。
    public var event: UsageEvent?
    /// 成功後 anchor 的目標狀態(`pending` 恆為 nil —— pending 由 coordinator 構造)。
    public var target: CumulativeAnchor

    public init(event: UsageEvent?, target: CumulativeAnchor) {
        self.event = event
        self.target = target
    }
}

public struct CumulativeDerivation: Sendable {
    public var proposals: [IncarnationKey: CumulativeProposal]
    /// R1:沒有 anchor、且其 `timeCreated` 早於上一個 durable complete-census boundary 的
    /// incarnation —— 它「本應早已可見」卻無權威,屬歧義,呼叫端必須 fail closed。
    public var ambiguous: [IncarnationKey]
    /// discovery/便利用的 cursor;**不參與 correctness 判定**。
    public var scanState: ScanState
    public var parseErrors: Int
    /// X4(grok-50-r3,owner contract):因 parse/identity 無法**納入** census 的來源列數。
    /// 與 `parseErrors` 分開 —— 後者亦含「列已納入但欄位降級」(如 model JSON 壞)的品質計數。
    /// 任何 excludedRows > 0 的輪都**不具 complete-census 資格**:valid rows 照常處理,
    /// 但 `lastCompleteCensusMs` 不得推進(「掃過查詢」≠「完成 authoritative census」)。
    public var excludedRows: Int
    public var scannedFiles: Int

    public var events: [UsageEvent] {
        proposals.values.compactMap(\.event).sorted { $0.timestamp < $1.timestamp }
    }

    public init(proposals: [IncarnationKey: CumulativeProposal], ambiguous: [IncarnationKey] = [],
                scanState: ScanState, parseErrors: Int, excludedRows: Int = 0, scannedFiles: Int) {
        self.proposals = proposals
        self.ambiguous = ambiguous
        self.scanState = scanState
        self.parseErrors = parseErrors
        self.excludedRows = excludedRows
        self.scannedFiles = scannedFiles
    }
}

/// #50 窄 seam —— 僅 cumulativeSnapshotOnly provider 實作。
///
/// `establishOnly`:無既有 authority 且無任何既往記帳證據時的**顯式 zero-delta 建立**——
/// 把當下絕對計數器定為 baseline、本輪不發事件,避免把我方開始觀測之前的歷史用量
/// 追溯記到今天。此路徑亦使「authority 遺失且帳本證據已被 retention 清除」的歧義情境
/// 失敗方向恆為有界低估,而非溢收。
public protocol CumulativeAnchorAdapter {
    /// `boundaryMs`:上一次 durable complete-census 的時間邊界;nil = 尚無此證明。
    /// `establishAll`:顯式 re-baseline —— 所有可觀測 incarnation 一律 zero-delta 重錨。
    func censusCumulative(anchors: [IncarnationKey: CumulativeAnchor],
                          scanState: ScanState,
                          boundaryMs: Int64?,
                          establishAll: Bool) throws -> CumulativeDerivation
}

// MARK: - 載入結果

/// R5:rename 已成功、其後 directory sync 失敗 —— pathname 可能已指向新內容,
/// 且其跨斷電耐久性未知。**不得**被當成「失敗且未變更」。
public struct AuthorityOutcomeUnknown: Error {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
}

public enum AuthorityLoad: Sendable {
    /// 檔案確定不存在 —— 尚無 authority(合法的初始狀態)。
    case absent
    /// 存在但不可採信:讀不到、解不開、integrity 不符、或語義不可能。一律整個 provider fail closed。
    case rejected(String)
    case loaded(CumulativeAuthority)
}

// MARK: - 持久化

/// `cumulative-anchors.json` 的 durable store。
///
/// 刻意不抽 generic DurableStore;只 reuse `DurabilityOps` 的 syscall contract:
/// temp(O_EXCL, write-all)→ F_FULLFSYNC → rename → parent-dir fsync;任何 barrier 失敗即 throw。
final class CumulativeAnchorStore {
    private let fileURL: URL?
    private let durabilityOps: DurabilityOps

    init(fileURL: URL?, durabilityOps: DurabilityOps) {
        self.fileURL = fileURL
        self.durabilityOps = durabilityOps
    }

    /// parse → integrity → semantic,三關全過才回 `.loaded`。
    func load() -> AuthorityLoad {
        guard let fileURL else { return .absent }
        let raw: Data
        do {
            raw = try Data(contentsOf: fileURL)
        } catch {
            if AtomicJSON.pathIsGenuinelyMissing(fileURL.path) { return .absent }
            return .rejected("authority file exists but is unreadable")
        }
        let decoded: CumulativeAuthority
        do {
            decoded = try AtomicJSON.decoder().decode(CumulativeAuthority.self, from: raw)
        } catch {
            return .rejected("authority file is not decodable")
        }
        if let why = Self.verifyIntegrity(decoded) { return .rejected(why) }
        if let why = Self.validateSemantics(decoded) { return .rejected(why) }
        return .loaded(decoded)
    }

    func saveDurably(_ authority: CumulativeAuthority) throws {
        guard let fileURL else { return }
        var stamped = authority
        stamped.schemaVersion = CumulativeAuthority.currentSchemaVersion
        stamped.integrity = Self.canonicalDigest(of: stamped)
        let blob = try AtomicJSON.encoder().encode(stamped)
        let parent = fileURL.deletingLastPathComponent()
        try AppPaths.ensureDirectory(parent)
        let tempURL = parent.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var wrote = 0
        let total = blob.count
        var writeErrno: Int32 = 0
        blob.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            while wrote < total {
                let n = write(fd, rawBuf.baseAddress!.advanced(by: wrote), total - wrote)
                if n > 0 { wrote += n; continue }
                if n < 0 && errno == EINTR { continue }
                writeErrno = (n < 0) ? errno : EIO
                return
            }
        }
        guard wrote == total else {
            close(fd); unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(writeErrno))
        }
        guard durabilityOps.syncFile(fd) == 0 else {
            let e = errno; close(fd); unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        close(fd)
        guard durabilityOps.renameFile(tempURL.path, fileURL.path) == 0 else {
            let e = errno; unlink(tempURL.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        guard durabilityOps.syncDirectory(parent.path) == 0 else {
            // rename 已生效:舊內容可能已不可達。回報 outcome-unknown,不得謊稱未變更。
            throw AuthorityOutcomeUnknown("directory sync failed after the replacement was renamed into place")
        }
    }

    /// F2(grok-50-r2):上一次 save 以 outcome-unknown 結束(rename 已生效、dir-sync 失敗)
    /// 之後,恢復 accounting 前先確認**目前可見**的 directory entry 已 durable ——
    /// 只重做 parent-dir fsync 這一個 barrier,不盲目重做原 accounting 寫入。
    /// 驗證半部(parse → integrity → semantic)由其後的 load() 完成。
    func confirmVisibleEntryDurable() throws {
        guard let fileURL else { return }
        let parent = fileURL.deletingLastPathComponent()
        guard durabilityOps.syncDirectory(parent.path) == 0 else {
            throw AuthorityOutcomeUnknown("directory sync is still failing — the durability of the visible authority entry remains unconfirmed")
        }
    }

    /// X1(grok-50-r3,owner contract):對「目前載入的 exact authority」建立 process-independent
    /// durability confirmation —— file barrier(F_FULLFSYNC)+ parent-dir barrier,不重寫檔案、
    /// 不做任何 accounting mutation。fresh process 無從得知上一個 process 的 rename 是否曾
    /// 通過 directory barrier;在此 confirmation 成功前,載入的 bytes 不得支撐任何
    /// correctness-affecting 動作(pending recovery / ledger append / anchor、boundary、cursor 推進)。
    /// 呼叫端在 refresh.lock 內、且 load() 已成功之後呼叫 —— 無並行 writer,fd 所指內容
    /// 即 load 所讀內容。
    func confirmLoadedAuthorityDurable() throws {
        guard let fileURL else { return }
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw AuthorityOutcomeUnknown("cannot open the visible authority file to confirm its durability")
        }
        guard durabilityOps.syncFile(fd) == 0 else {
            close(fd)
            throw AuthorityOutcomeUnknown("file durability barrier failed while confirming the loaded authority")
        }
        close(fd)
        let parent = fileURL.deletingLastPathComponent()
        guard durabilityOps.syncDirectory(parent.path) == 0 else {
            throw AuthorityOutcomeUnknown("directory durability barrier failed while confirming the loaded authority")
        }
    }

    // MARK: integrity(completeness / accidental-omission detection)

    /// canonical digest:涵蓋**整個 correctness-relevant authority payload**(digest 欄位自身除外)
    /// —— schemaVersion、per-provider lastCompleteCensusMs、以及全部 anchors。
    /// F3(grok-50-r2):census boundary 是 authority provenance(R1 的唯一判準),
    /// 它的意外遺漏、偽造或倒退必須與 anchor 遺漏一樣可被偵測。
    /// providerId 與 incarnation key 皆排序後,對帶 domain 前綴的 canonical 表示取 SHA-256。
    /// 目的是偵測**意外遺漏或部分語義變更**(例如某個 anchor record 被刪掉但其餘仍語法合法),
    /// 不是 authentication —— 沒有金鑰,也不宣稱可防惡意篡改;通過後仍須 semantic validation。
    static func canonicalDigest(of a: CumulativeAuthority) -> String {
        let encoder = AtomicJSON.encoder()   // .sortedKeys
        var parts: [String] = []
        parts.append("schemaVersion\u{1F}\(a.schemaVersion)")
        for pid in a.lastCompleteCensusMs.keys.sorted() {
            parts.append("census\u{1F}\(pid)\u{1F}\(a.lastCompleteCensusMs[pid]!)")
        }
        for pid in a.providers.keys.sorted() {
            let m = a.providers[pid] ?? [:]
            for k in m.keys.sorted() {
                guard let blob = try? encoder.encode(m[k]!) else { continue }
                parts.append("anchor\u{1F}\(pid)\u{1F}\(k)\u{1F}\(String(decoding: blob, as: UTF8.self))")
            }
        }
        let joined = parts.joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verifyIntegrity(_ a: CumulativeAuthority) -> String? {
        guard a.schemaVersion == CumulativeAuthority.currentSchemaVersion else {
            return "authority schema version \(a.schemaVersion) is not supported"
        }
        let expected = canonicalDigest(of: a)
        guard a.integrity == expected else {
            return "authority integrity digest mismatch — record omission or partial mutation"
        }
        return nil
    }

    // MARK: semantic validation
    //
    // 任一條不成立即整份 reject —— v1 刻意**不做 partial salvage**:一旦 authority 出現語義損壞,
    // 損壞邊界未知,挑「看起來還好的」record 繼續用等於在猜。
    //
    // 本層刻意保持 provider-agnostic;事件 id 的格式(如 `oc:<sid>:<epoch>:<from>`)屬 adapter
    // 契約,由 adapter 於導出/重播時自行檢查。

    /// 與來源側一致的計數上界(`OpenCodeAdapter.readRows` 對每個欄位套用同一 cap)。
    /// 同時提供溢位安全:4 類各 ≤ 1e15 ⇒ foldTotal ≤ 4e15,遠低於 `Int.max`。
    static let counterSaneCap = 1_000_000_000_000_000

    private static func checkCounters(_ c: AnchorCounters, _ label: String) -> String? {
        for (name, v) in [("input", c.input), ("output", c.output),
                          ("cacheRead", c.cacheRead), ("cacheWrite", c.cacheWrite)] {
            if v < 0 { return "\(label) \(name) is negative" }
            if v > counterSaneCap { return "\(label) \(name) exceeds the source sane cap" }
        }
        guard c.cost.isFinite, c.cost >= 0 else { return "\(label) cost is not a finite non-negative value" }
        return nil
    }

    static func validateSemantics(_ a: CumulativeAuthority) -> String? {
        // X3(grok-50-r3,owner contract):census boundary 是 R1 的唯一判準 —— 非正/超界的
        // boundary(如 -1)會把所有正常 timeCreated 誤判為 post-boundary ⇒ 全額回填
        // (silent overcount)。與來源 timestamp 同一個 sanity domain(reuse counterSaneCap,
        // 不另發明 census-only 規則);缺 provider 條目 = 尚無 boundary(合法);
        // 值不合法 ⇒ 整份 reject fail closed —— 不 clamp、不 silent drop。
        for (pid, ms) in a.lastCompleteCensusMs {
            guard !pid.isEmpty else { return "census boundary carries an empty provider id" }
            guard ms > 0, ms <= counterSaneCap else {
                return "census boundary for '\(pid)' is outside the sane source-timestamp domain"
            }
        }
        for (pid, anchors) in a.providers {
            guard !pid.isEmpty else { return "authority contains an empty provider id" }
            for (rawKey, anchor) in anchors {
                guard let ik = IncarnationKey(encoded: rawKey) else {
                    return "incarnation key '\(rawKey)' is not parseable — it must carry both sessionId and timeCreated"
                }
                guard ik.timeCreatedMs > 0, ik.timeCreatedMs <= counterSaneCap else {
                    return "incarnation key '\(rawKey)' has a source-impossible timeCreated"
                }
                // F4:上界與下界並列 —— epoch == Int.max 不是可合法演進的狀態(nextEpoch 會
                // 對它 fail closed),含它的 authority 一律 reject,而不是等到 census +1 時 trap。
                guard anchor.epoch > 0, anchor.epoch < Int.max else {
                    return "anchor \(rawKey) epoch \(anchor.epoch) is outside the valid range 1...\(Int.max - 1)"
                }
                if let why = checkCounters(anchor.accountedThrough, "anchor \(rawKey) accountedThrough") {
                    return why
                }
                guard let p = anchor.pending else { continue }

                if let why = checkCounters(p.previous, "anchor \(rawKey) pending.previous") { return why }
                if let why = checkCounters(p.target, "anchor \(rawKey) pending.target") { return why }
                guard p.epoch == anchor.epoch else {
                    return "anchor \(rawKey) pending.epoch \(p.epoch) does not match anchor epoch \(anchor.epoch)"
                }
                guard p.previous == anchor.accountedThrough else {
                    return "anchor \(rawKey) pending.previous does not match the anchor's accountedThrough"
                }
                guard p.target.dominates(p.previous) else {
                    return "anchor \(rawKey) pending.target is below pending.previous within the same epoch"
                }
                guard p.event.providerId == pid else {
                    return "anchor \(rawKey) pending.event belongs to provider '\(p.event.providerId)', not '\(pid)'"
                }
                guard !p.event.id.isEmpty else { return "anchor \(rawKey) pending.event has an empty id" }
                guard p.event.timestamp.timeIntervalSince1970.isFinite else {
                    return "anchor \(rawKey) pending.event has a non-finite timestamp"
                }
                if let c = p.event.providerCostUSD, !(c.isFinite && c >= 0) {
                    return "anchor \(rawKey) pending.event has a non-finite or negative provider cost"
                }

                // R4:**先逐欄驗證再做任何加法** —— event 的 token 欄位本身也是 authority 的一部分,
                // 未經驗證就相加會在構造過的檔案上 trap(整數溢位),那是最糟的失敗方向:
                // 應當 reject 整份 authority,而不是讓行程崩潰。
                let t = p.event.tokens
                for (name, v) in [("input", t.input), ("output", t.output), ("cacheRead", t.cacheRead),
                                  ("cacheWrite5m", t.cacheWrite5m), ("cacheWrite1h", t.cacheWrite1h),
                                  ("cacheWriteUnknown", t.cacheWriteUnknown)] {
                    if v < 0 { return "anchor \(rawKey) pending.event token \(name) is negative" }
                    if v > counterSaneCap {
                        return "anchor \(rawKey) pending.event token \(name) exceeds the source sane cap"
                    }
                }
                // 逐欄皆 ≤ 1e15 ⇒ 三項相加 ≤ 3e15,遠低於 Int.max;此處已不可能溢位。
                let eventCacheWrite = t.cacheWrite5m + t.cacheWrite1h + t.cacheWriteUnknown

                // event 的 token 量必須恰好等於 previous→target 的差額 —— 否則重播該 event
                // 會把 authority 推到一個與帳本不一致的位置。
                let expected = (input: p.target.input - p.previous.input,
                                output: p.target.output - p.previous.output,
                                cacheRead: p.target.cacheRead - p.previous.cacheRead,
                                cacheWrite: p.target.cacheWrite - p.previous.cacheWrite)
                guard t.input == expected.input, t.output == expected.output,
                      t.cacheRead == expected.cacheRead,
                      eventCacheWrite == expected.cacheWrite else {
                    return "anchor \(rawKey) pending.event tokens do not equal the previous→target delta"
                }

                // X5(grok-50-r3,owner contract):pending 必須等於 canonical derivation 的預期,
                // 不是「幾個欄位看起來合理」。id 逐位重算(與 prepare 同一 helper)、cost transition
                // 與 provider-reported cost 一致;任何 mismatch = malformed authority ⇒ 整份
                // reject fail closed —— 不得「修正 id 後繼續」。這同時封掉「id 撞既有 ledger 事件
                // ⇒ recovery 誤 finalize」與「target.cost 憑空推進而 event 無對應成本」兩路。
                let expectedId = ik.eventId(epoch: p.epoch, previous: p.previous, target: p.target)
                guard p.event.id == expectedId else {
                    return "anchor \(rawKey) pending.event id does not match the canonical accounting-operation identity"
                }
                // R5-A 一致化:writer 已改 strict cost semantics(任何 exact 上升都 emit、
                // 任何 exact 下降都 rollback 換 epoch)⇒ 本 invariant 的數值必須同一 contract:
                // providerCost 存在 ⇒ 恰等 delta(同源 double,bit-exact);nil ⇒ delta 恰為 0
                //(strict 世界裡負 delta 的 pending 不可能由 writer 產生 ⇒ malformed,reject)。
                // 若 validator 保留舊 1e-6 下限,strict writer 的合法 sub-eps pending 會被
                // 打成 malformed ⇒ 整份 authority poison —— 此一致化是 R5-A 的必要組成。
                let pendingCostDelta = p.target.cost - p.previous.cost
                if let c = p.event.providerCostUSD {
                    guard c > 0, c == pendingCostDelta else {
                        return "anchor \(rawKey) pending.event provider cost is inconsistent with the previous→target cost transition"
                    }
                } else {
                    guard pendingCostDelta == 0 else {
                        return "anchor \(rawKey) pending cost transition advances without a matching provider-reported cost"
                    }
                }
            }
        }
        return nil
    }
}
