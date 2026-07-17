import Foundation
import UsageCore

/// `aipet install-hook` 的 planner(純函數)與 runner(temp-dir 隔離)測試。
/// 2026-07-17 owner 決策後:只做 fresh install + 包裹單一 script 路徑;複合/bare/相對/
/// 不存在 → 拒絕(不搬 shim)。新建檔清除繼承 ACL。
final class InstallHookTests: XCTestCase {

    // MARK: helpers

    private let hookPath = "/data dir/claude-statusline-hook.sh"
    private var prefix: String { InstallHook.hookInvocationPrefix(hookPath: hookPath) }

    private func planOf(_ json: String?, home: String = "/Users/t",
                        regular: @escaping (String) -> Bool = { _ in false },
                        exec: @escaping (String) -> Bool = { _ in false }) -> InstallHook.Plan {
        let probe = InstallHook.Probe(settingsData: json.map { Data($0.utf8) }, home: home,
                                      isRegularFile: regular, isExecutable: exec)
        return InstallHook.plan(probe: probe, hookPath: hookPath)
    }

    private func assertRefused(_ plan: InstallHook.Plan, contains needle: String,
                               file: StaticString = #file, line: UInt = #line) {
        if case .refuse(let reason) = plan.action {
            XCTAssertTrue(reason.contains(needle), "reason=\(reason)", file: file, line: line)
            XCTAssertNil(plan.newSettingsJSON, "refuse 不得產生 settings payload", file: file, line: line)
        } else {
            XCTAssertTrue(false, "expected refuse, got \(plan.action)", file: file, line: line)
        }
    }

    private func plainTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aipet-ih-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mode(_ path: String) -> Int {
        var st = stat()
        guard lstat(path, &st) == 0 else { return -1 }
        return Int(st.st_mode & 0o777)
    }

    private struct Shell { let stdout: String; let stderr: String; let status: Int32 }
    @discardableResult
    private func runShell(_ command: String, stdin: String? = nil, env: [String: String] = [:]) throws -> Shell {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", command]
        var e = ProcessInfo.processInfo.environment
        e.removeValue(forKey: "AIPET_STATUSLINE_HOOK_ACTIVE")
        for (k, v) in env { e[k] = v }
        p.environment = e
        let inP = Pipe(); let outP = Pipe(); let errP = Pipe()
        p.standardInput = inP; p.standardOutput = outP; p.standardError = errP
        try p.run()
        if let stdin { inP.fileHandleForWriting.write(Data(stdin.utf8)) }
        inP.fileHandleForWriting.closeFile()
        let o = outP.fileHandleForReading.readDataToEndOfFile()
        let er = errP.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Shell(stdout: String(decoding: o, as: UTF8.self),
                     stderr: String(decoding: er, as: UTF8.self), status: p.terminationStatus)
    }

    /// 檔案是否帶擴充 ACL(用 /bin/ls -le;ACL 條目以 " N: " 起頭)。
    private func hasExtendedACL(_ path: String) -> Bool {
        guard let out = try? runShell("/bin/ls -le \(InstallHook.shellSingleQuote(path))").stdout else { return false }
        return out.split(separator: "\n").contains { $0.range(of: "^ [0-9]+: ", options: .regularExpression) != nil }
    }

    // MARK: planner — quoting / fresh / refuse

    func testShellSingleQuote() throws {
        XCTAssertEqual(InstallHook.shellSingleQuote("a b"), "'a b'")
        XCTAssertEqual(InstallHook.shellSingleQuote("it's"), "'it'\\''s'")
        for s in ["plain", "a  b", "it's", "x'y'z", "$HOME `id` \"q\""] {
            let out = try runShell("/bin/echo " + InstallHook.shellSingleQuote(s))
            XCTAssertEqual(out.stdout, s + "\n", s)
        }
    }

    func testFreshVariants() throws {
        for json in [nil, "{}", #"{"statusLine":{}}"#, #"{"statusLine":{"command":""}}"#,
                     #"{"statusLine":{"command":"   "}}"#] {
            let plan = planOf(json)
            XCTAssertEqual(plan.action, .installFresh, json ?? "nil")
            XCTAssertEqual(plan.newCommand, prefix)
        }
        let plan = planOf(#"{"model":"opus","statusLine":{"padding":0},"permissions":{"allow":["x"]}}"#)
        let root = try JSONSerialization.jsonObject(with: plan.newSettingsJSON!) as! [String: Any]
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual((root["permissions"] as? [String: Any])?["allow"] as? [String], ["x"])
        let sl = root["statusLine"] as! [String: Any]
        XCTAssertEqual(sl["padding"] as? Int, 0)
        XCTAssertEqual(sl["type"] as? String, "command")
        XCTAssertEqual(sl["command"] as? String, prefix)
    }

    func testRefusals() throws {
        assertRefused(planOf("not json {"), contains: "not valid JSON")
        assertRefused(planOf("[1,2]"), contains: "top level is not an object")
        assertRefused(planOf(#"{"statusLine":"x"}"#), contains: "statusLine is not an object")
        assertRefused(planOf(#"{"statusLine":{"type":"static","command":"x"}}"#), contains: "not \"command\"")
        assertRefused(planOf(#"{"statusLine":{"type":"static"}}"#), contains: "not \"command\"")
        assertRefused(planOf(#"{"statusLine":{"type":5,"command":"x"}}"#), contains: "type is not a string")
        assertRefused(planOf(#"{"statusLine":{"command":[1]}}"#), contains: "command is not a string")
        assertRefused(planOf(#"{"statusLine":{"type":"command","command":"/bin/bash /repo/Scripts/claude-statusline-hook.sh"}}"#),
                      contains: "not managed by this installer")
        // 大小寫變體的 hook 引用也要拒絕(case-insensitive FS;grok code-r10)
        assertRefused(planOf(#"{"statusLine":{"type":"command","command":"/x/CLAUDE-STATUSLINE-HOOK.SH"}}"#),
                      contains: "not managed by this installer")
    }

    // MARK: planner — 只包裹單一 script 路徑;其餘拒絕

    func testWrapSimpleScriptPath() throws {
        let simple = "/Users/t/bin/status.sh"
        let p1 = planOf(#"{"statusLine":{"type":"command","command":"\#(simple)"}}"#,
                        regular: { $0 == simple }, exec: { $0 == simple })
        XCTAssertEqual(p1.action, .wrapPath(simple))
        XCTAssertEqual(p1.newCommand, "\(prefix) --wrap '\(simple)'")
        let p2 = planOf(#"{"statusLine":{"type":"command","command":"\#(simple)"}}"#,
                        regular: { $0 == simple }, exec: { _ in false })
        XCTAssertEqual(p2.action, .wrapBashDashDash(simple))
        XCTAssertEqual(p2.newCommand, "\(prefix) --wrap /bin/bash -- '\(simple)'")
    }

    func testTildeExpansion() throws {
        let plan = planOf(#"{"statusLine":{"type":"command","command":"~/bin/st.sh"}}"#,
                          regular: { $0 == "/Users/t/bin/st.sh" }, exec: { $0 == "/Users/t/bin/st.sh" })
        XCTAssertEqual(plan.action, .wrapPath("/Users/t/bin/st.sh"))
    }

    func testDirectoryOrSpecialTargetRefused() throws {
        // 目錄 / 非 regular(/dev/null 之類)即使 exists 為真也不得包裹(grok code-r12 #1)。
        // planOf 的 isRegularFile 預設回 false → 模擬「存在但非 regular」;斷言拒絕。
        let dir = "/Users/t/somedir"
        assertRefused(planOf(#"{"statusLine":{"type":"command","command":"\#(dir)"}}"#,
                             regular: { _ in false }, exec: { _ in true }),
                      contains: "single script file")
        // runner e2e:真的把 statusLine 指向一個目錄 → 拒絕、settings 不動
        let root = plainTempDir()
        let cfg = root.appendingPathComponent("cfg").path
        let data = root.appendingPathComponent("data").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        let targetDir = root.appendingPathComponent("iamdir").path
        try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        let before = try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": targetDir]])
        try before.write(to: URL(fileURLWithPath: cfg + "/settings.json"))
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 2, "目錄 target 必須拒絕:\(r.output)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cfg + "/settings.json")), before, "settings 不得被動")
    }

    func testComplexCommandRefused() throws {
        // 複合指令(含空白/管線/引號)→ 拒絕,不搬 shim(owner 決策)
        let original = #"env FOO='a b' /usr/local/bin/st --flag | tr -d x"#
        let json = try String(data: JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": original]]), encoding: .utf8)!
        assertRefused(planOf(json), contains: "single script file")
    }

    func testBareRelativeMissingRefused() throws {
        // bare / 相對(即使 probe 回 true 也不吃 CWD)/ 絕對但不存在 → 拒絕
        for cmd in ["foo", "./foo", "bin/foo"] {
            assertRefused(planOf(#"{"statusLine":{"type":"command","command":"\#(cmd)"}}"#,
                                 regular: { _ in true }, exec: { _ in true }),
                          contains: "single script file")
        }
        assertRefused(planOf(#"{"statusLine":{"type":"command","command":"/nope/x.sh"}}"#),
                      contains: "single script file")
        // ~user 不展開 → 拒絕
        assertRefused(planOf(#"{"statusLine":{"type":"command","command":"~bob/st.sh"}}"#,
                             regular: { _ in true }, exec: { _ in true }),
                      contains: "single script file")
    }

    func testCommandPointingAtHookRefused() throws {
        // 指向 hook 本身 → 因含 hook 檔名,由「not managed」守衛拒絕(絕不包裹我方 hook)
        assertRefused(planOf(#"{"statusLine":{"type":"command","command":"\#(hookPath)"}}"#,
                             regular: { _ in true }, exec: { _ in true }),
                      contains: "not managed by this installer")
    }

    // MARK: planner — canonical 冪等

    func testCanonicalFormsAlreadyInstalled() throws {
        let f1 = prefix
        let f2 = "\(prefix) --wrap '/Users/t/my.sh'"
        let f3 = "\(prefix) --wrap /bin/bash -- '/Users/t/my.sh'"
        for cmd in [f1, f2, f3] {
            let plan = planOf(#"{"statusLine":{"type":"command","command":"\#(cmd)"}}"#)
            guard case .alreadyInstalled = plan.action else {
                XCTAssertTrue(false, "expected alreadyInstalled for \(cmd), got \(plan.action)"); continue
            }
            XCTAssertNil(plan.newSettingsJSON)
        }
        // 引號內含空白路徑的 F2 也要認得
        let spaced = "\(prefix) --wrap '/Users/t/my status.sh'"
        if case .alreadyInstalled = planOf(#"{"statusLine":{"type":"command","command":"\#(spaced)"}}"#).action {} else {
            XCTAssertTrue(false)
        }
    }

    func testCanonicalWithoutTypeGetsPreciseRefusal() throws {
        assertRefused(planOf(#"{"statusLine":{"command":"\#(prefix)"}}"#), contains: "this installer's")
        assertRefused(planOf(#"{"statusLine":{"type":"static","command":"\#(prefix)"}}"#), contains: "this installer's")
    }

    func testCanonicalIsByteExactNoTrim() throws {
        // 前後空白的 F1 不是 canonical(byte-exact)→ 不得被當成 alreadyInstalled
        // (含 hook 檔名 → 由 "not managed" 守衛拒絕;重點是「非 alreadyInstalled」)
        for cmd in [" \(prefix) ", "\(prefix) --wrap 'rel/path.sh'"] {
            let plan = planOf(#"{"statusLine":{"type":"command","command":"\#(cmd)"}}"#)
            if case .alreadyInstalled = plan.action {
                XCTAssertTrue(false, "byte-exact:不得把「\(cmd)」當成 alreadyInstalled")
            }
            XCTAssertNil(plan.newSettingsJSON, "\(cmd) 應為 refuse,無 payload")
        }
    }

    // MARK: 內嵌 hook drift

    func testEmbeddedHookMatchesScriptsFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let onDisk = try Data(contentsOf: root.appendingPathComponent("Scripts/claude-statusline-hook.sh"))
        XCTAssertEqual(StatuslineHookScript.content, onDisk,
                       "內嵌副本與 Scripts/claude-statusline-hook.sh 不一致 — 跑 python3 Scripts/generate-embedded-hook.py")
    }

    // MARK: runner

    func testRunnerFreshInstall() throws {
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg dir").path
        let data = dir.appendingPathComponent("data dir").path
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertEqual(mode(cfg + "/settings.json"), 0o600)
        XCTAssertEqual(mode(data + "/claude-statusline-hook.sh"), 0o700)
        XCTAssertTrue(r.output.contains("did not exist before"))
        XCTAssertFalse(r.output.contains("backup:"))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cfg + "/settings.json"))) as! [String: Any]
        let sl = root["statusLine"] as! [String: Any]
        XCTAssertEqual(sl["type"] as? String, "command")
        XCTAssertTrue((sl["command"] as! String).contains("claude-statusline-hook.sh"))
    }

    func testRunnerIdempotentAndRepairsHook() throws {
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        XCTAssertEqual(InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false).exitCode, 0)
        let sURL = URL(fileURLWithPath: cfg + "/settings.json")
        let bytes1 = try Data(contentsOf: sURL)
        // 弄壞 hook → 第二跑修復,settings 不動,無備份
        try Data("broken".utf8).write(to: URL(fileURLWithPath: data + "/claude-statusline-hook.sh"))
        chmod(data + "/claude-statusline-hook.sh", 0o644)
        let r2 = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r2.exitCode, 0, r2.output)
        XCTAssertTrue(r2.output.contains("already installed"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: data + "/claude-statusline-hook.sh")),
                       StatuslineHookScript.content)
        XCTAssertEqual(mode(data + "/claude-statusline-hook.sh"), 0o700)
        XCTAssertEqual(try Data(contentsOf: sURL), bytes1)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: cfg)).filter { $0.contains("backup") }.isEmpty)
    }

    func testRunnerWrapExistingScriptEndToEnd() throws {
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data dir").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        let mine = dir.appendingPathComponent("my-status.sh").path
        try Data("#!/bin/bash\n/bin/cat >/dev/null\nprintf MINE\nprintf E >&2\nexit 3\n".utf8)
            .write(to: URL(fileURLWithPath: mine))
        chmod(mine, 0o755)
        let originalSettings = try JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": mine], "keep": ["x": 1]])
        try originalSettings.write(to: URL(fileURLWithPath: cfg + "/settings.json"))

        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("backup: "))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cfg + "/settings.json"))) as! [String: Any]
        XCTAssertEqual((root["keep"] as? [String: Any])?["x"] as? Int, 1)
        let newCmd = (root["statusLine"] as! [String: Any])["command"] as! String
        let backups = try FileManager.default.contentsOfDirectory(atPath: cfg).filter { $0.contains("aipet-backup") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cfg + "/" + backups[0])), originalSettings)
        XCTAssertEqual(mode(cfg + "/" + backups[0]), 0o600)

        // 實跑新 command:stdout/stderr/exit 全由使用者腳本決定,官方檔照落
        let payload = #"{"session_id":"S","rate_limits":{"five_hour":{"used_percentage":9,"resets_at":1789000000}}}"#
        let shell = try runShell(newCmd, stdin: payload, env: ["AIPET_DATA_DIR": data])
        XCTAssertEqual(shell.stdout, "MINE")
        XCTAssertEqual(shell.stderr, "E")
        XCTAssertEqual(shell.status, 3)
        let readings = ClaudeCodeAdapter.readStatuslineRateLimits(
            from: [URL(fileURLWithPath: data + "/claude-statusline.json")])
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings[0].primary?.usedPercent, 9)
        XCTAssertFalse((try String(contentsOf: URL(fileURLWithPath: data + "/claude-statusline.json"), encoding: .utf8)).contains("\"S\""))
    }

    func testRunnerDryRunWritesNothing() throws {
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: true)
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("dry-run"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfg))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data))
    }

    func testRunnerSymlinkedSettingsRefusedButHookRepairable() throws {
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("dotfiles-settings.json").path
        try Data(#"{"statusLine":{"type":"command","command":"/bin/date"}}"#.utf8)
            .write(to: URL(fileURLWithPath: real))
        try FileManager.default.createSymbolicLink(atPath: cfg + "/settings.json", withDestinationPath: real)
        let refuse = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(refuse.exitCode, 2, refuse.output)
        XCTAssertTrue(refuse.output.contains("symlink"))
        var st = stat()
        XCTAssertTrue(lstat(cfg + "/settings.json", &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK)

        // canonical(透過 symlink 讀到)→ alreadyInstalled 仍可修復 hook,settings 不碰
        let hookPathReal = data + "/claude-statusline-hook.sh"
        let canonical = InstallHook.hookInvocationPrefix(hookPath: hookPathReal)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": canonical]])
            .write(to: URL(fileURLWithPath: real))
        let repair = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(repair.exitCode, 0, repair.output)
        XCTAssertTrue(repair.output.contains("already installed"))
        XCTAssertEqual(mode(hookPathReal), 0o700)
    }

    func testRunnerConfigDirIsRegularFile() throws {
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg-as-file").path
        try Data("i am a file".utf8).write(to: URL(fileURLWithPath: cfg))
        let data = dir.appendingPathComponent("data").path
        for dry in [true, false] {
            let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: dry)
            XCTAssertEqual(r.exitCode, 2, "dry=\(dry):\(r.output)")
            XCTAssertTrue(r.output.contains("cannot inspect"), r.output)
        }
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: cfg), encoding: .utf8), "i am a file")
    }

    func testRunnerBackupCollision() throws {
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        let mine = dir.appendingPathComponent("m.sh").path
        try Data("#!/bin/bash\ntrue\n".utf8).write(to: URL(fileURLWithPath: mine)); chmod(mine, 0o755)
        let fixed = Date(timeIntervalSince1970: 1_789_000_000)
        var seeds: [Data] = []
        func seed(_ n: Int) throws {
            let d = try JSONSerialization.data(withJSONObject:
                ["statusLine": ["type": "command", "command": mine], "seed": n])
            seeds.append(d)
            try d.write(to: URL(fileURLWithPath: cfg + "/settings.json"))
        }
        try seed(1)
        XCTAssertEqual(InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false, now: fixed).exitCode, 0)
        try seed(2)
        XCTAssertEqual(InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false, now: fixed).exitCode, 0)
        let backups = try FileManager.default.contentsOfDirectory(atPath: cfg).filter { $0.contains("aipet-backup") }.sorted()
        XCTAssertEqual(backups.count, 2, "\(backups)")
        XCTAssertTrue(backups[1].hasSuffix("-2"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cfg + "/" + backups[0])), seeds[0])
        XCTAssertEqual(mode(cfg + "/" + backups[0]), 0o600)
        XCTAssertEqual(mode(cfg + "/" + backups[1]), 0o600)
    }

    func testNewCommandEscapedInOutput() throws {
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.path + "/da\u{1b}t\na"
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: true)
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("\\x1B") && r.output.contains("\\x0A"), r.output)
        XCTAssertFalse(r.output.contains("da\u{1b}t\na"))
    }

    func testRefuseComplexEscapesControlChars() throws {
        // 拒絕訊息回顯使用者指令;含控制字元必須跳脫,不得偽造輸出行
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        let evil = "foo\u{1b}bar\nbaz | qux"
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": evil]])
            .write(to: URL(fileURLWithPath: cfg + "/settings.json"))
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 2, r.output)
        XCTAssertTrue(r.output.contains("\\x1B"), r.output)
        XCTAssertFalse(r.output.contains("foo\u{1b}bar"))
    }

    func testACLClearedOnCreatedFiles() throws {
        // 父目錄帶「everyone allow read + 檔案繼承」ACL;新建的 settings/backup/hook 不得
        // 繼承該 ACL(否則「0600」settings 變 everyone 可讀;codex code-r11 #1)。
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let setACL = Process()
        setACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        setACL.arguments = ["+a", "everyone allow read,file_inherit", cfg]
        setACL.standardError = Pipe()
        try setACL.run(); setACL.waitUntilExit()
        // 驗證 FS 真的套用了繼承 ACL(否則此環境無法驗,跳過不假綠)
        let probe = cfg + "/probe.txt"
        FileManager.default.createFile(atPath: probe, contents: Data("x".utf8))
        guard setACL.terminationStatus == 0, hasExtendedACL(probe) else {
            print("  ⓘ testACLClearedOnCreatedFiles skipped — inherited ACL not enforced here")
            return
        }
        try? FileManager.default.removeItem(atPath: probe)
        // 先放一份 settings 讓 install 會做備份
        let mine = dir.appendingPathComponent("m.sh").path
        try Data("#!/bin/bash\ntrue\n".utf8).write(to: URL(fileURLWithPath: mine)); chmod(mine, 0o755)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": mine]])
            .write(to: URL(fileURLWithPath: cfg + "/settings.json"))
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertFalse(hasExtendedACL(cfg + "/settings.json"), "settings.json 不得帶繼承 ACL")
        let backups = try FileManager.default.contentsOfDirectory(atPath: cfg).filter { $0.contains("aipet-backup") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertFalse(hasExtendedACL(cfg + "/" + backups[0]), "backup 不得帶繼承 ACL")
    }

    func testRunnerSymlinkToHookRefused() throws {
        // statusLine 指向一個「外名 symlink → 我方 hook」的路徑:檔名守衛抓不到,但 dev+ino
        // 身份比對必須抓到並拒絕(不得回報成功 + 產生 runtime 會 loop 的設定;codex code-r12b #2)
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let hookP = data + "/claude-statusline-hook.sh"
        // 先讓 hook 落地(fresh install)
        XCTAssertEqual(InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false).exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hookP))
        // 外名 symlink → hook,把 statusLine 指向它
        let alias = dir.appendingPathComponent("mystatus.sh").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: hookP)
        let before = try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": alias]])
        try before.write(to: URL(fileURLWithPath: cfg + "/settings.json"))
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 2, "symlink→hook 必須拒絕:\(r.output)")
        // r17 後 refuse 訊息不再宣稱 runtime 後果;鎖定穩定 token「hook itself」(不再接受
        // 已移除的「would loop」,免得回歸該不實措辭時測不出來 —— grok code-r18)。
        XCTAssertTrue(r.output.contains("hook itself"), r.output)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cfg + "/settings.json")), before, "settings 不得被動")
    }

    func testCLIUnknownArgWritesNothing() throws {
        // `--dryrun`(打錯字)/ 未知參數 → exit 2、零寫入(codex code-r12b #3)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let aipet = root.appendingPathComponent(".build/debug/aipet").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: aipet), "需先建 aipet")
        for badArg in ["--dryrun", "--help", "extra"] {
            let dir = plainTempDir()
            let cfg = dir.appendingPathComponent("cfg").path
            let data = dir.appendingPathComponent("data").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: aipet)
            p.arguments = ["install-hook", badArg]
            var env = ProcessInfo.processInfo.environment
            env["CLAUDE_CONFIG_DIR"] = cfg
            env["AIPET_DATA_DIR"] = data
            p.environment = env
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 2, "\(badArg) 應 exit 2")
            XCTAssertFalse(FileManager.default.fileExists(atPath: cfg), "\(badArg) 不得建 configDir")
            XCTAssertFalse(FileManager.default.fileExists(atPath: data), "\(badArg) 不得建 dataDir")
        }
    }

    func testAlreadyInstalledCanonicalAliasToHookRefused() throws {
        // 既存的 canonical `--wrap '<alias>'`,其中 alias(symlink)解析到我方 hook:
        // 分類為 .alreadyInstalled(.wrapPath) 會繞過 fresh-wrap 的身份守衛 → runtime 自我
        // 引用、狀態列 exit 2,但 installer 回報「already installed」(codex code-r14 #1)。
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let hookP = data + "/claude-statusline-hook.sh"
        XCTAssertEqual(InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false).exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hookP))
        // 外名 symlink → hook(不含 hook 檔名 → 分類為合法 canonical wrap target)
        let alias = dir.appendingPathComponent("mystatus.sh").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: hookP)
        let canonical = InstallHook.hookInvocationPrefix(hookPath: hookP)
            + " --wrap " + InstallHook.shellSingleQuote(alias)
        let before = try JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": canonical]])
        try before.write(to: URL(fileURLWithPath: cfg + "/settings.json"))
        for dry in [true, false] {
            let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: dry)
            XCTAssertEqual(r.exitCode, 2, "dry=\(dry) canonical alias→hook 必須拒絕:\(r.output)")
            XCTAssertTrue(r.output.contains("hook itself"), r.output)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cfg + "/settings.json")), before,
                       "settings 不得被動")
    }

    func testHookACLRepairedWhenPresent() throws {
        // 既存 hook 內容/mode 皆正確,但被加了擴充 ACL(everyone allow write)→ hookNeedsRepair
        // 必須判定需重寫(重寫才會清 ACL);只查內容/mode 會漏,權限硬化承諾被繞過
        // (codex code-r14 #2)。
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        XCTAssertEqual(InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false).exitCode, 0)
        let hookP = data + "/claude-statusline-hook.sh"
        let addACL = Process()
        addACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        addACL.arguments = ["+a", "everyone allow write", hookP]
        addACL.standardError = Pipe()
        try addACL.run(); addACL.waitUntilExit()
        // 內容/mode 未動(+a 只加 ACL entry);若此環境不套用 ACL 則跳過不假綠
        guard addACL.terminationStatus == 0, hasExtendedACL(hookP) else {
            print("  ⓘ testHookACLRepairedWhenPresent skipped — extended ACL not enforced here")
            return
        }
        XCTAssertEqual(mode(hookP), 0o700)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: hookP)), StatuslineHookScript.content)
        // dry-run:只有 ACL 相異也必須報「would refresh」(證明 hookNeedsRepair 認得 ACL)
        let dryR = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: true)
        XCTAssertEqual(dryR.exitCode, 0, dryR.output)
        XCTAssertTrue(dryR.output.contains("would refresh"), "帶 ACL 的 hook 應判為需修復:\(dryR.output)")
        // 真跑:重寫清 ACL,內容/mode 不變
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("hook refreshed"), r.output)
        XCTAssertFalse(hasExtendedACL(hookP), "重寫後 hook 不得再帶擴充 ACL")
        XCTAssertEqual(mode(hookP), 0o700)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: hookP)), StatuslineHookScript.content)
    }

    func testACLAbsentErrnoClassification() {
        // acl_get_fd_np 回 nil 的 errno 分類(codex code-r15 #2 + r16 #1)。純函式,可攜、不需
        // 真的 ACL-unsupported FS:良性(無 ACL / FS 不支援)不得觸發重寫;真失敗要 fail closed。
        for e in [ENOENT, EOPNOTSUPP, ENOTSUP] {
            XCTAssertTrue(InstallHook.aclAbsentErrno(e), "errno \(e) 應視為『無 ACL』(不重寫)")
        }
        for e in [EACCES, EPERM, EINVAL, EBADF, ENOMEM] {
            XCTAssertFalse(InstallHook.aclAbsentErrno(e), "errno \(e) 是真查詢失敗,必須 fail closed")
        }
        // EOPNOTSUPP 與 ENOTSUP 在 Darwin 上是不同值(grok code-r13 實測),兩者都要涵蓋
        XCTAssertTrue(EOPNOTSUPP != ENOTSUP, "Darwin 上兩者不同值,分類必須各自涵蓋")
    }

    func testAlreadyInstalledHardlinkToHookRefused() throws {
        // codex code-r15 #1:wrap target 是「hardlink → 我方 hook」且需修復時,writeAtomic 的
        // tmp+rename 換掉 hookPath 的 inode,只在修復「後」做 dev+ino 比對會漏(hardlink 仍指
        // 舊 inode)→ 回報成功。修復「前」的比對(此刻同 inode)才抓得到。
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let hookP = data + "/claude-statusline-hook.sh"
        XCTAssertEqual(InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false).exitCode, 0)
        let hard = dir.appendingPathComponent("hardalias.sh").path
        try FileManager.default.linkItem(atPath: hookP, toPath: hard)   // 同 inode
        // 觸發修復:對(共享的)hook inode 加擴充 ACL —— 讓 break-once 時 rename 分岔 inode、
        // 修復後比對漏掉。此環境不套 ACL 則跳過不假綠。
        let addACL = Process()
        addACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        addACL.arguments = ["+a", "everyone allow write", hookP]
        addACL.standardError = Pipe()
        try addACL.run(); addACL.waitUntilExit()
        guard addACL.terminationStatus == 0, hasExtendedACL(hookP) else {
            print("  ⓘ testAlreadyInstalledHardlinkToHookRefused skipped — extended ACL not enforced here")
            return
        }
        let canonical = InstallHook.hookInvocationPrefix(hookPath: hookP)
            + " --wrap " + InstallHook.shellSingleQuote(hard)
        let before = try JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": canonical]])
        try before.write(to: URL(fileURLWithPath: cfg + "/settings.json"))
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 2, "hardlink→hook + 修復 必須拒絕(修復前比對):\(r.output)")
        XCTAssertTrue(r.output.contains("hook itself"), r.output)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cfg + "/settings.json")), before,
                       "settings 不得被動")
    }

    func testHookACLLookupErrorFailsClosed() throws {
        // codex code-r15 #2:acl_get_fd_np 回 nil 同時代表「無 ACL」與「查詢失敗」。帶
        // `deny readsecurity` 的 ACL 連讀 ACL 都被擋 → 舊碼當「無 ACL」放過(fail open),敵意
        // ACL 既偵測不到也清不掉。修好後應 fail closed:判為需重寫。
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("data").path
        XCTAssertEqual(InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false).exitCode, 0)
        let hookP = data + "/claude-statusline-hook.sh"
        for spec in ["everyone allow write", "everyone deny readsecurity"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/chmod")
            p.arguments = ["+a", spec, hookP]; p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                print("  ⓘ testHookACLLookupErrorFailsClosed skipped — chmod +a unsupported here"); return
            }
        }
        // 確認 deny readsecurity 真的讓讀 ACL 失敗(否則此環境無法驗此路徑)
        let ls = try runShell("/bin/ls -le \(InstallHook.shellSingleQuote(hookP))")
        guard ls.status != 0 else {
            print("  ⓘ testHookACLLookupErrorFailsClosed skipped — readsecurity deny not enforced here"); return
        }
        // dry-run 必須 fail closed → would refresh(而非 up to date)
        let dryR = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: true)
        XCTAssertEqual(dryR.exitCode, 0, dryR.output)
        XCTAssertTrue(dryR.output.contains("would refresh"), "ACL 查詢失敗必須當需修復:\(dryR.output)")
        // 真跑重寫 → 新 inode 無 ACL、可再讀
        let r = InstallHook.run(configDir: cfg, dataDir: data, home: "/Users/t", dryRun: false)
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(r.output.contains("hook refreshed"), r.output)
        XCTAssertEqual(try runShell("/bin/ls -le \(InstallHook.shellSingleQuote(hookP))").status, 0,
                       "重寫後應可再讀 security 資訊")
        XCTAssertFalse(hasExtendedACL(hookP), "重寫後不得帶擴充 ACL")
        XCTAssertEqual(mode(hookP), 0o700)
    }

    func testCLIProcessExitCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let aipet = root.appendingPathComponent(".build/debug/aipet").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: aipet), "需先建 aipet")
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"static","command":"x"}}"#.utf8)
            .write(to: URL(fileURLWithPath: cfg + "/settings.json"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: aipet)
        p.arguments = ["install-hook"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = cfg
        env["AIPET_DATA_DIR"] = dir.appendingPathComponent("data").path
        p.environment = env
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 2)
    }

    func testCLIDryRunCreatesNothing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let aipet = root.appendingPathComponent(".build/debug/aipet").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: aipet), "需先建 aipet")
        let dir = plainTempDir()
        let cfg = dir.appendingPathComponent("cfg").path
        let data = dir.appendingPathComponent("never-created").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: aipet)
        p.arguments = ["install-hook", "--dry-run"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = cfg
        env["AIPET_DATA_DIR"] = data
        p.environment = env
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfg))
    }
}
