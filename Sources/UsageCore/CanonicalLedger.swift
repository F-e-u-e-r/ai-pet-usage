import Foundation

// #48 Option C(pivot:issue #48 comment 5120184667 §2)——版本化 raw-ledger canonicalizer。
//
// 角色:canonicalization 與 monotonic comparison 的單一真相(資料表示與判定)。
// 歷程:canonicalizer 階段(2026-07-30)本型別獨立驗收、未接線;gate 階段(2026-08-01,
// commit 3ae3676 起)由 UsageCoordinator.fullReindex 的 final 判定區呼叫(monotonicGateDecision)。
// 本型別自身仍不做任何 I/O 決策——replace/preserve 由 coordinator 依 verdict 執行。
//
// v1 規格(顯式、封閉):
// - `canonicalizerVersion = 1`;`ledgerSchemaAssumption = "usage-event-jsonl/current"`。
// - 從 raw JSONL bytes 出發(JSONSerialization 物件層),不先經寬鬆 typed decoder——
//   寬鬆 decode 會靜默吞掉未知 key 與 key-presence 資訊(R5 已證)。
// - 允許的 top-level keys = UsageEvent 現有全部 payload 欄位(見 `allowedKeys`);
//   tokens 子物件允許 keys 見 `allowedTokenKeys`。未知 key 一律 fail closed。
// - absent / explicit null / 0 預設「互不等義」。v1 顯式列舉的 normalization 只有:
//   (N1) `tokens.cacheWriteUnknown` absent ≡ explicit 0(舊行無此欄;owner 指定必須明文化,
//        不得依賴 decoder 偶然行為)。其餘 token 欄位 absent = missing required key ⇒ fail。
//   (N2) optional 欄位(accountId/projectId/projectName/modelId/sourcePath/providerCostUSD)
//        absent ≡ explicit null(production encoder 對 nil 一律省略 key;兩形皆 canonicalize
//        為 .null)。
//   (N3) timestamp 以 raw 字串精確比較,無任何正規化(小數秒/時區變體 ⇒ 差異 ⇒ fail closed)。
// - 兩側 duplicate event ID 偵測發生在建 dictionary 之前(先分組計數,絕不 keep-first 覆寫);
//   同一行內的重複 schema member 亦以 raw byte 掃描 fail closed(JSONSerialization 會先塌縮)。
// - 空白行:僅允許單一 trailing newline;內部空白行 ⇒ malformed(不靜默跳過)。
// - 數值:token 欄位必須為 JSON 整數且可精確落入 Int64(unsigned 超界 ⇒ fail closed);
//   `providerCostUSD` 保留 raw backing type(int-backed ≠ double-backed)——**沒有**型別形式
//   等義這條 normalization,`1` 與 `1.0` 視為差異 ⇒ fail closed。
// - 所有欄位預設 immutable。v1 enrichment allowlist 只有:
//   (E1) `modelId`:absent/null → known **非空** string(owner 裁定:`""` = invalid/unknown)。
//   known→known、known→nil、token/timestamp/identity/sourcePath 任何變化、未列舉差異 ⇒ fail。
//   (契約提及的「與 model 綁定的 display metadata」目前 schema 無此欄位;保留為空集合。)
// - candidate 一律以「實際將被持久化的 encoded bytes」進 canonicalization
//   (`canonicalizePersistedBytes`:先過 production encoder 再走同一 raw 路徑),
//   不比較可能遺失 key-presence 資訊的 in-memory typed 物件。
// - Failure 只攜帶計數與**封閉集內**的 schema key 名;未知 raw key 為攻擊者可控字串,
//   只以固定分類計數(unknownTopLevelKeys/unknownTokenKeys)呈現,絕不外帶原文;
//   絕不攜帶 payload 值或 sourcePath 值(count-only 揭示由後續 GUI/CLI 階段沿用)。
public enum CanonicalLedgerV1 {

    public static let canonicalizerVersion = 1
    public static let ledgerSchemaAssumption = "usage-event-jsonl/current"

    /// UsageEvent 的全部現有 payload 欄位(§2 要求全欄位入 canonical representation)。
    static let requiredKeys: Set<String> = ["id", "providerId", "timestamp", "tokens", "sourceKind"]
    static let optionalKeys: Set<String> = ["accountId", "projectId", "projectName", "modelId",
                                            "sourcePath", "providerCostUSD"]
    static var allowedKeys: Set<String> { requiredKeys.union(optionalKeys) }
    static let requiredTokenKeys: Set<String> = ["input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h"]
    /// N1:cacheWriteUnknown absent ≡ 0。
    static let normalizedAbsentZeroTokenKeys: Set<String> = ["cacheWriteUnknown"]
    static var allowedTokenKeys: Set<String> { requiredTokenKeys.union(normalizedAbsentZeroTokenKeys) }
    /// E1:唯一的 enrichment allowlist 欄位。
    static let enrichableKeys: Set<String> = ["modelId"]

    /// Canonical 值:顯式區分 string/int/double/bool/null(absent 依 N1/N2 收斂,否則為 fail)。
    public enum Value: Equatable, Sendable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case null
    }

    public struct Event: Equatable, Sendable {
        public let id: String
        /// key → canonical value;含 tokens 攤平為 "tokens.<sub>"。
        public let fields: [String: Value]
    }

    /// 單側 canonicalization 結果:成功 = 無重複的 id→event 映射。
    public struct Slice: Equatable, Sendable {
        public let events: [String: Event]
        public var count: Int { events.count }
    }

    /// 失敗摘要:只有計數與**固定 schema 詞彙**的 key 名。owner 裁定(impl-r1):未知 raw key 為
    /// 攻擊者可控字串,**絕不**原文外帶——只以固定分類計數呈現(unknownTopLevelKeys/unknownTokenKeys)。
    /// `offendingKeys` 只會出現封閉 key 集內的名字(missing/invalid 案例),無 payload、無路徑值。
    public struct FailureSummary: Error, Equatable, Sendable {
        public var malformedLines = 0
        public var missingRequiredKeys = 0
        public var unknownTopLevelKeys = 0
        public var unknownTokenKeys = 0
        /// 同一 raw JSON 行內重複出現的 schema key(JSONSerialization 會先塌縮 dictionary,
        /// 故以 raw byte 掃描偵測;歧義 ⇒ fail closed)。
        public var duplicateJSONMembers = 0
        /// key 位置出現 JSON escape(impl-r3 sol MUST-FIX):schema key 全為純 ASCII、永無跳脫;
        /// `"tokens"` 這類別名可繞過重複偵測再被 JSONSerialization 解碼塌縮 ⇒ 一律 fail closed。
        public var escapedKeyNames = 0
        /// Encoding-domain gate(owner amendment,spot-check MUST-FIX):輸入契約 = 無 BOM 嚴格
        /// 合法 UTF-8 JSONL。整份 Data 在**任何**切行/掃描/parse 前驗證;固定優先序
        /// BOM > NUL > invalid-UTF-8,單一分類計 1(share-safe count-only)。
        public var bomCount = 0
        public var nulByteCount = 0
        public var invalidEncodingCount = 0
        public var invalidTypes = 0
        public var duplicateIDs = 0
        /// 出錯的 key 名(去重、排序;**僅**封閉 key 集內的 schema 詞彙,未知 key 永不入列)。
        public var offendingKeys: [String] = []
        public var isEmpty: Bool {
            malformedLines == 0 && missingRequiredKeys == 0 && unknownTopLevelKeys == 0
                && unknownTokenKeys == 0 && duplicateJSONMembers == 0 && escapedKeyNames == 0
                && bomCount == 0 && nulByteCount == 0 && invalidEncodingCount == 0
                && invalidTypes == 0 && duplicateIDs == 0
        }
    }

    // MARK: - Canonicalization(raw bytes 起點)

    /// 從 raw JSONL bytes canonicalize 一側。任何行級失敗或 duplicate ⇒ .failure(fail closed)。
    /// 空白行(impl-r1 L1):唯一合法的空 subsequence 是「單一 trailing newline」產生的檔尾空段;
    /// 其餘(內部空白行、連續 newline)一律 malformed——靜默跳過即是未列舉 normalization。
    public static func canonicalizeRawLines(_ data: Data) -> Result<Slice, FailureSummary> {
        if data.isEmpty { return .success(Slice(events: [:])) }   // 空輸入 = 合法空 slice(零事件)。
        var summary = FailureSummary()

        // Encoding-domain gate(owner amendment):**先驗證整份 raw data,再切行**——
        // alternative encoding 下的 LF framing 本身不可信,不得先按 byte 切分未驗證輸入。
        // 主 gate = 嚴格 UTF-8(String(data:encoding:) 失敗即 nil,非 lossy);
        // BOM/NUL 為固定優先序的可診斷前置拒絕(BOM > NUL > invalid-UTF-8,單一分類計 1)。
        // 驗證後仍以**原始 bytes** 掃描(不引入任何未規格化的 normalization);
        // scanner 與 JSONSerialization 因此消費同一份已驗證 UTF-8 line bytes。
        if hasForbiddenBOM(data) { summary.bomCount = 1; return .failure(summary) }
        if data.contains(0x00) { summary.nulByteCount = 1; return .failure(summary) }
        guard String(data: data, encoding: .utf8) != nil else {
            summary.invalidEncodingCount = 1; return .failure(summary)
        }

        var offending: Set<String> = []
        var byID: [String: [Event]] = [:]   // 先分組,不覆寫——duplicate 偵測先於任何 keep-first。

        let segments = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (idx, line) in segments.enumerated() {
            if line.isEmpty {
                let isSoleTrailing = (idx == segments.count - 1) && data.last == 0x0A
                if !isSoleTrailing { summary.malformedLines += 1 }
                continue
            }
            // impl-r1 L2 / impl-r2 / impl-r3 收緊:JSONSerialization 會把同行重複 member 靜默塌縮
            // (先於 key 驗證),故先以 string-aware 掃描偵測同層重複 key;key 位置出現任何 JSON
            // escape(schema key 永為純 ASCII)同樣 fail closed——`"tokens"` 這類別名
            // 可繞過重複偵測、再被解碼塌縮(impl-r3 三 lens 收斂 MUST-FIX)。
            let scan = scanRawMembers(in: line)
            if scan.hasEscapedKey { summary.escapedKeyNames += 1; continue }
            if scan.hasDuplicate { summary.duplicateJSONMembers += 1; continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                summary.malformedLines += 1
                continue
            }
            switch canonicalizeObject(obj) {
            case .success(let event):
                byID[event.id, default: []].append(event)
            case .failure(let f):
                summary.malformedLines += f.malformedLines
                summary.missingRequiredKeys += f.missingRequiredKeys
                summary.unknownTopLevelKeys += f.unknownTopLevelKeys
                summary.unknownTokenKeys += f.unknownTokenKeys
                summary.invalidTypes += f.invalidTypes
                offending.formUnion(f.offendingKeys)
            }
        }
        for (_, group) in byID where group.count > 1 {
            summary.duplicateIDs += group.count
        }
        summary.offendingKeys = offending.sorted()
        guard summary.isEmpty else { return .failure(summary) }
        return .success(Slice(events: byID.compactMapValues(\.first)))
    }

    /// UTF-8/16/32 BOM 前綴(順序注意:UTF-32 的 BOM 含 UTF-16 BOM 前綴,先查 32)。
    private static func hasForbiddenBOM(_ data: Data) -> Bool {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return true }   // UTF-32BE
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return true }   // UTF-32LE
        if data.starts(with: [0xFF, 0xFE]) { return true }               // UTF-16LE
        if data.starts(with: [0xFE, 0xFF]) { return true }               // UTF-16BE
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return true }         // UTF-8 BOM
        return false
    }

    struct RawMemberScan {
        var hasDuplicate = false
        var hasEscapedKey = false
    }

    /// impl-r2(luna MUST-FIX)+ impl-r3(三 lens 收斂 MUST-FIX):string-aware 輕量 key 掃描——
    /// 追蹤字串/跳脫/巢狀深度,在 top-level(深度1)與 `tokens` 子物件收集 key 並偵測同層重複。
    /// 「key」= 字串後(容忍空白)緊接 `:` 者;字串**值**的內容被字串狀態機吃掉,不會誤中;
    /// 任意空白形式 `"key" :` 一樣被抓。**key 位置含任何 escape ⇒ hasEscapedKey**(schema key
    /// 永為純 ASCII;`"id"`/`"tokens"` 等別名會被 JSONSerialization 解碼塌縮,
    /// 掃描層看不見——一律 fail closed,任何深度皆然)。
    private static func scanRawMembers(in line: Data.SubSequence) -> RawMemberScan {
        var result = RawMemberScan()
        var inString = false, escaped = false, sawEscapeInCurrent = false
        var depth = 0
        var buf: [UInt8] = []
        var lastString: String? = nil        // 剛結束、尚未定性(key or value)的字串
        var lastStringHadEscape = false
        var seenTop = Set<String>(), seenTokens = Set<String>()
        var pendingTokensObject = false      // 剛看過 top-level "tokens": ,等它的 '{'
        var tokensObjectDepth: Int? = nil

        for byte in line {
            if inString {
                if escaped { escaped = false; buf.append(byte); continue }
                switch byte {
                case 0x5C: escaped = true; sawEscapeInCurrent = true    // backslash
                case 0x22:                                       // closing quote
                    inString = false
                    // sol follow-up(字面對齊):嚴格轉換取代 lossy String(decoding:as:)——
                    // 整份 Data 已過嚴格 UTF-8 gate,此處 nil 不可達;仍以 fail-closed 對待。
                    guard let s = String(data: Data(buf), encoding: .utf8) else {
                        result.hasEscapedKey = true
                        return result
                    }
                    lastString = s
                    lastStringHadEscape = sawEscapeInCurrent
                    buf.removeAll(keepingCapacity: true)
                    sawEscapeInCurrent = false
                default: buf.append(byte)
                }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x20, 0x09, 0x0D, 0x0A: break                   // whitespace:不定性
            case 0x3A:                                           // ':' → lastString 是 key
                if let key = lastString {
                    if lastStringHadEscape {                     // 任何深度的 escaped key ⇒ fail closed
                        result.hasEscapedKey = true
                        return result
                    }
                    if depth == 1 {
                        if !seenTop.insert(key).inserted { result.hasDuplicate = true; return result }
                        pendingTokensObject = (key == "tokens")
                    } else if let td = tokensObjectDepth, depth == td {
                        if !seenTokens.insert(key).inserted { result.hasDuplicate = true; return result }
                    }
                }
                lastString = nil
            case 0x7B:                                           // '{'
                depth += 1
                if pendingTokensObject { tokensObjectDepth = depth; pendingTokensObject = false }
                lastString = nil
            case 0x7D:                                           // '}'
                if let td = tokensObjectDepth, depth == td { tokensObjectDepth = nil }
                depth -= 1
                lastString = nil
                pendingTokensObject = false                      // impl-r3 grok NIT:旗標不跨界殘留
            case 0x5B: depth += 1; lastString = nil; pendingTokensObject = false   // '['
            case 0x5D: depth -= 1; lastString = nil                                 // ']'
            default:
                lastString = nil                                 // 逗號/數字/字面值:剛才的字串是 value
                if byte == 0x2C { pendingTokensObject = false }
            }
        }
        return result
    }

    /// req 12:candidate 以「實際持久化 bytes」canonicalize——先過 production encoder,
    /// 再走與 baseline 完全相同的 raw 路徑。
    public static func canonicalizePersistedBytes(of events: [UsageEvent]) -> Result<Slice, FailureSummary> {
        let encoder = AtomicJSON.encoder()
        var blob = Data()
        for e in events {
            guard let line = try? encoder.encode(e) else {
                var f = FailureSummary(); f.malformedLines = 1
                return .failure(f)
            }
            blob.append(line)
            blob.append(0x0A)
        }
        return canonicalizeRawLines(blob)
    }

    private static func canonicalizeObject(_ obj: [String: Any]) -> Result<Event, FailureSummary> {
        var summary = FailureSummary()
        var offending: Set<String> = []
        var fields: [String: Value] = [:]

        for key in obj.keys where !allowedKeys.contains(key) {
            summary.unknownTopLevelKeys += 1   // owner 裁定:未知 key 名=攻擊者可控字串,只計數、絕不外帶。
        }
        for key in requiredKeys where obj[key] == nil || obj[key] is NSNull {
            // required key 缺席或 explicit null ⇒ fail(N2 只適用 optional 欄位)。
            summary.missingRequiredKeys += 1
            offending.insert(key)
        }
        guard summary.unknownTopLevelKeys == 0, summary.missingRequiredKeys == 0 else {
            summary.offendingKeys = offending.sorted()
            return .failure(summary)
        }

        guard let id = obj["id"] as? String, !id.isEmpty else {
            summary.invalidTypes += 1; summary.offendingKeys = ["id"]
            return .failure(summary)
        }

        func putString(_ key: String) {
            switch obj[key] {
            case nil, is NSNull: fields[key] = .null            // N2
            case let s as String: fields[key] = .string(s)
            default: summary.invalidTypes += 1; offending.insert(key)
            }
        }
        fields["id"] = .string(id)
        putString("providerId"); putString("timestamp"); putString("sourceKind")   // N3:timestamp 原字串
        putString("accountId"); putString("projectId"); putString("projectName")
        putString("modelId"); putString("sourcePath")

        switch obj["providerCostUSD"] {
        case nil, is NSNull: fields["providerCostUSD"] = .null                     // N2
        case let n as NSNumber where !isBoolean(n):
            // impl-r1 L3(grok S1/luna F3):保留 raw backing type——int-backed 與 double-backed
            // 不等義(`1` ≠ `1.0`),無「型別形式等義」這條 normalization;異形 ⇒ 比對差異 ⇒ fail closed。
            if isIntegral(n) {
                if let v = exactInt64(n) { fields["providerCostUSD"] = .int(v) }
                else { summary.invalidTypes += 1; offending.insert("providerCostUSD") }
            } else {
                fields["providerCostUSD"] = .double(n.doubleValue)
            }
        default: summary.invalidTypes += 1; offending.insert("providerCostUSD")
        }

        if let tokens = obj["tokens"] as? [String: Any] {
            for key in tokens.keys where !allowedTokenKeys.contains(key) {
                summary.unknownTokenKeys += 1   // 同 top-level:未知 key 只計數,不外帶名字。
            }
            for key in allowedTokenKeys {
                switch tokens[key] {
                case nil where normalizedAbsentZeroTokenKeys.contains(key):
                    fields["tokens." + key] = .int(0)                              // N1
                case nil, is NSNull:
                    summary.missingRequiredKeys += 1; offending.insert("tokens." + key)
                case let n as NSNumber where !isBoolean(n) && isIntegral(n):
                    // impl-r1 L4:窄化前範圍檢查——unsigned 超出 Int64.max 會 wrap 成別的值,
                    // 讓非單調 candidate 假相等;超界 ⇒ invalidType fail closed。
                    if let v = exactInt64(n) { fields["tokens." + key] = .int(v) }
                    else { summary.invalidTypes += 1; offending.insert("tokens." + key) }
                default:
                    summary.invalidTypes += 1; offending.insert("tokens." + key)
                }
            }
        } else {
            summary.invalidTypes += 1; offending.insert("tokens")
        }

        guard summary.isEmpty else {
            summary.offendingKeys = offending.sorted()
            return .failure(summary)
        }
        return .success(Event(id: id, fields: fields))
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    private static func isIntegral(_ n: NSNumber) -> Bool {
        // JSONSerialization:整數字面值 → 整數型 NSNumber;"100.0"/"1.5" → double-backed。
        // token 值規格為 JSON 整數;double-backed 一律視為型別偏差 ⇒ fail closed。
        let t = String(cString: n.objCType)
        return t != "d" && t != "f"
    }

    /// impl-r1 L4 / impl-r2 收緊:Int64 精確窄化。unsigned('Q')超界 ⇒ nil;
    /// 另以數值 round-trip 通用防護任何 exotic backing(窄化有損 ⇒ nil ⇒ 呼叫端 fail closed)。
    private static func exactInt64(_ n: NSNumber) -> Int64? {
        if String(cString: n.objCType) == "Q", n.uint64Value > UInt64(Int64.max) { return nil }
        let v = n.int64Value
        guard NSNumber(value: v).compare(n) == .orderedSame else { return nil }
        return v
    }

    // MARK: - Monotonic comparison

    public enum Verdict: Equatable, Sendable {
        /// candidate 為 baseline 的語意非回退超集合。
        case pass(newEvents: Int, enrichedEvents: Int)
        /// 任何缺失/變異(counts only)。
        case fail(missingEvents: Int, changedEvents: Int)
    }

    /// 前提:兩側 Slice 皆出自本型別的 canonicalize(duplicate 已在該層 fail closed)。
    public static func compareMonotonic(baseline: Slice, candidate: Slice) -> Verdict {
        var missing = 0, changed = 0, enriched = 0
        for (id, b) in baseline.events {
            guard let c = candidate.events[id] else { missing += 1; continue }
            if c == b { continue }
            if isAllowlistedEnrichment(baseline: b, candidate: c) { enriched += 1; continue }
            changed += 1
        }
        guard missing == 0, changed == 0 else {
            return .fail(missingEvents: missing, changedEvents: changed)
        }
        let newCount = candidate.events.keys.filter { baseline.events[$0] == nil }.count
        return .pass(newEvents: newCount, enrichedEvents: enriched)
    }

    /// E1:enrichable key 由 null → **非空** string(owner 裁定:`""` 是 invalid/unknown,
    /// 不得成為 known target),其餘欄位必須全等。known→known / known→null ⇒ 非 enrichment。
    /// `enrichableKeys` 為單一真相(impl-r1 grok N4):新增 enrichable 欄位改集合即可。
    private static func isAllowlistedEnrichment(baseline: Event, candidate: Event) -> Bool {
        var b = baseline.fields, c = candidate.fields
        var anyEnriched = false
        for key in enrichableKeys {
            if b[key] == c[key] { continue }                 // 該 key 未變:交給整體等值判定。
            guard b[key] == .null, case .string(let s)? = c[key], !s.isEmpty else { return false }
            b.removeValue(forKey: key)
            c.removeValue(forKey: key)
            anyEnriched = true
        }
        return anyEnriched && b == c
    }
}
