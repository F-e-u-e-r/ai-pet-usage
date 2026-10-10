import Foundation

/// Codex **app-server** 官方額度來源(Source B;owner 2026-10-09 裁示的 primary codex quota source)。
///
/// 透過本機 `codex app-server`(stdio JSON-RPC)呼叫 `account/rateLimits/read`,取得
/// provider-reported 的 5h / 週窗口 used%、窗長、重置時刻,折成 `observedAt = fetch 完成時刻` 的
/// `RateLimitReading`,經**既有單一** `LimitEngine.ingest` 權威折疊(fresh observedAt → 蓋過
/// turn-emission-bound 的 rollout Source A;見 docs/ADAPTER_CONTRACT.md 與 watchdog 證據
/// `reviews/codex-quota-watchdog/`)。
///
/// 硬線(owner 契約):
///   - **不是** opt-in:偵測到 codex 即為正常整合;不可用/未登入/壞/逾時/不支援 → **fail soft 回 Source A**
///     (絕不造 0%、絕不把 absence 變成 0%)。
///   - 非持久 daemon:每次抓取 spawn 一個短命 `codex app-server`,bounded timeout,確定性 teardown
///     (close stdin → terminate → SIGKILL → reap;並 join 讀取緒後才讓 pipe 釋放,避免 close race)。
///   - 隱私 fail-closed:**窄解碼**只取兩窗 used%/窗長/重置 + **經 sanitize 的** planType;
///     credits/account/ordinaryUsage 等一律不 decode;原始回應永不持久化/log;不抽 token、不碰 direct-backend。
///   - 不進同步 adapter hot path:呼叫端在背景 async 執行(spawn ~0.8–2.5s)。
public enum CodexAppServerLimits {

    /// 回應累積上限(真實 rate-limit JSON ~200 bytes;遠超 = 壞/惡意 child → fail-soft,不耗記憶體)。
    static let maxResponseBytes = 1_048_576

    // MARK: - 窄解碼(camelCase;與 rollout 的 snake_case 刻意分離,privacy-narrow)

    /// app-server `result` 物件的**窄 Decodable**:只宣告額度所需欄位。`result` 其餘欄位
    /// (`ordinaryUsageAllowed`、`rateLimitResetCredits`、account metadata 等)未宣告 → 永不 materialize。
    struct RateLimitsResult: Decodable {
        let rateLimits: Windows?
        struct Windows: Decodable {
            let primary: Window?
            let secondary: Window?
            let planType: String?
        }
        struct Window: Decodable {
            let usedPercent: Double?
            let windowDurationMins: Int?
            /// 觀察為 Unix epoch 秒(number);某些版本可能為 ISO 字串 → 兩者皆容忍(其餘型別 = nil)。
            let resetsAt: ResetsAt?
        }
        /// `resetsAt` 容忍 number(epoch 秒)或 ISO8601 字串;無法解讀 → `.none`(窗仍可用,只是無重置時刻)。
        enum ResetsAt: Decodable {
            case epoch(Double)
            case iso(String)
            case unknown
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let d = try? c.decode(Double.self) { self = .epoch(d) }
                else if let s = try? c.decode(String.self) { self = .iso(s) }
                else { self = .unknown }
            }
            var date: Date? {
                switch self {
                case .epoch(let d): return d.isFinite ? Date(timeIntervalSince1970: d) : nil
                case .iso(let s): return ISO8601.parse(s)
                case .unknown: return nil
                }
            }
        }
    }

    public enum DecodeOutcome: Equatable {
        /// 解碼成功;可能為空(無任何可分類/合法窗、也無合法 plan → fail-soft,呼叫端不 ingest)。
        case ok([RateLimitReading])
        /// 非 JSON / 非物件 / 無 `rateLimits` 物件 → 無法辨識 → 呼叫端 fail-soft 回 Source A。
        case malformed
    }

    /// 方案標籤 sanitize(privacy fail-closed):真實 codex 方案標籤是**單一短字母詞**(plus/pro/team/
    /// enterprise…)。只接受 `[A-Za-z]{1,16}`;其餘一律 nil。此嚴格形態擋掉所有危險輸入——
    /// token(`sk-…`)、UUID(`550e8400-…`)、email(`@`)、path(`/`)、多 MB —— 它們都含非字母字元
    /// 或超長(xcheck r2 sol BLOCKER:舊的「字母數字 + `_ . -`」會讓 token/UUID 整串通過)。
    /// 未知單詞方案(如未來新增)亦 fail-closed 不顯示標籤——額度 % 仍正常(標籤只是裝飾)。
    static func sanitizedPlanType(_ raw: String?) -> String? {
        guard let raw, (1...16).contains(raw.count) else { return nil }
        let letters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return raw.allSatisfy { letters.contains($0) } ? raw : nil
    }

    /// resetsAt 合理性界(防惡意/壞 epoch:如 1e20 → 巨大 Date → 下游 `Int(interval)` trap 崩潰,
    /// xcheck r2 sol MAJOR)。只接受「觀測時刻附近」的重置:[observedAt − 2 天, observedAt + 30 天]
    /// (遠寬於 5h/週窗 + clock skew)。超出 → nil(窗仍可用,只是無重置時刻),絕不崩潰。
    static func saneResetsAt(_ date: Date?, observedAt: Date) -> Date? {
        guard let date else { return nil }
        let lower = observedAt.addingTimeInterval(-2 * 86400)
        let upper = observedAt.addingTimeInterval(30 * 86400)
        return (date >= lower && date <= upper) ? date : nil
    }

    /// 把 app-server 的 `result` 物件 bytes 窄解碼成 codex `RateLimitReading`。
    /// 窗型分類**重用** `CodexAdapter.classifyWindows`(以 windowMinutes 精確歸位:300→5h、10080→週;
    /// 未知窗長 fail-closed 忽略)。usedPercent 保持 **USED** 語義(不做 100−x 反轉),且須為 finite ∧
    /// 落在 [0,100] 才採納——超範圍/NaN 視為壞資料丟棄該窗(fail-closed,不以無效值覆蓋有效的 Source A)。
    static func decode(resultJSON: Data, providerId: String = "codex", observedAt: Date) -> DecodeOutcome {
        guard let decoded = try? JSONDecoder().decode(RateLimitsResult.self, from: resultJSON) else {
            return .malformed
        }
        guard let rl = decoded.rateLimits else { return .malformed }

        // present-but-unusable → **整筆** fail-soft(.ok([])),不發半筆。理由(xcheck r3 grok/luna/sol):
        // 一個「在原始回應中出現」的窗若 percent 非法、或窗長非已知(300/10080),windowReading/classify
        // 會把它變成 nil 槽;若另一窗合法,半筆(例 5h 槽 nil + weekly 槽有值)會被引擎的 codex 規則誤判為
        // 「5h 被撤回」而 tombstone 5h(= 把壞資料變成權威性的 absence),違反 per-window fallback。真實 B
        // 恆雙窗合法(watchdog 330/330),故 present-but-bad 是異常訊號 → 整筆作廢、回退 Source A(fail soft)。
        // 真正「缺席」(該窗在回應中 nil)仍合法(合法單窗由下游 per-window 處理;grok:勿改弱引擎規則)。
        func usable(_ w: RateLimitsResult.Window?) -> Bool {
            guard let w else { return true }   // 窗缺席:合法
            guard let pct = w.usedPercent, pct.isFinite, pct >= 0, pct <= 100 else { return false }
            return w.windowDurationMins == 300 || w.windowDurationMins == 10080
        }
        guard usable(rl.primary), usable(rl.secondary) else { return .ok([]) }

        func windowReading(_ w: RateLimitsResult.Window?) -> RateLimitWindowReading? {
            guard let w, let percent = w.usedPercent else { return nil }   // present 者已過 usable 驗證
            return RateLimitWindowReading(usedPercent: percent,
                                          windowMinutes: w.windowDurationMins ?? 0,
                                          resetsAt: saneResetsAt(w.resetsAt?.date, observedAt: observedAt))
        }
        let (fiveHour, weekly) = CodexAdapter.classifyWindows(windowReading(rl.primary),
                                                              windowReading(rl.secondary))
        let reading = RateLimitReading(providerId: providerId, observedAt: observedAt,
                                       primary: fiveHour, secondary: weekly,
                                       planType: sanitizedPlanType(rl.planType), sourcePath: nil)
        // 至少一窗可分類、或仍帶合法 plan → 發 reading(plan-only 保留方案標籤);皆無 → 空(fail-soft)。
        if reading.primary != nil || reading.secondary != nil || reading.planType != nil {
            return .ok([reading])
        }
        return .ok([])
    }

    // MARK: - transport(可注入;production = ProcessTransport,測試 = fake)

    /// 回傳 `account/rateLimits/read` 的 `result` 物件 bytes;任何失敗(spawn 失敗/逾時/早退/
    /// 壞 JSON-RPC/無 result/超限)都 **throw**(呼叫端 fail-soft)。
    public protocol Transport: Sendable {
        func fetchRateLimitsResult(timeout: TimeInterval) throws -> Data
    }

    public enum TransportError: Error, Equatable {
        case binaryNotFound
        case launchFailed
        case timeoutOrNoResult
        case rpcError
        case responseTooLarge
    }

    /// 單行 JSON-RPC 訊息(已解析為物件)→ 對 `account/rateLimits/read`(id==2)回應的判斷。純函數,
    /// 可測(transport 的 reader 用它;把此前只存在於 reader 內、unit 無法覆蓋的 envelope 邏輯抽出 ——
    /// jsonrpc gate 迴歸正因 reader 解析無 unit 覆蓋才溜到 runtime 才發現)。
    /// id≠2 → ignore;id==2 ∧ 無非-null error ∧ 帶可序列化 result → result(result bytes);否則 → rpcError。
    enum LineOutcome: Equatable { case ignore; case result(Data); case rpcError }
    static func classifyLine(_ obj: [String: Any]) -> LineOutcome {
        guard (obj["id"] as? Int) == 2 else { return .ignore }
        let hasError = obj["error"] != nil && !(obj["error"] is NSNull)
        if !hasError, let result = obj["result"], let rd = try? JSONSerialization.data(withJSONObject: result) {
            return .result(rd)
        }
        return .rpcError
    }

    /// fail-soft 取數:transport 失敗或解碼 malformed → 回空陣列(**絕不造 0%**)。
    /// observedAt 在 transport **回傳後**蓋章(= 讀值真正取得的時刻),確保它恆為最新、
    /// 不被抓取期間落地的其他(較舊)觀測搶先而變 inert。
    public static func fetchReadings(transport: Transport, timeout: TimeInterval) -> [RateLimitReading] {
        guard let data = try? transport.fetchRateLimitsResult(timeout: timeout) else { return [] }
        switch decode(resultJSON: data, observedAt: Date()) {
        case .ok(let readings): return readings
        case .malformed: return []
        }
    }

    // MARK: - binary discovery(packaged GUI app 的 PATH 極簡,不能靠裸 PATH)

    /// 依序尋找已安裝的 `codex` 執行檔。GUI app(Finder/LaunchAgent 啟動)拿到的是極簡 PATH,
    /// 無法靠裸 PATH 找到,故搜**固定絕對路徑**(PATH-independent,無子程序、無 hang 風險)。
    /// 找不到 → nil(呼叫端 fail-soft,不視為錯誤)。非標準安裝位置未命中亦 fail-soft。
    /// `globalPaths` 預設為系統級固定位置;可注入(測試傳 `[]` 以 hermetic 驗證「找不到」,不受
    /// 測試主機是否剛好裝了全域 codex 影響;xcheck r2 sol MINOR)。
    public static func discoverCodexBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        globalPaths: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                              URL(fileURLWithPath: "/usr/local/bin/codex")]
    ) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        // 明確覆寫(測試/進階使用者):CODEX_BIN 指向執行檔本身。
        if let bin = env["CODEX_BIN"], bin.hasPrefix("/") { candidates.append(URL(fileURLWithPath: bin)) }
        // CODEX_HOME(= 資料目錄,如 ~/.codex)下的 standalone 安裝。
        let codexHome = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        candidates.append(codexHome.appendingPathComponent("packages/standalone/current/bin/codex"))
        candidates.append(home.appendingPathComponent(".local/bin/codex"))
        candidates.append(contentsOf: globalPaths)
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    // MARK: - fetch gate(owner guardrails:debounce/coalesce + single-flight + ~60s 最小間隔)

    /// 純值 gate:把 owner 的 guardrail 做成可測決策核心(app 層驅動只執行決策、持 `var gate`)。
    /// **所有**觸發(startup/FSEvents/300s safety-net/手動 ⌘R)一律受單流 + ~60s 最小間隔雙閘——
    /// owner 契約「B 實際 spawn 不得超過 ~每 60s 一次」不給手動例外。時間用**單調時鐘**(systemUptime)
    /// 的秒數,不用 wall-clock(避免系統時鐘回跳導致長時間誤 skip、或前跳導致提早 spawn)。
    public struct FetchGate: Equatable, Sendable {
        /// 上次抓取完成的單調時刻(秒;來源 = `ProcessInfo.processInfo.systemUptime`)。
        public var lastFetchAt: TimeInterval?
        public var inFlight: Bool
        public let minInterval: TimeInterval

        public init(minInterval: TimeInterval = 60, lastFetchAt: TimeInterval? = nil, inFlight: Bool = false) {
            self.minInterval = minInterval
            self.lastFetchAt = lastFetchAt
            self.inFlight = inFlight
        }

        public enum Decision: Equatable, Sendable {
            case proceed
            case skipInFlight       // 已有一次抓取進行中(單流)→ 合併,不重複 spawn
            case skipMinInterval    // 距上次抓取未滿 minInterval → 防 spawn storm(含手動)
        }

        /// 這一次請求可否真正 spawn。`now` = 單調 uptime 秒。
        public func decide(now: TimeInterval) -> Decision {
            if inFlight { return .skipInFlight }
            if let last = lastFetchAt, now - last < minInterval { return .skipMinInterval }
            return .proceed
        }

        /// proceed 後呼叫:標記進行中(呼叫端隨即 async 抓取)。
        public mutating func begin() { inFlight = true }

        /// 抓取結束(成功或失敗)呼叫:解除單流並記錄本次抓取的單調時刻(min-interval 自此起算)。
        public mutating func finish(at: TimeInterval) { inFlight = false; lastFetchAt = at }
    }

    // MARK: - ProcessTransport(spawn codex app-server;stdio JSON-RPC;bounded;確定性 teardown)

    /// production transport:spawn `codex app-server`,走 watchdog 驗證過的握手
    /// (`initialize` → `initialized` → `account/rateLimits/read`),bounded timeout,
    /// 確定性清理:close-stdin → terminate →(≤3s)→ SIGKILL → reap,並 **join 讀取緒**後才回傳
    /// (讀取緒退出後 pipe 由 ARC 釋放;teardown 不手動 close 讀端,避免與 `availableData` 競態丟
    /// NSFileHandleOperationException)。stderr 直接丟到 /dev/null(我方不讀 → 不會因 stderr 寫滿
    /// pipe buffer 而讓健康的 server 卡死逾時)。累積上限 maxResponseBytes 防惡意/壞 child 耗記憶體。
    /// 註:codex app-server 經 watchdog 證實為**單一 stdio 程序**(無 daemon / 無 control socket),
    /// 故對 pid 的 terminate+kill+reap 即確定性清理;不另設 process group(Foundation Process 不便設定)。
    public struct ProcessTransport: Transport {
        let binary: URL
        let clientName: String
        let clientVersion: String

        public init(binary: URL, clientName: String = "ai-pet-usage",
                    clientVersion: String = AppVersionInfo.current.displayVersion ?? "0") {
            self.binary = binary
            self.clientName = clientName
            self.clientVersion = clientVersion
        }

        public func fetchRateLimitsResult(timeout: TimeInterval) throws -> Data {
            let proc = Process()
            proc.executableURL = binary
            proc.arguments = ["app-server"]
            let inPipe = Pipe(); let outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice   // 丟棄 stderr:我方不讀 → 不會因 stderr 滿而死鎖
            do { try proc.run() } catch { throw TransportError.launchFailed }

            // JSON-RPC 三行(watchdog 驗證序列)。clientName/version 經 JSON 轉義。
            let ver = Self.jsonEscaped(clientVersion)
            let name = Self.jsonEscaped(clientName)
            let lines = [
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"\(name)\",\"version\":\"\(ver)\"}}}\n",
                "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}\n",
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}\n",
            ]
            for line in lines { try? inPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8)) }

            // 背景讀 stdout 的 NDJSON,找 id==2 的 result;sem = 結果信號、readerDone = 讀取緒已退出(join)。
            let box = ResultBox()
            let sem = DispatchSemaphore(value: 0)
            let readerDone = DispatchSemaphore(value: 0)
            DispatchQueue(label: "codex-appserver-read").async {
                defer { readerDone.signal() }   // join 點:讀取緒退出必發
                var buffer = Data()
                var totalRead = 0
                let handle = outPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData   // teardown terminate/kill → EOF(空)解除阻塞
                    if chunk.isEmpty { break }
                    totalRead += chunk.count
                    if totalRead > CodexAppServerLimits.maxResponseBytes {   // **累計**上限(非僅當前 buffer)
                        box.overflow = true; sem.signal(); return
                    }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            switch CodexAppServerLimits.classifyLine(obj) {
                            case .ignore: break   // 非 id==2(init 回應/通知等)→ 續讀
                            case .result(let rd): box.data = rd; sem.signal(); return
                            case .rpcError: box.rpcError = true; sem.signal(); return
                            }
                        }
                    }
                }
                sem.signal()   // EOF 未見 id==2
            }

            let waited = sem.wait(timeout: .now() + timeout)

            // 確定性 teardown(任何離開路徑都走這裡一次):close stdin → terminate → kill → reap → join reader。
            try? inPipe.fileHandleForWriting.close()
            if proc.isRunning { proc.terminate() }
            // **單調**時鐘的 kill 寬限(wall-clock 回跳不得無限延長 SIGKILL;xcheck r2 sol/luna MAJOR)。
            let killDeadline = ProcessInfo.processInfo.systemUptime + 3
            while proc.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { usleep(50_000) }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()                       // reap:避免 zombie
            _ = readerDone.wait(timeout: .now() + 3)   // join:程序已死 → stdout EOF → 讀取緒退出;之後 ARC 釋放 pipe
            // 不手動 close outPipe 讀端:讀取緒已退出,ARC 釋放即關閉,避免與 availableData 競態。

            guard waited == .success else { throw TransportError.timeoutOrNoResult }
            if box.overflow { throw TransportError.responseTooLarge }
            if box.rpcError { throw TransportError.rpcError }
            guard let data = box.data else { throw TransportError.timeoutOrNoResult }
            return data
        }

        /// 只轉義會破壞上面手組 JSON 的字元(version/name 幾乎恆為 ascii;防禦性)。
        static func jsonEscaped(_ s: String) -> String {
            var out = ""
            for ch in s.unicodeScalars {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
                }
            }
            return out
        }

        /// 跨執行緒傳遞讀取結果的小盒子(sem/readerDone barrier 保證可見性)。
        final class ResultBox: @unchecked Sendable {
            var data: Data?
            var rpcError = false
            var overflow = false
        }
    }
}
