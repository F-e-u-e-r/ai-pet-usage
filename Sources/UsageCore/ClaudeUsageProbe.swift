import Foundation
import Darwin

/// Claude Code 額度的 **`/usage` 探針**(statusline 的備援來源)。
///
/// 為何需要:Claude desktop 的 session **從不呼叫** statusLine 指令(實測 2026-11-16:探針記錄
/// 整段 desktop session 0 次呼叫;終端機 `claude` 每則訊息都呼叫)。只用 desktop 時
/// `claude-statusline.json` 會停在幾小時前,meter 顯示的是舊值。
///
/// 做法(與 Codex app-server 同精神:問 CLI,不碰登入憑證):
///   - 在隱藏的 pseudo-terminal 裡跑 `claude /usage`(cwd = home 底下專用的空目錄,沿用 home 的信任),讀畫面文字後確定性拆除。
///   - **不讀 Keychain、不抽 token、不打 API**;`/usage` 是本機指令,不發模型請求(實測 session 檔
///     只有 local_command 紀錄、無 assistant/usage)。
///   - 解析結果寫成與 hook 相同 schema 的落地檔 `claude-usage-probe.json`,由
///     `ClaudeCodeAdapter` 既有的「各窗取最新 captured_at」邏輯併入;另含 Fable 等 model-scoped 週窗
///     (statusline payload 沒有這欄)。
///   - fail-soft:找不到 claude / 未登入 / 信任提示 / 畫面格式變了 / 逾時 → 不寫檔(絕不造 0%)。
///
/// 已知副作用(owner 2026-11-16 知悉):每次探針會啟動一個 Claude Code session —— 觸發使用者的
/// SessionStart hook 與 statusline hook,並在 `~/.claude/projects/<探針工作目錄>/` 留一個小 session 檔。
/// 故只在 statusline 讀數陳舊時才跑,且受最小間隔閘限制。
public enum ClaudeUsageProbe {

    public static let landingFileName = "claude-usage-probe.json"

    public static func landingURL() -> URL {
        AppPaths.dataDirectory().appendingPathComponent(landingFileName)
    }

    /// statusline / 探針讀數多舊才跑探針。
    public static let staleAfter: TimeInterval = 5 * 60
    /// 兩次探針的最小間隔(單調時鐘;含手動)。
    public static let minInterval: TimeInterval = 5 * 60

    // MARK: - 解析結果

    public struct Window: Equatable, Sendable {
        public var usedPercent: Double
        public var resetsAt: Date?
        public init(usedPercent: Double, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public struct ScopedWindow: Equatable, Sendable {
        public var displayName: String
        public var window: Window
        public init(displayName: String, window: Window) {
            self.displayName = displayName
            self.window = window
        }
    }

    public struct Parsed: Equatable, Sendable {
        public var session: Window?
        public var week: Window?
        public var scoped: [ScopedWindow]
        public init(session: Window?, week: Window?, scoped: [ScopedWindow]) {
            self.session = session
            self.week = week
            self.scoped = scoped
        }
    }

    // MARK: - 畫面文字還原

    /// 把 PTY 原始輸出還原成可解析的純文字。Claude Code 以游標定位(`ESC[nG` / `ESC[nC`)代替空白,
    /// 直接剝除會把字黏在一起("45%used"),故這兩種一律換成一個空白;其餘 CSI / OSC / 字元集切換剝除。
    public static func renderText(_ data: Data) -> String {
        let s = String(decoding: data, as: UTF8.self)
        var out = String.UnicodeScalarView()
        var it = Array(s.unicodeScalars)[...]
        while let c = it.first {
            it = it.dropFirst()
            guard c == "\u{1B}" else {
                if c == "\r" { out.append("\n") } else { out.append(c) }
                continue
            }
            guard let next = it.first else { break }
            if next == "[" {                         // CSI:參數直到 final byte(0x40–0x7E)
                it = it.dropFirst()
                var final: Unicode.Scalar?
                while let p = it.first {
                    it = it.dropFirst()
                    if (0x40...0x7E).contains(p.value) { final = p; break }
                }
                if final == "G" || final == "C" { out.append(" ") }
                // 換列類(CUP H/f、CUD B、CNL E、VPA d):剝除會把兩列黏成一列(標題被吃進上一列)。
                else if let f = final, "HfBEd".unicodeScalars.contains(f) { out.append("\n") }
            } else if next == "]" || next == "P" {   // OSC / DCS:直到 BEL 或 ST(ESC \)
                it = it.dropFirst()
                while let p = it.first {
                    it = it.dropFirst()
                    if p == "\u{07}" { break }
                    if p == "\u{1B}" { if it.first == "\\" { it = it.dropFirst() }; break }
                }
            } else if next == "(" || next == ")" {   // 字元集:ESC ( X
                it = it.dropFirst()
                if !it.isEmpty { it = it.dropFirst() }
            } else {                                 // 其他雙字元序列(ESC = / ESC > …)
                it = it.dropFirst()
            }
        }
        return String(out)
    }

    // MARK: - 解析

    /// 從還原後的畫面文字解析額度。只看**最後一份**完整畫面(從最後一個 "Current session" 起),
    /// 因為累積輸出裡較早的畫面可能是快取值(畫面上 "Refreshing…" 之前)。
    /// 5h 與週窗都缺 → nil(不造值)。
    public static func parse(screen: String, now: Date) -> Parsed? {
        guard let start = screen.range(of: "Current session", options: .backwards) else { return nil }
        let lines = screen[start.lowerBound...]
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }

        struct Section { var title: String; var percent: Double?; var reset: Date? }
        var sections: [Section] = []
        // 段落只收**緊接在標題下**的「N% used」與「Resets …」列;遇到任何其他非空列(未知段落標題如
        // "Extra usage"、"Loading…")即關閉,避免別段的數字/重置時間被算進前一段(造值)。
        var open = false
        for line in lines {
            if line.hasPrefix("Current session") || line.hasPrefix("Current week") {
                sections.append(Section(title: line))
                open = true
                continue
            }
            guard open, !line.isEmpty else { continue }
            if sections[sections.count - 1].percent == nil, let p = usedPercent(in: line) {
                sections[sections.count - 1].percent = p
            } else if sections[sections.count - 1].reset == nil, line.hasPrefix("Resets") {
                sections[sections.count - 1].reset = parseReset(line, now: now)
            } else {
                open = false
            }
        }

        var result = Parsed(session: nil, week: nil, scoped: [])
        for s in sections {
            guard let p = s.percent else { continue }
            let w = Window(usedPercent: p, resetsAt: s.reset)
            if s.title.hasPrefix("Current session") {
                if result.session == nil { result.session = w }
            } else if let name = parenthesized(s.title) {
                if name.lowercased() == "all models" {
                    if result.week == nil { result.week = w }
                } else if !result.scoped.contains(where: { $0.displayName.lowercased() == name.lowercased() }) {
                    result.scoped.append(ScopedWindow(displayName: name, window: w))
                }
            }
        }
        guard result.session != nil || result.week != nil else { return nil }
        return result
    }

    /// "████ 45% used" → 45。只收有限、0…1000 的值(>100 理論上可能,負值/NaN 拒收)。
    /// 數字前不得緊接數字/逗號/點/負號("1,234% used" 不可讀成 234,"-5% used" 不可讀成 5)。
    static func usedPercent(in line: String) -> Double? {
        guard let r = line.range(of: #"(?<![\d.,\-])(\d+(?:\.\d+)?)\s*%\s*used"#, options: .regularExpression) else { return nil }
        let digits = line[r].prefix { $0.isNumber || $0 == "." }
        guard let v = Double(digits), v.isFinite, v >= 0, v <= 1000 else { return nil }
        return v
    }

    static func parenthesized(_ title: String) -> String? {
        guard let open = title.firstIndex(of: "("), let close = title.lastIndex(of: ")"), open < close else { return nil }
        let name = title[title.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// "Resets 11:59am (Asia/Tokyo)" / "Resets Nov 20 at 7am (Asia/Tokyo)" → Date。
    /// 時區無法辨識(畫面被截斷,如 "Asia/Toky")或格式不符 → nil(重置時間可缺,不猜)。
    static func parseReset(_ line: String, now: Date) -> Date? {
        let pattern = #"Resets\s+(?:([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: line) else { return nil }
            return String(line[r])
        }
        guard let tzName = group(6), let tz = TimeZone(identifier: tzName),
              let hour12 = group(3).flatMap(Int.init), (1...12).contains(hour12),
              let ampm = group(5) else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else { return nil }
        let hour = (hour12 % 12) + (ampm == "pm" ? 12 : 0)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0

        // 夏令時間結束時同一牆上時刻出現兩次;回撥幅度取自時區偏移差(紐約 1h、Lord Howe 30m)。
        // 已過的分鐘仍算未過(畫面只到分鐘)。回傳該日的所有出現時刻,先到者在前。
        func occurrences(_ c: DateComponents) -> [Date] {
            guard let first = cal.date(from: c) else { return [] }
            // 26h 視窗涵蓋任何 ≤ 1 天的回撥(含換日線式回撥,如 1969 Kwajalein 23h);
            // 第二次必須落在同一天同一時分,否則只是視窗內另一天的回撥。
            let back = tz.secondsFromGMT(for: first) - tz.secondsFromGMT(for: first.addingTimeInterval(26 * 3600))
            let second = first.addingTimeInterval(TimeInterval(back))
            let wall: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
            guard back > 0, cal.dateComponents(wall, from: second) == cal.dateComponents(wall, from: first) else { return [first] }
            return [first, second]
        }
        func upcoming(_ occ: [Date]) -> Date? { occ.first { $0.addingTimeInterval(60) > now } ?? occ.last }

        if let mon = group(1), let day = group(2).flatMap(Int.init) {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            guard let mi = months.firstIndex(of: mon), (1...31).contains(day), let year = comps.year else { return nil }
            // 畫面不帶年份:取前一年/今年/明年中離 now 最近者(Dec 30 看到 "Jan 2" → 明年;
            // Jan 1 看到剛過的 "Dec 31" → 去年)。不存在的日期("Nov 31")→ nil,不滾成下個月。
            let candidates = [year - 1, year, year + 1].compactMap { y -> Date? in
                var c = comps
                c.year = y
                c.month = mi + 1
                c.day = day
                let occ = occurrences(c)
                guard let d = occ.first,
                      cal.component(.month, from: d) == mi + 1, cal.component(.day, from: d) == day else { return nil }
                return upcoming(occ)
            }
            return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
        }
        // 只有時刻 → 昨天/今天/明天所有出現時刻中最早尚未過去者。畫面只到分鐘,顯示的那一分鐘內仍算未過
        // (11:59:05 看到 "11:59am" 是馬上重置,不是 24h 後)。明天由牆上時刻重建,不由今天 +1 天
        // (春令跳過的 2:30 今天被挪成 3:30,明天仍是 2:30);昨天涵蓋跨午夜回撥(2010 Casey)。
        // 春令空檔裡的時刻(紐約 3/8 的 2:30)會被 cal.date 挪成 3:30;沒有任何瞬間顯示成 2:30,故只收牆上時分相符者。
        let all = (-1...1).flatMap { d -> [Date] in
            var c = comps
            c.day = comps.day.map { $0 + d }
            return occurrences(c)
        }
        return all.filter {
            cal.component(.hour, from: $0) == hour && cal.component(.minute, from: $0) == minute
                && $0.addingTimeInterval(60) > now
        }.min()
    }

    // MARK: - 落地檔(與 hook 同 schema)

    public static func landingJSON(_ p: Parsed, capturedAt: Date) -> Data? {
        func win(_ w: Window) -> [String: Any] {
            var o: [String: Any] = ["used_percentage": w.usedPercent]
            if let r = w.resetsAt { o["resets_at"] = Int(r.timeIntervalSince1970.rounded()) }
            return o
        }
        var rl: [String: Any] = [:]
        if let s = p.session { rl["five_hour"] = win(s) }
        if let w = p.week { rl["seven_day"] = win(w) }
        var out: [String: Any] = [
            "schema_version": 1,
            "source": "usage-probe",
            "captured_at": isoUTC(capturedAt),
            "rate_limits": rl,
        ]
        if !p.scoped.isEmpty {
            out["model_scoped"] = p.scoped.map { s -> [String: Any] in
                var o = win(s.window)
                o["display_name"] = s.displayName
                return o
            }
        }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    public static func writeLanding(_ p: Parsed, capturedAt: Date, to url: URL) throws {
        guard let data = landingJSON(p, capturedAt: capturedAt) else { throw JSONCodecError.notADictionary }
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        // 暫存檔一建立就是 0600 再 rename 上去:最終路徑任何時刻都不會是 umask 預設權限(0644)。
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        do {
            // open 的 mode 會被 umask 遮(umask 0400 → 0200,adapter 讀不回);fchmod 不受 umask 影響。
            guard fchmod(fd, 0o600) == 0 else { throw posixError() }
            try data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw posixError() }
                    off += n
                }
            }
            guard fsync(fd) == 0 else { throw posixError() }
            let closed = close(fd)
            fd = -1                                  // close 失敗也不可再 close(fd 號碼可能已被重用)
            guard closed == 0 else { throw posixError() }
            guard rename(temp, url.path) == 0 else { throw posixError() }
        } catch {
            if fd >= 0 { close(fd) }
            unlink(temp)
            throw error
        }
    }

    static func isoUTC(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// 各 statusline 來源的讀數時間,與 `ClaudeCodeAdapter` 同規則:`captured_at`,缺鍵才退檔案 mtime
    /// (第三方工具寫的 `~/.claude/usage-status.json` 是官方 payload 原文,沒有 captured_at)。
    /// 缺檔 / 壞檔 / rate_limits 裡沒有任何可用的 5h/週窗百分比 → nil(空殼不能證明新鮮)。
    public static func freshnessStamps(of urls: [URL]) -> [Date?] {
        urls.map { url in
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let limits = obj["rate_limits"] as? [String: Any],
                  ["five_hour", "seven_day"].contains(where: { key in
                      guard let w = limits[key] as? [String: Any] else { return false }
                      return (w["used_percentage"] ?? w["used_percent"]) is NSNumber
                  }) else { return nil }
            if let s = obj["captured_at"] as? String, let d = ISO8601.parse(s) { return d }
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        }
    }

    /// 只有在**所有**來源(statusline hook 與上一次探針)都陳舊或缺檔時才探。
    /// 未來時間戳(時鐘漂移/竄改)視為不可信 → 不能拿來證明新鮮。
    public static func shouldProbe(capturedAts: [Date?], now: Date, staleAfter: TimeInterval = staleAfter) -> Bool {
        let trusted = capturedAts.compactMap { $0 }.filter { $0 <= now.addingTimeInterval(60) }
        guard let newest = trusted.max() else { return true }
        return now.timeIntervalSince(newest) >= staleAfter
    }

    // MARK: - 找 claude

    public static func discoverClaudeBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        var candidates: [URL] = []
        if let bin = env["CLAUDE_BIN"], bin.hasPrefix("/") { candidates.append(URL(fileURLWithPath: bin)) }
        candidates.append(home.appendingPathComponent(".local/bin/claude"))
        candidates.append(home.appendingPathComponent(".claude/local/claude"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/claude"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - 取消把手(stop / quit 時殺掉整個探針程序群組)

    /// `AppModel.stop()` 持有並呼叫 `cancel()`:同步 SIGKILL 探針的整個程序群組(claude 與它帶起的
    /// hook / MCP 子程序),並讓擷取迴圈立即結束、不寫檔。app 結束時不等背景 task 收尾也不留孤兒。
    public final class ProbeHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var pgid: pid_t = 0
        private var cancelled = false

        public init() {}

        public var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        public func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if pgid > 0 { kill(-pgid, SIGKILL) }
        }

        /// 在鎖內 spawn 並登記群組:`cancel()` 不可能落在「已 spawn、未登記」的空檔(quit 漏殺)。
        /// 已取消 → 不 spawn,回 nil。
        func register(_ spawn: () -> pid_t?) -> pid_t? {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled, let pid = spawn() else { return nil }
            pgid = pid
            return pid
        }

        /// 在鎖內執行最後的寫檔:`cancel()` 回傳後不可能再寫;寫到一半時 cancel 會等它寫完。
        func commitUnlessCancelled(_ body: () -> Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            return body()
        }

        /// 必須在 reap 群組 leader **之前**呼叫:leader 未被 reap 前 pgid 不會被系統重用。
        func detach() {
            lock.lock(); defer { lock.unlock() }
            pgid = 0
        }
    }

    // MARK: - PTY 擷取

    /// TIOCSWINSZ = _IOW('t', 103, struct winsize)(巨集無法匯入 Swift)。
    private static let TIOCSWINSZ_: UInt = 0x8008_7467

    /// 在隱藏 PTY 跑 `claude /usage`,回傳**確認已更新完成**的完整畫面文字;任何失敗 / 逾時 / 取消 → nil。
    ///
    /// 時序(實測):乾淨環境下數字約 3s 出現(先是快取值),畫面顯示 "Refreshing…" 向伺服器更新,
    /// 之後只重繪變動字元。串流本身無法判斷 "Refreshing…" 是否還在畫面上,故以**完整重繪**為準:
    /// 數字出現 1s 後調整視窗大小 + SIGWINCH 逼出整頁重繪,收滿 1s 後檢查這一窗 —— 連續兩窗都完整、
    /// 都不含 Refreshing、解析相同才接受,否則再逼一次;逾時仍未完成 → nil(絕不把快取值當新值)。
    /// 前提:重繪反映當下狀態(Ink 全頁重繪;2026-11-16 實測重繪頁含最新數字)。
    ///
    /// 程序:以 posix_spawn 開**新 session**(自己的程序群組 + PTY 為 controlling tty),拆除時對整個群組 SIGTERM → 續讀 0.5s → close master
    /// → 最多等 1.5s → 群組 SIGKILL(忽略 TERM 的 hook 子孫也清掉)→ reap。
    /// 同 `captureScreen`,另回傳**接受該頁的時刻**:解析與 `captured_at` 都用它(拆除要 2s,
    /// 拆除後才取 `Date()` 會讓「顯示那一分鐘」的 Resets 滾到明天)。
    static func capture(binary: URL, home: URL, timeout: TimeInterval = 20,
                        handle: ProbeHandle? = nil,
                        parentEnv: [String: String] = ProcessInfo.processInfo.environment) -> (page: String, at: Date)? {
        if handle?.isCancelled == true { return nil }
        var master: Int32 = -1
        var slave: Int32 = -1
        var ws = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        let workDir = probeWorkDirectory(home: home)
        guard (try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)) != nil else { return nil }
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else { return nil }
        let env = probeEnvironment(binary: binary, home: home, parent: parentEnv)
        let spawn = { spawnInOwnGroup(binary: binary, arguments: ["/usage"], env: env, cwd: workDir, tty: slave) }
        guard let pid = handle.map({ $0.register(spawn) }) ?? spawn() else {
            close(master); close(slave)
            return nil
        }
        close(slave)                               // 父程序不留 slave,子程序結束時 master 才會收到 EOF/EIO

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)

        func pump(for seconds: TimeInterval) -> Bool {   // false = EOF/錯誤
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(0, min(seconds, 0.2)) * 1000)
            let r = poll(&pfd, 1, ms)
            if r < 0 { return errno == EINTR }           // 訊號中斷不是 EOF
            if r == 0 { return true }
            let n = read(master, &chunk, chunk.count)
            if n < 0 { return errno == EINTR || errno == EAGAIN }
            if n == 0 { return false }
            buffer.append(contentsOf: chunk[0..<n])
            return true
        }

        let bufferCap = 4 * 1024 * 1024
        let percentUsedPattern = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?\s*%\s*used"#)
        func screenHasPercentUsed(_ text: String) -> Bool {
            guard let re = percentUsedPattern else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

        var result: (page: String, at: Date)?
        do {
            let start = uptime()
            var numbersAt: TimeInterval?
            var nextRedrawAt: TimeInterval?
            var redrawSentAt: TimeInterval?
            var scannedUpTo = 0
            var redrawStart = 0
            var bigger = false
            var lastGood: Parsed?
            var alive = true
            while alive, uptime() - start < timeout, handle?.isCancelled != true {
                alive = pump(for: 0.1)
                if buffer.count > bufferCap { break }
                let wallNow = Date()
                let mono = uptime()
                if numbersAt == nil {
                    // 只掃新到的位元組,往回接到上一個換行(同一行的 "5" 與 "% used" 之間可夾任意長的色碼,
                    // 固定重疊會漏);最多回退 64 KiB,不換行的洪水仍是線性。每次都重繪整個 buffer 是 O(N²)。
                    var from = scannedUpTo
                    let floor = max(0, scannedUpTo - 65_536)
                    while from > floor, buffer[from - 1] != 0x0A { from -= 1 }
                    scannedUpTo = buffer.count
                    if screenHasPercentUsed(renderText(buffer.subdata(in: from..<buffer.count))) {
                        numbersAt = mono
                        nextRedrawAt = mono + 1.0
                    }
                    continue
                }
                if let sent = redrawSentAt {
                    // 每次重繪後收滿 1s 的所有輸出再判斷(不靠「靜止」:spinner 會一直送位元組,
                    // 而停頓中的片段看起來也像靜止)。要求**連續兩個**視窗都含完整重繪、都不含
                    // Refreshing、解析結果相同才接受。
                    guard mono - sent >= 1.0 else { continue }
                    redrawSentAt = nil
                    let page = renderText(buffer.subdata(in: redrawStart..<buffer.count))
                    // 視窗裡恰好一個 "Current session":多出來的是重繪後的差異幀,會蓋掉乾淨的整頁。
                    if page.components(separatedBy: "Current session").count == 2, !page.contains("Refreshing"),
                       let parsed = parse(screen: page, now: wallNow) {
                        if let prev = lastGood, prev == parsed {
                            result = (page, wallNow)
                            break
                        }
                        lastGood = parsed
                    } else {
                        lastGood = nil
                    }
                    nextRedrawAt = mono
                    continue
                }
                if let t = nextRedrawAt, mono >= t {
                    bigger.toggle()                              // 每次換尺寸,確保真的觸發重繪
                    var size = bigger ? winsize(ws_row: 52, ws_col: 150, ws_xpixel: 0, ws_ypixel: 0)
                                      : winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
                    _ = ioctl(master, TIOCSWINSZ_, &size)
                    kill(-pid, SIGWINCH)                      // wrapper 腳本時 UI 可能在子程序
                    redrawStart = buffer.count
                    redrawSentAt = mono
                    nextRedrawAt = nil
                }
            }
        }

        // 拆除(整個群組)
        kill(-pid, SIGTERM)
        let drainUntil = uptime() + 0.5
        // 上限也管拆除:狂吐的子程序 0.5s 內可再灌 ~100 MiB(實測)。超過就不再讀,直接 close master。
        while uptime() < drainUntil, buffer.count <= bufferCap, pump(for: 0.1) {}
        close(master)
        let killAt = uptime() + 1.5
        while !hasExited(pid), uptime() < killAt { usleep(50_000) }
        kill(-pid, SIGKILL)                        // leader 尚未 reap → pgid 不會被重用;清掉忽略 TERM 的子孫
        handle?.detach()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}

        return handle?.isCancelled == true ? nil : result
    }

    /// 回傳畫面文字(相容舊呼叫端與測試)。
    public static func captureScreen(binary: URL, home: URL, timeout: TimeInterval = 20,
                                     handle: ProbeHandle? = nil,
                                     parentEnv: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        capture(binary: binary, home: home, timeout: timeout, handle: handle, parentEnv: parentEnv)?.page
    }

    /// leader 是否已結束(不 reap:WNOWAIT)。
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return true }
        return info.si_pid != 0
    }

    /// posix_spawn:新 session(pgid == pid)、PTY slave 為 controlling tty 並接 stdin/out/err、cwd、
    /// 其餘 fd 一律不繼承、訊號處置重設為預設。
    static func spawnInOwnGroup(binary: URL, arguments: [String], env: [String: String],
                                cwd: URL, tty: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }

        // 以路徑重開 slave:SETSID 的 session leader 開啟終端機即取得 controlling tty,
        // app 當掉 / 被強制結束(stop() 沒跑)時 master 關閉 → 核心對前景群組送 SIGHUP,不留孤兒。
        guard let name = ttyname(tty) else { return nil }
        guard posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, 0, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, 0, 2) == 0 else { return nil }
        guard posix_spawn_file_actions_addchdir_np(&actions, cwd.path) == 0 else { return nil }

        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGWINCH, SIGCHLD, SIGALRM,
                    SIGUSR1, SIGUSR2, SIGTSTP, SIGTTIN, SIGTTOU] { sigaddset(&defaults, sig) }
        var noMask = sigset_t()
        sigemptyset(&noMask)
        guard posix_spawnattr_setsigdefault(&attr, &defaults) == 0,
              posix_spawnattr_setsigmask(&attr, &noMask) == 0,
              posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF |
                                                    POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { return nil }

        let argv: [UnsafeMutablePointer<CChar>?] = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, binary.path, &actions, &attr, argv, envp) == 0 else { return nil }
        return pid
    }

    /// 探針子程序的 cwd:home 底下專用的空目錄,不是 home 本身。cwd = home 時 Claude Code 啟動會掃 home,
    /// macOS 把它碰到的 Documents / Desktop / 照片 / 其他 app 資料記在**本 app** 名下 → 一連串不相干的權限提示
    /// (owner 2026-11-17 回報)。放在 home 底下 → 沿用 home 的信任,不會停在信任提示(實測)。
    static func probeWorkDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(AppPaths.appFolderName, isDirectory: true)
            .appendingPathComponent("claude-probe", isDirectory: true)
    }

    /// 乾淨環境:不繼承呼叫端的 CLAUDE_* / ANTHROPIC_*(在 Claude Code 子程序內執行時會被當成子 session,
    /// 或改走別的 base URL)—— 唯一例外是 `CLAUDE_CONFIG_DIR`:adapter 依它讀使用者選的設定/帳號,
    /// 探針必須查同一個帳號。強制英文 locale,解析器只認英文字串。
    static func probeEnvironment(binary: URL, home: URL,
                                 parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [
            "HOME": home.path,
            "PATH": [binary.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SHELL", "CLAUDE_CONFIG_DIR"] {
            if let v = parent[key] { env[key] = v }
        }
        return env
    }

    /// 端到端:擷取 → 解析 → 寫落地檔。回傳是否寫入。取消 → 不寫。
    @discardableResult
    public static func runOnce(binary: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               landing: URL = landingURL(), handle: ProbeHandle? = nil) -> Bool {
        guard let shot = capture(binary: binary, home: home, handle: handle),
              let parsed = parse(screen: shot.page, now: shot.at) else { return false }
        let write = { (try? writeLanding(parsed, capturedAt: shot.at, to: landing)) != nil }
        return handle.map { $0.commitUnlessCancelled(write) } ?? write()
    }
}
