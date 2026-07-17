import Foundation

/// `aipet install-hook`:把內嵌的 statusline hook 落地到資料目錄,並把
/// `<configDir>/settings.json` 的 `statusLine` 接上。
///
/// 設計契約(經 grok-4.5 + gpt-5.6-sol 多輪審定;2026-07-17 owner 決策簡化):
/// - 純 planner(無 IO,`Probe` 注入檔案系統事實)+ 薄 runner(全部 IO)。
/// - **只做兩件事**:fresh install(statusLine 未設/空 → 設成本 hook),或
///   **包裹「單一可執行 script 路徑」**(絕對路徑,或 ~/ 展開後為絕對路徑的既存檔)。
///   複合指令 / bare / 相對路徑 / 路徑不存在 → **一律拒絕並給手動指引**,絕不解析或
///   切割使用者的指令、絕不代寫 shim。這一刀消掉了「把任意指令搬進 shim 再管理該
///   shim 的健康/自我引用」整個 edge class(11 輪 review 的主要缺陷來源)。
/// - 冪等:只認「本安裝器產生的 canonical 形式(F1 fresh / F2 wrapPath / F3 bash--)
///   + type=="command"」為已安裝;任何其他 `claude-statusline-hook.sh` 引用一律拒絕。
/// - 變更 settings 前:單一 O_NOFOLLOW 快照同時餵 planner 與提交比對;提交前重讀比對,
///   不同即中止(此前零寫入)。比對→rename 的殘餘競態為已揭露限制(提醒關閉 Claude Code)。
/// - settings.json 是 symlink/非 regular → settings 變更動作一律拒絕(dotfiles 手動改);
///   alreadyInstalled 仍可原子刷新我方 hook 檔。
/// - 新建的每個檔(settings/backup/hook)寫入時清除繼承的擴充 ACL 並強制 0600/0700
///   (fchmod 不清 ACL:繼承的 allow-read 會讓「0600」settings 變 everyone 可讀;
///   deny-read 會讓安裝靜默壞掉;codex code-r11 #1)。
public enum InstallHook {

    // MARK: - 純 planner

    public struct Probe {
        public let settingsData: Data?          // 規劃用位元組(symlink 已跟隨);nil = 檔案不存在
        public let home: String                 // 真實家目錄(getpwuid 系),非 $HOME
        public let isRegularFile: (String) -> Bool   // 跟隨 symlink 後為 regular file(目錄/裝置/FIFO → false)
        public let isExecutable: (String) -> Bool

        public init(settingsData: Data?, home: String,
                    isRegularFile: @escaping (String) -> Bool,
                    isExecutable: @escaping (String) -> Bool) {
            self.settingsData = settingsData
            self.home = home
            self.isRegularFile = isRegularFile
            self.isExecutable = isExecutable
        }
    }

    public enum Action: Equatable {
        case installFresh
        case wrapPath(String)                   // 絕對路徑、存在且可執行
        case wrapBashDashDash(String)           // 絕對路徑、存在但不可執行
        case alreadyInstalled(kind: CanonicalKind)
        case refuse(reason: String)
    }

    public enum CanonicalKind: Equatable {
        case fresh                              // F1
        case wrapPath(String)                   // F2
        case wrapBashDashDash(String)           // F3
    }

    public struct Plan {
        public let action: Action
        /// settings 變更動作才有值:整份新 settings.json 的位元組(pretty + sortedKeys)。
        public let newSettingsJSON: Data?
        /// 變更後的 statusLine.command(顯示用)。
        public let newCommand: String?
        /// 被取代的舊 command(顯示用;可能為 nil)。
        public let oldCommand: String?
    }

    /// POSIX 單引號包裹:' → '\''。所有嵌入 command 字串的路徑一律經過這裡。
    public static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 本安裝器產生的 command 前綴(runner 擁有 hookPath 的引號;planner 不再引一次)。
    public static func hookInvocationPrefix(hookPath: String) -> String {
        "/bin/bash \(shellSingleQuote(hookPath))"
    }

    /// 嚴格解析「本安裝器 quoting 格式」的單一 token:整段必須恰為 '<…>'(內部僅允許
    /// '\'' 跳脫),回傳未引號的原字串;不符回 nil。用於辨識 F2/F3 的 target。
    static func unquoteSingle(_ s: String) -> String? {
        guard s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 else { return nil }
        let inner = String(s.dropFirst().dropLast())
        var out = ""
        var rest = Substring(inner)
        while let r = rest.range(of: "'\\''") {
            let before = rest[..<r.lowerBound]
            guard !before.contains("'") else { return nil }
            out += before + "'"
            rest = rest[r.upperBound...]
        }
        guard !rest.contains("'") else { return nil }
        out += rest
        return out
    }

    static let hookFileName = "claude-statusline-hook.sh"
    static let simplePathPattern = "^[A-Za-z0-9_/.~+-]+$"

    // 自我引用守衛一律大小寫不敏感:macOS 預設 APFS case-insensitive,大小寫變體是同一
    // inode(grok code-r10 #1)。hook basename 含固定尾碼,對任何變體 fail-closed 皆安全。
    static func containsCI(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    /// 指令不是「我們能安全包裹的單一 script 路徑」時的拒絕文案(附手動指引;不解析指令)。
    /// 不含 "install-hook:" 前綴 —— runner 的 refuse 出口會統一加上。
    static func refuseNotSimpleScript(_ shown: String) -> String {
        // shown 是使用者指令(不可信)→ esc();模板本身的換行是結構性的,保留(finish
        // 會保留 \n)。整段 reason 不再由 runner 二次 esc(否則結構換行會變 \x0A)。
        """
        your statusLine command was left unchanged — it is not a single script file this
        installer can wrap automatically (it looks like a compound command, has arguments, is a relative/
        bare path, or points at a missing/non-file target):
          \(esc(shown))
        Options:
          • Point statusLine.command at an ABSOLUTE path to your script (e.g. /Users/you/.claude/statusline.sh)
            or a ~/ path, then re-run install-hook.
          • Or wrap it yourself — see the README's "--wrap" section for the manual form.
          • Or remove the statusLine block from settings.json and re-run to install the AI Pet Usage hook fresh.
        """
    }

    public static func plan(probe: Probe, hookPath: String) -> Plan {
        let prefix = hookInvocationPrefix(hookPath: hookPath)

        func refuse(_ reason: String) -> Plan {
            Plan(action: .refuse(reason: reason), newSettingsJSON: nil, newCommand: nil, oldCommand: nil)
        }

        var root: [String: Any] = [:]
        if let data = probe.settingsData {
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                return refuse("settings.json is not valid JSON — fix or remove it, then re-run (nothing was changed)")
            }
            guard let dict = obj as? [String: Any] else {
                return refuse("settings.json top level is not an object — not touching it")
            }
            root = dict
        }

        let statusLineRaw = root["statusLine"]
        var statusLine: [String: Any] = [:]

        if let raw = statusLineRaw {
            guard let dict = raw as? [String: Any] else {
                return refuse("settings.json statusLine is not an object — not touching it")
            }
            statusLine = dict
            let typeRaw = dict["type"]
            let typeValue = typeRaw as? String
            if typeRaw != nil && typeValue == nil {
                return refuse("statusLine.type is not a string — not touching it")
            }
            let commandRaw = dict["command"]
            let command = commandRaw as? String
            if commandRaw != nil && command == nil {
                return refuse("statusLine.command is not a string — not touching it")
            }
            // trimmed 只判「空 ⇒ 視同未設定」;canonical 比對/守衛/分類都用 raw(byte-exact)。
            let raw = command ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmed.isEmpty {
                // canonical 辨識要先於 type 檢查,讓「是我們的但 type 不對」拿到精確訊息。
                if let kind = classifyCanonical(raw, prefix: prefix, hookPath: hookPath) {
                    if dict["type"] as? String == "command" {
                        return Plan(action: .alreadyInstalled(kind: kind), newSettingsJSON: nil,
                                    newCommand: nil, oldCommand: command)
                    }
                    return refuse("statusLine.command is this installer's, but statusLine.type is \(typeValue.map { "\"\(esc($0))\"" } ?? "missing") instead of \"command\" — set it to \"command\" (or remove statusLine and re-run)")
                }
                if let typeValue, typeValue != "command" {
                    return refuse("statusLine.type is \"\(esc(typeValue))\" (not \"command\") — not touching a non-command statusLine")
                }
                if containsCI(raw, hookFileName) {
                    return refuse("statusLine already references a \(hookFileName) not managed by this installer (manual install?) — not touching it")
                }
            } else if let typeValue, typeValue != "command" {
                return refuse("statusLine.type is \"\(esc(typeValue))\" (not \"command\") — not touching a non-command statusLine")
            }

            if trimmed.isEmpty {
                return freshPlan(root: root, statusLine: statusLine, prefix: prefix, oldCommand: nil)
            }

            // 既有指令:只接受「單一 script 路徑」;其餘一律拒絕(不解析、不搬 shim)。
            let original = raw
            if original.range(of: simplePathPattern, options: .regularExpression) != nil {
                var candidate = original
                if candidate == "~" || candidate.hasPrefix("~/") {
                    candidate = probe.home + String(candidate.dropFirst(1))
                }
                if candidate.hasPrefix("/") {   // 只認絕對路徑(bare/相對不吃安裝當下 CWD)
                    // (指向 hook 本身的引用已由上面的 containsCI(hookFileName) 守衛拒絕。)
                    // 必須是 regular file:目錄 / /dev/null 之類 fileExists 也為真,但包了
                    // 會產生壞 statusline(hook 去 exec 一個目錄/裝置;grok code-r12 #1)。
                    if probe.isRegularFile(candidate) {
                        if probe.isExecutable(candidate) {
                            return wrapPlan(root: root, statusLine: statusLine, prefix: prefix,
                                            action: .wrapPath(candidate),
                                            command: "\(prefix) --wrap \(shellSingleQuote(candidate))",
                                            oldCommand: original)
                        }
                        return wrapPlan(root: root, statusLine: statusLine, prefix: prefix,
                                        action: .wrapBashDashDash(candidate),
                                        command: "\(prefix) --wrap /bin/bash -- \(shellSingleQuote(candidate))",
                                        oldCommand: original)
                    }
                }
            }
            // 複合指令 / bare / 相對 / ~user / 路徑不存在 → 拒絕(附指引)。
            return refuse(refuseNotSimpleScript(original))
        }

        // statusLine 完全不存在。
        return freshPlan(root: root, statusLine: [:], prefix: prefix, oldCommand: nil)
    }

    /// 辨識三種 canonical 形式(byte-exact,不 trim)。target 必須是「本安裝器可能產生的
    /// 形狀」:絕對路徑、且不是任何 claude-statusline-hook.sh(self-wrap/外部 hook 都不認)
    /// —— 不符者一律 nil → 落到 filename-refuse(fail-closed)。
    /// 刻意不檢查 target 目前存在/可執行:那是安裝後可合法改變的狀態。
    static func classifyCanonical(_ command: String, prefix: String, hookPath: String) -> CanonicalKind? {
        func validTarget(_ t: String) -> Bool {
            t.hasPrefix("/") && !containsCI(t, hookFileName)
        }
        if command == prefix { return .fresh }
        let wrapPrefix = prefix + " --wrap "
        guard command.hasPrefix(wrapPrefix) else { return nil }
        let rest = String(command.dropFirst(wrapPrefix.count))
        let bashPrefix = "/bin/bash -- "
        if rest.hasPrefix(bashPrefix) {
            guard let target = unquoteSingle(String(rest.dropFirst(bashPrefix.count))),
                  validTarget(target) else { return nil }
            return .wrapBashDashDash(target)
        }
        guard let target = unquoteSingle(rest), validTarget(target) else { return nil }
        return .wrapPath(target)
    }

    static func emitSettings(root: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func freshPlan(root: [String: Any], statusLine: [String: Any],
                          prefix: String, oldCommand: String?) -> Plan {
        var sl = statusLine
        sl["type"] = "command"
        sl["command"] = prefix
        var newRoot = root
        newRoot["statusLine"] = sl
        return Plan(action: .installFresh, newSettingsJSON: emitSettings(root: newRoot),
                    newCommand: prefix, oldCommand: oldCommand)
    }

    static func wrapPlan(root: [String: Any], statusLine: [String: Any], prefix: String,
                         action: Action, command: String, oldCommand: String?) -> Plan {
        var sl = statusLine
        sl["type"] = "command"
        sl["command"] = command
        var newRoot = root
        newRoot["statusLine"] = sl
        return Plan(action: action, newSettingsJSON: emitSettings(root: newRoot),
                    newCommand: command, oldCommand: oldCommand)
    }

    // MARK: - Runner(IO)

    public struct RunResult {
        public let output: String
        public let exitCode: Int32
    }

    /// 顯示層控制字元跳脫:保留 \n(多行格式),其餘 C0/0x7f → \xNN。runner 全部輸出經
    /// finish() 單一出口套用。
    static func escapeForDisplay(_ s: String) -> String {
        s.unicodeScalars.map { scalar in
            if scalar.value == 0x0a { return "\n" }
            if scalar.value < 0x20 || scalar.value == 0x7f {
                return String(format: "\\x%02X", scalar.value)
            }
            return String(scalar)
        }.joined()
    }

    /// 欄位級跳脫:C0 全部含 LF。不可信內容(路徑/指令/refuse 原因)插進輸出行前必經,
    /// 否則欄位內 LF 會偽造輸出行(finish() 保留結構性 \n;grok code-r2 #2)。
    static func esc(_ s: String) -> String {
        s.unicodeScalars.map { scalar in
            if scalar.value < 0x20 || scalar.value == 0x7f {
                return String(format: "\\x%02X", scalar.value)
            }
            return String(scalar)
        }.joined()
    }

    static func finish(_ output: String, _ code: Int32) -> RunResult {
        RunResult(output: escapeForDisplay(output), exitCode: code)
    }

    /// 清除 fd 所指檔的擴充 ACL(fchmod 不清 ACL;繼承的 allow/deny ACL 會讓 0600/0700
    /// 名不副實 —— codex code-r11 #1)。清完驗證確實無擴充 ACL;清不掉 → false(呼叫端中止)。
    /// FS 不支援 ACL(ENOTSUP)視為「本就沒有」→ true。
    static func clearExtendedACL(_ fd: Int32) -> Bool {
        guard let empty = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) != 0 {
            // 只有「FS 不支援 ACL」才視為「本就無 ACL、OK」。acl_set_fd_np(3) 記載
            // 不支援時回 EOPNOTSUPP(Darwin 上 102);ENOTSUP(45)是不同值,兩者都接受
            // 以求可攜(grok code-r13 #1 實測 45≠102,原本只認 ENOTSUP 會讓不支援 ACL 的
            // 磁碟區安裝失敗)。EINVAL 等其他 errno 是真失敗 → fail-closed。
            return errno == EOPNOTSUPP || errno == ENOTSUP
        }
        // 驗證:必須「確實沒有 extended ACL」。acl_get 回非 nil = 還有 ACL → 失敗;
        // 回 nil 也必須是 errno==ENOENT(無此 ACL);其他 errno = 讀取出錯 → 失敗(不 fail-open)。
        errno = 0
        if let remaining = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(remaining))
            return false
        }
        return errno == ENOENT
    }

    /// acl_get_fd_np 回 nil 時,errno 是否代表「本就沒有可查的擴充 ACL」(而非查詢失敗)。
    /// 三種良性:ENOENT(此檔無 ACL)、EOPNOTSUPP/ENOTSUP(FS 根本不支援 ACL —— 與
    /// clearExtendedACL 的 set 端「不支援即無 ACL」同一套)。其餘(EACCES/EINVAL/EBADF…)=
    /// 真查詢失敗 → 呼叫端須 fail closed。此分類歷經 r12b/r13/r15/r16 逐輪修補,抽成純函式集中
    /// 釘死:codex code-r16 #1 —— EOPNOTSUPP 被當失敗會讓不支援 ACL 的磁碟區每次都重寫、破壞冪等。
    public static func aclAbsentErrno(_ e: Int32) -> Bool {
        return e == ENOENT || e == EOPNOTSUPP || e == ENOTSUP
    }

    enum NoFollowRead {
        case missing
        case notRegular
        case bytes(Data)
    }

    /// O_NOFOLLOW + O_NONBLOCK(FIFO 不掛死)開檔 + fstat 必須 regular,回傳全部位元組。
    static func readNoFollow(_ path: String) -> NoFollowRead {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return .missing }
            return .notRegular
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return .notRegular }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                return .notRegular
            }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return .bytes(data)
    }

    /// 位元組全寫(EINTR-safe)。成功 true。
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var ok = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var written = 0
            while written < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    ok = false; return
                }
                if n == 0 { ok = false; return }
                written += n
            }
        }
        return ok
    }

    /// 獨佔建立(O_EXCL 作用在最終檔名,絕不 rename 蓋檔)—— 給備份用。
    enum ExclusiveCreate { case created, exists, failed }
    static func createExclusive(_ data: Data, at path: String, mode: mode_t) -> ExclusiveCreate {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        if fd < 0 { return errno == EEXIST ? .exists : .failed }
        var ok = fchmod(fd, mode) == 0 && clearExtendedACL(fd)   // umask 免疫 + 清繼承 ACL
        if ok { ok = writeAll(fd, data) }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        if !ok { unlink(path); return .failed }
        return .created
    }

    /// 原子寫檔:同目錄 tmp(O_CREAT|O_EXCL|O_NOFOLLOW)→ fchmod + 清 ACL → 全寫 →
    /// fsync → rename。
    static func writeAtomic(_ data: Data, to path: String, mode: mode_t) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/.aipet-install-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0..<UInt32.max)).tmp"
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        guard fd >= 0 else { return false }
        var ok = fchmod(fd, mode) == 0 && clearExtendedACL(fd)
        if ok { ok = writeAll(fd, data) }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        if !ok { unlink(tmp); return false }
        if rename(tmp, path) != 0 { unlink(tmp); return false }
        return true
    }

    /// 主流程。`configDir`/`dataDir`/`home` 由 CLI 注入(測試可全隔離);`now` 可注入固定時鐘。
    public static func run(configDir: String, dataDir: String, home: String, dryRun: Bool,
                           now: Date = Date()) -> RunResult {
        var out: [String] = []
        let settingsPath = configDir + "/settings.json"
        let hookPath = dataDir + "/" + hookFileName
        let fm = FileManager.default

        // lstat:只有 ENOENT 算不存在;其他錯誤(configDir 是普通檔 → ENOTDIR)一律拒絕。
        var lst = stat()
        let lstatRC = lstat(settingsPath, &lst)
        if lstatRC != 0 && errno != ENOENT {
            return finish("install-hook: cannot inspect \(esc(settingsPath)) (\(String(cString: strerror(errno)))) — fix the path and re-run", 2)
        }
        let settingsIsRegular = lstatRC == 0 && (lst.st_mode & S_IFMT) == S_IFREG
        let settingsExists = lstatRC == 0

        // 單一 O_NOFOLLOW 快照同時餵 planner 與提交比對(grok code-r1 #1)。
        var planBytes: Data?
        var captured: Data?
        if settingsIsRegular {
            switch readNoFollow(settingsPath) {
            case .bytes(let d):
                planBytes = d
                captured = d
            default:
                return finish("settings.json exists but could not be read — not touching it", 2)
            }
        } else if settingsExists {
            var fst = stat()
            guard stat(settingsPath, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG else {
                return finish("settings.json exists but is not a regular file (or a link to one) — not touching it", 2)
            }
            guard let data = fm.contents(atPath: settingsPath) else {
                return finish("settings.json exists but could not be read — not touching it", 2)
            }
            planBytes = data
        }

        let probe = Probe(settingsData: planBytes, home: home,
                          isRegularFile: { path in   // 跟隨 symlink(stat)後必須是 regular file
                              var st = stat()
                              return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
                          },
                          isExecutable: { fm.isExecutableFile(atPath: $0) })
        var plan = InstallHook.plan(probe: probe, hookPath: hookPath)

        // wrap 目標若(經 symlink/hardlink 等別名解析後)其實就是我方 hook → 改為拒絕:
        // planner 的檔名字串守衛抓不到「外名 symlink → hook」;包了等於 wrap 我方 hook 自己
        //(symlink 會 runtime exit 2、hardlink 則以 standalone 跑、exit 0 多跑一次 —— 見 code-r17
        // 實測),安裝卻回報成功(codex code-r12b #2)。用 dev+ino 身份比對(比字串/realpath
        // 穩健);hook 尚未落地時無從撞名,天然安全。
        func sameFileAsHook(_ target: String) -> Bool {
            var t = stat(), h = stat()
            return stat(target, &t) == 0 && stat(hookPath, &h) == 0
                && t.st_dev == h.st_dev && t.st_ino == h.st_ino
        }
        switch plan.action {
        case .wrapPath(let t), .wrapBashDashDash(let t):
            if sameFileAsHook(t) {
                // 只陳述無歧義的事實(target 就是我方 hook、非使用者自己的腳本)+ 復原指引,
                // 不宣稱 runtime 後果 —— symlink 會 exit 2、hardlink 卻 exit 0 正常顯示,任何單一
                // 後果描述都會對其一失真(grok/codex code-r17 P3;與 .alreadyInstalled 訊息一致)。
                plan = Plan(action: .refuse(reason: "your statusLine points (via a link) at the AI Pet Usage hook itself, not a script of your own. Point statusLine at your own script, or remove it to install fresh."),
                            newSettingsJSON: nil, newCommand: nil, oldCommand: nil)
            }
        default: break
        }

        // 單一 O_NOFOLLOW fd 檢查 hook:regular + mode 0700 + 內容一致 + **無擴充 ACL**。
        // ACL 也要查:內容/mode 正確但帶 `everyone allow write` 之類的 hook,只查前兩者
        // 會被當「up to date」而略過 —— 但 clearExtendedACL 只在(重)寫時跑,ACL 永不清
        // (codex code-r14 #2)。任一不符 → 需重寫(writeAtomic 會清 ACL)。
        func hookNeedsRepair() -> Bool {
            let fd = open(hookPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return true }   // 缺失/symlink/不可讀 → (重)建
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  (st.st_mode & 0o777) == 0o700 else { return true }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 { if errno == EINTR { continue }; return true }
                if n == 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            if data != StatuslineHookScript.content { return true }
            // acl_get_fd_np 回 nil 多義:ENOENT/EOPNOTSUPP/ENOTSUP = 本就無(可查的)ACL;其餘
            // errno = 真查詢失敗(例如帶 `deny readsecurity` 的 ACL 連自己都讀不到,回 EACCES)。
            // 後者不能當「無 ACL」放過,否則帶敵意 ACL 的 hook 既偵測不到也清不掉 → fail closed 當
            // 需重寫(codex code-r15 #2);但 EOPNOTSUPP/ENOTSUP 不能當失敗,否則不支援 ACL 的
            // 磁碟區會每次都重寫、破壞冪等(codex code-r16 #1)。分類集中在 aclAbsentErrno。
            let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
            let aclErrno = errno
            if let a = acl { acl_free(UnsafeMutableRawPointer(a)); return true }   // 有擴充 ACL → 重寫清除
            if !aclAbsentErrno(aclErrno) { return true }                          // 真查詢失敗 → fail closed
            return false
        }

        switch plan.action {
        case .refuse(let reason):
            return finish("install-hook: \(reason)", 2)

        case .alreadyInstalled(let kind):
            // 已安裝的 canonical wrap target(F2/F3)也要跑自我引用身份比對:別名(symlink/
            // hardlink)解析到我方 hook 時,其 wrap target 其實是我方 hook 而非使用者腳本
            //(symlink 會 runtime exit 2、hardlink 則以 standalone 跑、exit 0 多跑一次),
            // installer 卻回報「nothing to change」(codex code-r14 #1)。
            let wrapTarget: String? = {
                switch kind {
                case .wrapPath(let t), .wrapBashDashDash(let t): return t
                case .fresh: return nil
                }
            }()
            // 只陳述無歧義的事實(wrap target 就是我方 hook、非使用者自己的腳本)+ 復原指引,
            // 不宣稱 runtime 後果:symlink 會 exit 2(realpath 護欄)、hardlink 卻 exit 0 正常顯示
            // (realpath 抓不到、內層 standalone 跑),任何單一後果詞(breaks/loop/invalid/redundant)
            // 都會對其一失真(grok + codex code-r17 P3 —— 兩訊息同一措辭)。
            let selfWrap = "your statusLine's wrap target resolves (via a link) to the AI Pet Usage hook itself, not a script of your own. Point statusLine at your own script, or remove it to install fresh."
            // 修復「前」先驗:hardlink 到現行 hook inode 者此刻同 inode → 抓得到;writeAtomic 的
            // tmp+rename 會把 hookPath 換成新 inode,只在修復後驗會漏掉 hardlink(codex code-r15
            // #1 實測重現:ACL 觸發修復後 exit 0)。只 stat,不寫入 → dry-run 亦安全。
            if let t = wrapTarget, sameFileAsHook(t) {
                return finish("install-hook: \(selfWrap)", 2)
            }
            let repairs = hookNeedsRepair()
            if dryRun {
                // 修復前比對已做;剩下的盲點只有「hook 當下缺失的 dangling symlink」——dry-run
                // 不落地故無從解析,但真跑會在寫檔後攔下(見下方)。不退回字串/realpath 比對以免
                // 重蹈 F4-shim 的逐別名軸脆弱性。
                out.append("already installed (command: \(esc(plan.oldCommand ?? "")))")
                out.append(repairs ? "dry-run: would refresh the hook (\(esc(hookPath)))" : "dry-run: hook is up to date")
                return finish(out.joined(separator: "\n"), 0)
            }
            try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            if repairs {
                guard writeAtomic(StatuslineHookScript.content, to: hookPath, mode: 0o700) else {
                    return finish("install-hook: failed to refresh \(esc(hookPath))", 2)
                }
                out.append("hook refreshed: \(esc(hookPath))")
            }
            // 修復「後」再驗一次:先前 dangling 的 symlink 要等 hook 落地才解析得到(hook-missing
            // repair 競態);hardlink 已在修復前攔下,此處補 symlink。
            if let t = wrapTarget, sameFileAsHook(t) {
                return finish("install-hook: the hook is installed, but \(selfWrap)", 2)
            }
            out.append("already installed (command: \(esc(plan.oldCommand ?? ""))) — nothing to change")
            return finish(out.joined(separator: "\n"), 0)

        case .installFresh, .wrapPath, .wrapBashDashDash:
            // settings 變更:symlink / 非 regular 一律拒絕(dry-run 亦然,先於任何輸出)。
            if settingsExists && !settingsIsRegular {
                return finish("install-hook: settings.json is a symlink or special file (dotfiles-managed?) — edit it manually; the command to set is:\n  \(esc(plan.newCommand ?? ""))", 2)
            }
            guard let newJSON = plan.newSettingsJSON else {
                return finish("install-hook: internal error — no settings payload", 2)
            }
            if dryRun {
                out.append("dry-run — nothing written. Planned changes:")
                if let old = plan.oldCommand { out.append("  old command: \(esc(old))") }
                out.append("  new command: \(esc(plan.newCommand ?? ""))")
                out.append("  would write: \(esc(hookPath)) (0700)")
                out.append(captured != nil
                    ? "  would back up settings.json first (timestamped, 0600)"
                    : "  settings.json does not exist — it would be created (no backup needed)")
                return finish(out.joined(separator: "\n"), 0)
            }

            // 提交前重讀比對(型別/位元組任一變化即中止,此前零寫入)。
            switch (readNoFollow(settingsPath), captured) {
            case (.missing, nil): break
            case (.bytes(let cur), .some(let was)) where cur == was: break
            default:
                return finish("install-hook: settings.json changed while planning — close Claude Code and re-run (nothing was changed)", 2)
            }

            // ---- 寫入開始(比對→rename 之間的競態為已揭露殘餘;建議關閉 Claude Code)----
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            if hookNeedsRepair() {
                guard writeAtomic(StatuslineHookScript.content, to: hookPath, mode: 0o700) else {
                    return finish("install-hook: failed to write \(esc(hookPath))", 2)
                }
            }

            var backupPath: String?
            if let was = captured {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd-HHmmss"
                df.locale = Locale(identifier: "en_US_POSIX")
                let base = settingsPath + ".aipet-backup-" + df.string(from: now)
                var target = base
                var n = 2
                creating: while true {
                    switch createExclusive(was, at: target, mode: 0o600) {
                    case .created: break creating
                    case .exists:
                        guard n <= 9 else {
                            return finish("install-hook: too many same-second backups — aborting before touching settings.json", 2)
                        }
                        target = base + "-\(n)"
                        n += 1
                    case .failed:
                        return finish("install-hook: could not create settings backup — aborting before touching settings.json", 2)
                    }
                }
                backupPath = target
            }

            guard writeAtomic(newJSON, to: settingsPath, mode: 0o600) else {
                return finish("install-hook: failed to write settings.json (the hook file was written and is inert)\(backupPath.map { "; your backup: \(esc($0))" } ?? "")", 2)
            }

            switch plan.action {
            case .installFresh: out.append("installed: statusLine now runs the AI Pet Usage hook")
            case .wrapPath, .wrapBashDashDash: out.append("installed: your existing statusline is now wrapped (its output/exit are unchanged)")
            default: break
            }
            if let old = plan.oldCommand { out.append("old command: \(esc(old))") }
            out.append("new command: \(esc(plan.newCommand ?? ""))")
            if let backupPath {
                out.append("backup: \(esc(backupPath))")
                out.append("revert: mv \(esc(shellSingleQuote(backupPath))) \(esc(shellSingleQuote(settingsPath)))  # overwrites any later Claude Code edits")
            } else {
                out.append("settings.json did not exist before — to revert, remove the statusLine key (or delete settings.json if you added nothing else)")
            }
            out.append("done — restart Claude Code (or trigger a statusline refresh) to activate; keep Claude Code closed while installing")
            return finish(out.joined(separator: "\n"), 0)
        }
    }
}
