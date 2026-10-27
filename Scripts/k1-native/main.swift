// main.swift — k1ctx 命令列入口(K1-NATIVE)。窄命令面(N2);所有語意在 K1Native.swift。
//
// 用法:
//   k1ctx context-init <context>        驗證(絕對正規路徑、目錄、非 symlink、owner uid、0700、完全為空)後建立 marker
//   k1ctx context-validate <context>    驗證 + 逐位元組驗 marker + 白名單;stdout 每行 "entry=<name>" 列出存在的白名單項目
//   k1ctx write-p12 <context>           驗證後,把 stdin 的 base64 文字解碼為 P12,以 O_EXCL|O_NOFOLLOW、0600 寫成 p12.tmp
//   k1ctx remove-p12 <context>          驗證後 unlink p12.tmp(不跟隨 symlink)並確認消失;失敗 = 1(呼叫端須視為 fatal)
//   k1ctx context-finalize <context>    驗證後要求 context 只剩 marker,刪 marker、以父目錄 fd + dev:inode 身分 rmdir
//   k1ctx check-keychain-path <path>    K5 顯式 keychain 輸入的物件形狀:絕對正規路徑、既存一般檔、非 symlink(開啟 O_NOFOLLOW|
//                                       O_NONBLOCK 後 fstat 同一 fd;不讀內容)。2 = 拒絕;1 = 無法判定
//   k1ctx scan-secrets [--exclude <abs>]... <abs-root>...
//                                       stdin 每行一個 sentinel;根與排除都須為絕對「正規」路徑(否則 scan-args);完整走訪根目錄
//                                       (symlink 不跟隨、FIFO 不開啟、錯誤不吞);stdout 報告 MATCH / ERROR / SPECIAL 與最後的
//                                       summary 行;0 CLEAN、2 SECRET_FOUND、1 INCOMPLETE_SCAN
// 退出碼:0 成功;1 作業失敗;2 拒絕 / 用法錯誤;3 CONTEXT_NOT_FOUND。
// 失敗時 stdout 印一行 "token=<token>"(機器可讀;shell adapter 據此組訊息),stderr 印 "k1ctx: <cmd>: <STATUS>(<token>): <detail>"。
// 本程式從不印任何檔案內容、不印 P12 / base64、不讀取任何環境變數作為安全依據。
import Darwin

let toolName = "k1ctx"
let maxBase64Bytes = 8 * 1024 * 1024   // P12 的 base64 輸入上限(有界讀取)

func emitStdout(_ s: String) { fputs(s + "\n", stdout) }
func emitStderr(_ s: String) { fputs(s + "\n", stderr) }

func usage() -> Never {
    emitStderr("usage: \(toolName) context-init|context-validate|write-p12|remove-p12|context-finalize <context>")
    emitStderr("       \(toolName) check-keychain-path <abs-path>")
    emitStderr("       \(toolName) scan-secrets [--exclude <abs-path>]... <abs-root>...   (sentinels on stdin, one per line)")
    emitStdout("token=usage")
    exit(K1Status.rejected.rawValue)
}

/// 統一的失敗出口:stdout token 行、stderr 診斷、凍結退出碼。stderr 形式 "k1ctx: <cmd>: <STATUS>(<token>): <detail>" ——
/// 狀態與 token 以括號相連(不是 ": "),讓 shell adapter 自己的 "<STATUS>: <token>" 行在 log 中可被唯一辨識。
func fail(_ cmd: String, _ e: K1Error) -> Never {
    emitStdout("token=\(e.token)")
    emitStderr("\(toolName): \(cmd): \(e.status.word)(\(e.token)): \(e.detail)")
    exit(e.status.rawValue)
}

func run(_ cmd: String, _ body: () throws -> Void) -> Never {
    do {
        try body()
        exit(K1Status.ok.rawValue)
    } catch let e as K1Error {
        fail(cmd, e)
    } catch {
        fail(cmd, K1Error(.operational, "internal", "未預期的錯誤"))
    }
}

/// argv 以位元組取得(檔名 / 路徑不假設 UTF-8)。
func argBytes(_ i: Int) -> [UInt8] {
    guard let p = CommandLine.unsafeArgv[i] else { return [] }
    let len = strlen(p)
    return p.withMemoryRebound(to: UInt8.self, capacity: len) { Array(UnsafeBufferPointer(start: $0, count: len)) }
}

let argc = Int(CommandLine.argc)
if argc < 2 { usage() }
let cmd = String(cString: CommandLine.unsafeArgv[1]!)
let uid = getuid()

switch cmd {
case "context-init":
    if argc != 3 { usage() }
    let path = argBytes(2)
    run(cmd) {
        let h = try openContext(path, uid: uid)
        defer { h.close() }
        let names = try enumerateEntries(h.fd)
        if !names.isEmpty {
            throw K1Error(.rejected, "context-not-empty", "context 在 K1 初始化前必須完全為空(含隱藏項;第一項 \(escapeBytes(names[0])))")
        }
        try createMarker(h.fd, uid: uid)
    }

case "context-validate":
    if argc != 3 { usage() }
    let path = argBytes(2)
    run(cmd) {
        let h = try openContext(path, uid: uid)
        defer { h.close() }
        try readMarker(h.fd, uid: uid)
        let names = try enumerateEntries(h.fd)
        let rep = try classifyEntries(h.fd, names)
        for n in rep.present { emitStdout("entry=\(escapeBytes(n))") }
    }

case "write-p12":
    if argc != 3 { usage() }
    let path = argBytes(2)
    run(cmd) {
        let h = try openContext(path, uid: uid)
        defer { h.close() }
        try readMarker(h.fd, uid: uid)
        _ = try classifyEntries(h.fd, try enumerateEntries(h.fd))
        let (text, rerr) = readAllStdin(maxBytes: maxBase64Bytes)
        if let e = rerr {
            if e == EFBIG { throw K1Error(.rejected, "p12-decode", "base64 輸入超過上限(\(maxBase64Bytes) bytes)") }
            throw K1Error(.operational, "p12-decode", "讀取 stdin 失敗(\(describeErrno(e)))")
        }
        guard let data = decodeBase64Strict(text) else {
            throw K1Error(.rejected, "p12-decode", "DEVELOPER_ID_P12_BASE64 不是合法的 base64(嚴格字母表、結尾填充、僅容許 ASCII 空白)")
        }
        try materializeP12(h.fd, data)
    }

case "remove-p12":
    if argc != 3 { usage() }
    let path = argBytes(2)
    run(cmd) {
        let h = try openContext(path, uid: uid)
        defer { h.close() }
        try readMarker(h.fd, uid: uid)
        try removeP12(h.fd)
    }

case "context-finalize":
    if argc != 3 { usage() }
    let path = argBytes(2)
    run(cmd) {
        let h = try openContext(path, uid: uid)
        defer { h.close() }
        try readMarker(h.fd, uid: uid)
        let names = try enumerateEntries(h.fd)
        let rep = try classifyEntries(h.fd, names)
        if let residual = rep.present.first {
            throw K1Error(.operational, "residual-entry", "context 仍有 K1 物件未被移除:\(escapeBytes(residual))(keychain 未刪成功或 P12 未移除?)")
        }
        try removeMarkerAndContext(h, path: path, uid: uid)
    }

case "check-keychain-path":
    if argc != 3 { usage() }
    let path = argBytes(2)
    run(cmd) { try checkKeychainPath(path) }

case "scan-secrets":
    var roots: [[UInt8]] = []
    var excludes: [[UInt8]] = []
    var i = 2
    while i < argc {
        let a = argBytes(i)
        if a == bytes("--exclude") {
            if i + 1 >= argc { usage() }
            let ex = argBytes(i + 1)
            do { try checkScanPathSyntax(ex, what: "--exclude") } catch let e as K1Error { fail(cmd, e) } catch { usage() }
            excludes.append(ex); i += 2
        } else {
            do { try checkScanPathSyntax(a, what: "掃描根目錄") } catch let e as K1Error { fail(cmd, e) } catch { usage() }
            roots.append(a); i += 1
        }
    }
    if roots.isEmpty { usage() }
    let (text, rerr) = readAllStdin(maxBytes: 1024 * 1024)
    if let e = rerr { fail(cmd, K1Error(.operational, "scan-args", "讀取 stdin 的 sentinel 失敗(\(describeErrno(e)))")) }
    var sentinels: [[UInt8]] = []
    var cur: [UInt8] = []
    for c in text { if c == 0x0a { if !cur.isEmpty { sentinels.append(cur) }; cur = [] } else { cur.append(c) } }
    if !cur.isEmpty { sentinels.append(cur) }
    if sentinels.isEmpty { fail(cmd, K1Error(.rejected, "scan-args", "stdin 沒有任何 sentinel(每行一個;不得為空)")) }
    let sum = scanSecrets(roots: roots, excludes: excludes, sentinels: sentinels) { emitStdout($0) }
    emitStdout(sum.line)
    if sum.exitStatus != .ok {
        emitStderr("\(toolName): \(cmd): \(sum.status): files=\(sum.files) errors=\(sum.errors) matches=\(sum.matches)")
    }
    exit(sum.exitStatus.rawValue)

default:
    usage()
}
