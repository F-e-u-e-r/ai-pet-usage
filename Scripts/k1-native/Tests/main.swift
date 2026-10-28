// Tests/main.swift — K1-NATIVE 單元 / 整合測試 runner(與 K1Native.swift 一起由 Scripts/k1-native/build.sh --tests 編譯)。
//
// 與 repo 的 usagecore-tests 同一手法:獨立執行檔、每個案例手動呼叫、以退出碼回報(0 = 全數通過)。只用 Darwin;不呼叫
// 任何外部行程;所有 fixture 建在 TMPDIR 下的 mkdtemp 目錄,結束時移除。每個「不得阻塞」的案例都以單調時鐘斷言完成時間,
// 另有 alarm() 看門狗:任何阻塞都會讓整個 runner 被 SIGALRM 終止(非零)而非默默通過。
//
// 涵蓋(owner N13):marker symlink / FIFO / 目錄 / 置換;不可存取 context;隱藏項;任意檔名;列舉失敗;不完整的秘密掃描;
// P12 exclusive 建立;P12 unlink 失敗;任意 cleanup 路徑拒絕;errno 分類;畸形 marker;非預期 context 項目;以及 N14(F-N1:
// 較早的 metadata 觀察 → 置換 marker → 原生讀取仍以「開啟到的物件」判定)與 N15(F-N2:不可走訪的子樹 + 其下的 sentinel →
// INCOMPLETE_SCAN 而非 CLEAN;FIFO 不阻塞;symlink 不跟隨;所有路徑被走訪或被明確拒絕)。
import Darwin

var passCount = 0
var failCount = 0
func ok() { passCount += 1 }
func bad(_ msg: String) { failCount += 1; fputs("FAIL: \(msg)\n", stdout) }
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want { ok() } else { bad("\(name): got [\(got)] want [\(want)]") }
}
// tuple 不能泛型地宣告 Equatable;以明確 arity 的多載比較(stdlib 提供 tuple 的 ==)。
func check<A: Equatable, B: Equatable>(_ name: String, _ got: (A, B), _ want: (A, B)) {
    if got == want { ok() } else { bad("\(name): got [\(got)] want [\(want)]") }
}
func check<A: Equatable, B: Equatable, C: Equatable>(_ name: String, _ got: (A, B, C), _ want: (A, B, C)) {
    if got == want { ok() } else { bad("\(name): got [\(got)] want [\(want)]") }
}
func check<A: Equatable, B: Equatable, C: Equatable, D: Equatable>(_ name: String, _ got: (A, B, C, D), _ want: (A, B, C, D)) {
    if got == want { ok() } else { bad("\(name): got [\(got)] want [\(want)]") }
}
func check<A: Equatable, B: Equatable, C: Equatable, D: Equatable, E: Equatable, F: Equatable>(_ name: String, _ got: (A, B, C, D, E, F), _ want: (A, B, C, D, E, F)) {
    if got == want { ok() } else { bad("\(name): got [\(got)] want [\(want)]") }
}
func expectError(_ name: String, _ status: K1Status, _ token: String, _ body: () throws -> Void) {
    do { try body(); bad("\(name): 預期 \(status.word)/\(token) 卻成功") }
    catch let e as K1Error {
        if e.status == status && e.token == token { ok() } else { bad("\(name): got \(e.status.word)/\(e.token) [\(e.detail)] want \(status.word)/\(token)") }
    } catch { bad("\(name): 非 K1Error") }
}
func expectOK(_ name: String, _ body: () throws -> Void) {
    do { try body(); ok() }
    catch let e as K1Error { bad("\(name): \(e.status.word)/\(e.token): \(e.detail)") }
    catch { bad("\(name): 未預期錯誤") }
}
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
/// 斷言 body 在 limit 秒內完成(FIFO / symlink→FIFO 案例的「不阻塞」證明;另有 alarm 看門狗)。
func timed(_ name: String, limit: Double, _ body: () -> Void) {
    let t0 = now(); body(); let dt = now() - t0
    if dt < limit { ok() } else { bad("\(name): 耗時 \(dt)s ≥ \(limit)s(疑似阻塞)") }
}

// ---------------------------------------------------------------- fixture 工具(只用 syscalls)
func cstr(_ s: String) -> [UInt8] { Array(s.utf8) }
func mkdirp(_ p: String, _ mode: mode_t = 0o700) { if mkdir(p, mode) != 0 && errno != EEXIST { bad("mkdir \(p): \(describeErrno(errno))") } }
func writeFile(_ p: String, _ data: [UInt8], _ mode: mode_t = 0o600) {
    let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, mode)
    if fd < 0 { bad("open \(p): \(describeErrno(errno))"); return }
    if let e = writeAll(fd, data) { bad("write \(p): \(describeErrno(e))") }
    _ = close(fd)
    _ = chmod(p, mode)   // 不受 umask 影響
}
func readFile(_ p: String) -> [UInt8]? {
    let fd = open(p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 { return nil }
    defer { _ = close(fd) }
    var out: [UInt8] = []
    while true { let (c, e) = readUpTo(fd, 4096); if e != nil { return nil }; if c.isEmpty { break }; out += c }
    return out
}
func lmode(_ p: String) -> (type: mode_t, perm: mode_t)? {
    var st = stat(); if lstat(p, &st) != 0 { return nil }
    return (st.st_mode & S_IFMT, st.st_mode & 0o7777)
}
func exists(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 }
/// 對 path 加上「目前使用者 deny list」的 ACL(等同 `chmod +a "$(id -un) deny list"`)。membership.h 的 mbr_uid_to_uuid 不在
/// Swift 的 Darwin 模組裡,以 @_silgen_name 直接綁定 libSystem 的符號。
@_silgen_name("mbr_uid_to_uuid") func c_mbr_uid_to_uuid(_ uid: uid_t, _ uu: UnsafeMutablePointer<UInt8>) -> Int32
func denyListACL(_ path: String) -> Bool {
    var uu = [UInt8](repeating: 0, count: 16)
    let r = uu.withUnsafeMutableBufferPointer { c_mbr_uid_to_uuid(getuid(), $0.baseAddress!) }
    if r != 0 { return false }
    guard let acl0 = acl_init(1) else { return false }
    var acl: acl_t? = acl0
    var entry: acl_entry_t? = nil
    if acl_create_entry(&acl, &entry) != 0 { return false }
    if acl_set_tag_type(entry, ACL_EXTENDED_DENY) != 0 { return false }
    if uu.withUnsafeBufferPointer({ acl_set_qualifier(entry, UnsafeRawPointer($0.baseAddress!)) }) != 0 { return false }
    var permset: acl_permset_t? = nil
    if acl_get_permset(entry, &permset) != 0 { return false }
    if acl_add_perm(permset, ACL_LIST_DIRECTORY) != 0 { return false }
    return acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0
}
func openDirFD(_ p: String) -> Int32 { open(p, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
/// 遞迴移除(fixture 專用;先恢復權限與旗標)。
func removeTree(_ p: String) {
    _ = chflags(p, 0)
    guard let m = lmode(p) else { return }
    if m.type == S_IFDIR {
        _ = chmod(p, 0o700)
        _ = acl_set_file(p, ACL_TYPE_EXTENDED, acl_init(0))   // 清掉測試加上的 ACL(若有)
        let fd = openDirFD(p)
        if fd >= 0 {
            if let names = try? enumerateEntries(fd) {
                for n in names { removeTree(p + "/" + String(decoding: n, as: UTF8.self)) }
            }
            _ = close(fd)
        }
        _ = rmdir(p)
    } else {
        _ = unlink(p)
    }
}

// ---------------------------------------------------------------- 測試根目錄
_ = alarm(600)   // 看門狗:整個 runner 超過 10 分鐘(任何阻塞)即被 SIGALRM 終止
var tmpdir = getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp"
while tmpdir.count > 1 && tmpdir.hasSuffix("/") { tmpdir.removeLast() }
var template = cstr(tmpdir + "/k1ctx-tests.XXXXXX") + [0]
let rootC: String? = template.withUnsafeMutableBufferPointer { buf -> String? in
    buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
        mkdtemp(p) == nil ? nil : String(cString: p)
    }
}
guard let ROOT = rootC else { fputs("FATAL: mkdtemp 失敗\n", stdout); exit(1) }
_ = chmod(ROOT, 0o700)
let myUID = getuid()
let otherUID: uid_t = myUID &+ 1
var caseNo = 0
/// 每個案例一個新的 0700 子目錄。
func fresh(_ tag: String) -> String { caseNo += 1; let p = "\(ROOT)/c\(caseNo)-\(tag)"; mkdirp(p); return p }
/// 建立一個有效的 K1 context(0700、marker)並回傳路徑。
func validContext(_ tag: String) -> String {
    let p = fresh(tag)
    let fd = openDirFD(p); expectOK("validContext createMarker \(tag)") { try createMarker(fd, uid: myUID) }; _ = close(fd)
    return p
}

// ================================================================ 1. 路徑語法契約(純字串;零檔案系統)
expectError("syntax 空", .rejected, "context-empty") { try checkContextPathSyntax([]) }
expectError("syntax 相對", .rejected, "context-relative") { try checkContextPathSyntax(cstr("ctx")) }
expectError("syntax 結尾 /", .rejected, "context-noncanonical") { try checkContextPathSyntax(cstr("/a/ctx/")) }
expectError("syntax //", .rejected, "context-noncanonical") { try checkContextPathSyntax(cstr("/a//ctx")) }
expectError("syntax .", .rejected, "context-noncanonical") { try checkContextPathSyntax(cstr("/a/./ctx")) }
expectError("syntax ..", .rejected, "context-noncanonical") { try checkContextPathSyntax(cstr("/a/../ctx")) }
expectError("syntax 根目錄", .rejected, "context-noncanonical") { try checkContextPathSyntax(cstr("/")) }
expectOK("syntax 正規") { try checkContextPathSyntax(cstr("/a/b/ctx.XXXX")) }
// NUL 邊界(owner R6 / R7;sol attempt-002 C-F3):含 0x00 的路徑在任何正規化 / 排除比對 / C 轉換之前即為無效輸入(context-nul),
// 且 NUL 拒絕先於其他語法判定(同一路徑同時含 '..' / '//' / 結尾 '/' 時 token 仍是 context-nul)。純字串判定:探針計數不變。
do {
    let before = cPathConversions
    expectError("syntax NUL(中段)", .rejected, "context-nul") { try checkContextPathSyntax(cstr("/a/b") + [0] + cstr("c")) }
    expectError("syntax NUL(結尾)", .rejected, "context-nul") { try checkContextPathSyntax(cstr("/a/b") + [0]) }
    expectError("syntax 只有 NUL", .rejected, "context-nul") { try checkContextPathSyntax([0]) }
    expectError("syntax NUL 先於 '..' 判定", .rejected, "context-nul") { try checkContextPathSyntax(cstr("/a/../b") + [0]) }
    expectError("syntax NUL 先於 '//' 判定", .rejected, "context-nul") { try checkContextPathSyntax(cstr("/a//b") + [0]) }
    expectError("syntax NUL 先於結尾 '/' 判定", .rejected, "context-nul") { try checkContextPathSyntax(cstr("/a/b/") + [0]) }
    expectError("syntax NUL 先於相對路徑判定", .rejected, "context-nul") { try checkContextPathSyntax([0] + cstr("a")) }
    expectError("syntax '..\\0junk' 成分(C-F3 的根)→ context-nul", .rejected, "context-nul") { try checkContextPathSyntax(cstr("/base/excluded/..") + [0] + cstr("junk")) }
    expectError("scan 路徑 NUL → scan-args(detail 帶 context-nul)", .rejected, "scan-args") { try checkScanPathSyntax(cstr("/a/b") + [0], what: "root") }
    check("NUL 語法判定零 C 字串轉換(探針計數不變)", cPathConversions, before)
}
check("lastComponent", String(decoding: lastComponent(cstr("/a/b/ctx.1")), as: UTF8.self), "ctx.1")
check("escapeBytes", escapeBytes([0x61, 0x20, 0x0a, 0xff, 0x5c]), "a\\x20\\x0a\\xff\\x5c")

// ================================================================ 2. errno 分類(N7)+ context 信任性質
do {
    let base = fresh("errno")
    expectError("ENOENT → 3", .notFound, "context-missing") { _ = try openContext(cstr(base + "/missing"), uid: myUID) }
    expectError("多層 ENOENT → 3", .notFound, "context-missing") { _ = try openContext(cstr(base + "/a/b/ctx"), uid: myUID) }
    writeFile(base + "/plain", cstr("x\n"))
    expectError("上層是一般檔(ENOTDIR 路徑鏈)→ 3", .notFound, "context-missing") { _ = try openContext(cstr(base + "/plain/ctx"), uid: myUID) }
    expectError("最後一段是一般檔 → 2 context-not-dir", .rejected, "context-not-dir") { _ = try openContext(cstr(base + "/plain"), uid: myUID) }
    mkdirp(base + "/real")
    _ = symlink(base + "/real", base + "/link")
    expectError("最後一段是 symlink(→ 目錄)→ 2 context-symlink", .rejected, "context-symlink") { _ = try openContext(cstr(base + "/link"), uid: myUID) }
    _ = symlink(base + "/nowhere", base + "/dangling")
    expectError("dangling symlink → 2 context-symlink", .rejected, "context-symlink") { _ = try openContext(cstr(base + "/dangling"), uid: myUID) }
    _ = symlink(base + "/loopB", base + "/loopA"); _ = symlink(base + "/loopA", base + "/loopB")
    expectError("祖先 symlink 迴圈(ELOOP)→ 1", .operational, "context-inaccessible") { _ = try openContext(cstr(base + "/loopA/ctx"), uid: myUID) }
    mkdirp(base + "/locked"); mkdirp(base + "/locked/ctx"); _ = chmod(base + "/locked", 0o000)
    expectError("上層不可搜尋(EACCES)→ 1,不是 3", .operational, "context-inaccessible") { _ = try openContext(cstr(base + "/locked/ctx"), uid: myUID) }
    expectError("上層不可搜尋下的缺項 → 1(無法證實不存在)", .operational, "context-inaccessible") { _ = try openContext(cstr(base + "/locked/none"), uid: myUID) }
    _ = chmod(base + "/locked", 0o700)
    // F-S2:既存 context 經「目標不可搜尋」的 symlink 祖先 → 1;祖先可搜尋時 symlink 祖先允許
    mkdirp(base + "/open"); _ = symlink(base + "/locked", base + "/open/link")
    _ = chmod(base + "/locked", 0o000)
    expectError("F-S2 既存 context 在不可搜尋的 symlink 祖先之後 → 1", .operational, "context-inaccessible") { _ = try openContext(cstr(base + "/open/link/ctx"), uid: myUID) }
    _ = chmod(base + "/locked", 0o700)
    expectOK("祖先 symlink 可搜尋 → 允許") { let h = try openContext(cstr(base + "/open/link/ctx"), uid: myUID); h.close() }
    mkdirp(base + "/m755", 0o755); _ = chmod(base + "/m755", 0o755)
    expectError("mode 0755 → 2 context-mode", .rejected, "context-mode") { _ = try openContext(cstr(base + "/m755"), uid: myUID) }
    mkdirp(base + "/m1700"); _ = chmod(base + "/m1700", 0o1700)
    expectError("mode 1700(特殊位元)→ 2 context-mode", .rejected, "context-mode") { _ = try openContext(cstr(base + "/m1700"), uid: myUID) }
    expectError("owner ≠ 指定 uid → 2 context-owner", .rejected, "context-owner") { _ = try openContext(cstr(base + "/real"), uid: otherUID) }
    expectOK("有效 0700 目錄 → 開啟") { let h = try openContext(cstr(base + "/real"), uid: myUID); check("fstat 是目錄", h.st.st_mode & S_IFMT, S_IFDIR); h.close() }
    expectError("ACL 以外的開啟失敗:目錄本身 0000 → 1", .operational, "context-inaccessible") {
        mkdirp(base + "/d000"); _ = chmod(base + "/d000", 0o000)
        defer { _ = chmod(base + "/d000", 0o700) }
        _ = try openContext(cstr(base + "/d000"), uid: myUID)
    }
    // NUL 邊界(C-F3 / R7):openContext 對含 NUL 的路徑在任何 open(2) 之前拒絕 —— 探針證明零 C 字串轉換;對照:正常(不存在的)
    // 路徑恰經過一次轉換(open → ENOENT,不另 lstat)。`<real>\0x` 若被截斷成 `<real>` 就會「成功」開啟一個有效 context —— 必須拒絕。
    let before = cPathConversions
    expectError("openContext NUL(有效 context + \\0x)→ context-nul,不是開啟截斷後的目錄", .rejected, "context-nul") { _ = try openContext(cstr(base + "/real") + [0] + cstr("x"), uid: myUID) }
    expectError("openContext NUL(中段)→ context-nul", .rejected, "context-nul") { _ = try openContext(cstr(base) + [0] + cstr("/real"), uid: myUID) }
    check("被拒的 NUL 路徑零 C 字串轉換(探針計數不變)", cPathConversions, before)
    expectError("對照(非虛測):不存在的正規路徑 → ENOENT", .notFound, "context-missing") { _ = try openContext(cstr(base + "/missing2"), uid: myUID) }
    check("對照:正常路徑恰經過一次 C 字串轉換(探針 +1)", cPathConversions, before + 1)
}

// ================================================================ 3. 列舉(N6):隱藏項、任意檔名、只排除 . / ..、錯誤傳播
do {
    let d = fresh("enum")
    writeFile(d + "/.hidden", cstr("h")); writeFile(d + "/normal", cstr("n"))
    // 控制字元、空白、換行、".." 子字串、零寬空白(U+200B)、非 ASCII:APFS 只接受合法 UTF-8(無 '/' / NUL),故不含 0xff。
    let weird: [UInt8] = [0x01, 0x20, 0x0a, 0x2e, 0x2e, 0x78, 0xe2, 0x80, 0x8b, 0xe4, 0xb8, 0xad]
    let fd = openDirFD(d)
    let wfd = withCPath(weird) { openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
    check("建立任意位元組檔名", wfd >= 0, true); _ = close(wfd)
    _ = symlink("/nowhere", d + "/dangling")
    let names = (try? enumerateEntries(fd)) ?? []
    let sorted = names.sorted { $0.lexicographicallyPrecedes($1) }
    let want: [[UInt8]] = [weird, cstr(".hidden"), cstr("dangling"), cstr("normal")].sorted { $0.lexicographicallyPrecedes($1) }
    check("列舉含隱藏項、任意位元組檔名、dangling symlink;不含 . / ..", sorted == want, true)
    check("列舉兩次結果一致(fdopendir(dup) 不消耗原 fd)", (try? enumerateEntries(fd))?.count ?? -1, 4)
    _ = close(fd)
    expectError("已關閉 / 無效 fd → context-enumerate", .operational, "context-enumerate") { _ = try enumerateEntries(fd) }
    let e = fresh("enum-empty"); let efd = openDirFD(e)
    check("空目錄列舉為空", (try? enumerateEntries(efd))?.isEmpty ?? false, true); _ = close(efd)
    // 以 ACL deny-list(等同 chmod +a "<user> deny list";mode 仍 0700、可 cd、可 stat)讓目錄無法被讀取 = 列舉不可能完成 →
    // openContext 回 1(作業失敗),不是 2 也不是 0。ACL 以 libSystem 的 acl_* API 程式化建立;環境不支援時跳過。
    let a = fresh("enum-acl")
    if denyListACL(a) {
        if open(a, O_RDONLY | O_DIRECTORY) < 0 {
            expectError("ACL deny list:無法列舉 → 1 context-inaccessible(零動作)", .operational, "context-inaccessible") { _ = try openContext(cstr(a), uid: myUID) }
            check("ACL deny list 下 mode 仍為 0700(不是權限位元在擋)", lmode(a)?.perm, 0o700)
        } else {
            fputs("SKIP: ACL deny list 未阻止目錄讀取 — 跳過 ACL 列舉案\n", stdout)
        }
        _ = acl_set_file(a, ACL_TYPE_EXTENDED, acl_init(0))
        expectOK("移除 ACL 後可開啟") { let h = try openContext(cstr(a), uid: myUID); h.close() }
    } else {
        fputs("SKIP: 本環境無法設定 ACL — 跳過 ACL 列舉案\n", stdout)
    }
}

// ================================================================ 4. marker 建立(N5 Create):O_CREAT|O_EXCL|O_NOFOLLOW,不跟隨、不阻塞
do {
    let d = fresh("mkmarker"); let fd = openDirFD(d)
    expectOK("空目錄 → 建立 marker") { try createMarker(fd, uid: myUID) }
    check("marker 精確位元組", readFile(d + "/.aipet-kc-context") ?? [], markerBytes(uid: myUID))
    check("marker 0600 一般檔", lmode(d + "/.aipet-kc-context").map { ($0.type == S_IFREG, $0.perm) } ?? (false, 0), (true, 0o600))
    expectError("既存一般檔 → 失敗(O_EXCL),不覆寫", .operational, "marker-create") { try createMarker(fd, uid: myUID) }
    check("既存內容不變", readFile(d + "/.aipet-kc-context") ?? [], markerBytes(uid: myUID))
    _ = unlink(d + "/.aipet-kc-context")
    writeFile(d + "/victim", cstr("VICTIM\n")); _ = symlink(d + "/victim", d + "/.aipet-kc-context")
    expectError("symlink → 一般檔:失敗", .operational, "marker-create") { try createMarker(fd, uid: myUID) }
    check("受害檔不變、symlink 仍是 symlink", (readFile(d + "/victim") ?? [], lmode(d + "/.aipet-kc-context")?.type), (cstr("VICTIM\n"), S_IFLNK))
    _ = unlink(d + "/.aipet-kc-context")
    _ = mkfifo(d + "/fifo", 0o600); _ = symlink(d + "/fifo", d + "/.aipet-kc-context")
    timed("symlink → FIFO(無讀端):立刻失敗、不阻塞", limit: 2.0) { expectError("symlink → FIFO", .operational, "marker-create") { try createMarker(fd, uid: myUID) } }
    _ = unlink(d + "/.aipet-kc-context"); _ = mkfifo(d + "/.aipet-kc-context", 0o600)
    timed("marker 路徑本身是 FIFO:立刻失敗", limit: 2.0) { expectError("FIFO marker", .operational, "marker-create") { try createMarker(fd, uid: myUID) } }
    _ = unlink(d + "/.aipet-kc-context"); mkdirp(d + "/.aipet-kc-context")
    expectError("marker 路徑是目錄:失敗", .operational, "marker-create") { try createMarker(fd, uid: myUID) }
    _ = rmdir(d + "/.aipet-kc-context"); _ = symlink(d + "/nowhere", d + "/.aipet-kc-context")
    expectError("dangling symlink:失敗", .operational, "marker-create") { try createMarker(fd, uid: myUID) }
    check("dangling 目標未被建立", exists(d + "/nowhere"), false)
    _ = unlink(d + "/.aipet-kc-context")
    _ = close(fd)
    // 自訂 token(寫回路徑用)
    let fd2 = openDirFD(d); expectOK("restore token 可用") { try createMarker(fd2, uid: myUID, token: "marker-restore") }; _ = close(fd2)
    // 權限不依賴繼承的 umask(sol attempt-001 D4 / grok NIT2):umask 0777 / 0200 下建立的 marker 仍恰為 0600(fchmod + fstat 複驗),
    // 且能通過 readMarker(同一個驗證端的 0600 要求)
    let du = fresh("mkmarker-umask"); let fdu = openDirFD(du)
    let oldMask = umask(0o777)
    expectOK("umask 0777 下建立 marker") { try createMarker(fdu, uid: myUID) }
    _ = umask(oldMask)
    check("umask 0777 下 marker 仍為 0600", lmode(du + "/.aipet-kc-context")?.perm, 0o600)
    expectOK("umask 0777 下建立的 marker 可被驗證") { try readMarker(fdu, uid: myUID) }
    _ = unlink(du + "/.aipet-kc-context")
    _ = umask(0o200)
    expectOK("umask 0200 下建立 marker") { try createMarker(fdu, uid: myUID) }
    _ = umask(oldMask)
    check("umask 0200 下 marker 仍為 0600(不是 0400)", lmode(du + "/.aipet-kc-context")?.perm, 0o600)
    expectOK("umask 0200 下建立的 marker 可被驗證") { try readMarker(fdu, uid: myUID) }
    _ = close(fdu)
}

// ================================================================ 5. marker 讀取(N5 Read / N14 F-N1):只看開啟到的物件
do {
    let d = validContext("rdmarker"); let fd = openDirFD(d); let m = d + "/.aipet-kc-context"
    expectOK("有效 marker → 通過") { try readMarker(fd, uid: myUID) }
    expectError("owner ≠ 指定 uid → marker-invalid", .rejected, "marker-invalid") { try readMarker(fd, uid: otherUID) }
    _ = unlink(m)
    expectError("缺 marker → marker-missing", .rejected, "marker-missing") { try readMarker(fd, uid: myUID) }
    // F-N1 決定性重現:先做「較早的 metadata 觀察」(lstat 說它是一般檔),再置換成敵意物件,原生讀取必須以「這次 open 到的物件」拒絕
    func swapAndRead(_ name: String, plant: () -> Void, token: String) {
        writeFile(m, markerBytes(uid: myUID)); _ = chmod(m, 0o600)
        check("F-N1 \(name):較早的觀察看到一般檔 marker", lmode(m)?.type, S_IFREG)
        _ = unlink(m); plant()
        timed("F-N1 \(name):原生讀取不阻塞", limit: 2.0) { expectError("F-N1 \(name)", .rejected, token) { try readMarker(fd, uid: myUID) } }
        _ = unlink(m); _ = rmdir(m)
    }
    swapAndRead("換成 FIFO(無寫端)", plant: { _ = mkfifo(m, 0o600) }, token: "marker-type")
    _ = mkfifo(d + "/../rdfifo", 0o600)
    swapAndRead("換成 symlink → FIFO", plant: { _ = symlink(d + "/../rdfifo", m) }, token: "marker-type")
    writeFile(d + "/../rdgood", markerBytes(uid: myUID)); _ = chmod(d + "/../rdgood", 0o600)
    swapAndRead("換成 symlink → 內容正確的不相關檔(不得讀到它)", plant: { _ = symlink(d + "/../rdgood", m) }, token: "marker-type")
    swapAndRead("換成目錄", plant: { mkdirp(m) }, token: "marker-type")
    swapAndRead("換成 0644 的一般檔", plant: { writeFile(m, markerBytes(uid: myUID), 0o644) }, token: "marker-invalid")
    swapAndRead("換成多一個位元組", plant: { writeFile(m, markerBytes(uid: myUID) + cstr("x")) }, token: "marker-invalid")
    swapAndRead("換成同長度錯內容(v2)", plant: { writeFile(m, cstr("aipet-kc-context v2\nuid=\(myUID)\n")) }, token: "marker-invalid")
    swapAndRead("換成 uid 不同的內容", plant: { writeFile(m, cstr("aipet-kc-context v1\nuid=\(otherUID)\n")) }, token: "marker-invalid")
    swapAndRead("換成含 NUL 的內容", plant: { writeFile(m, cstr("aipet-kc-context v1\nuid=\(myUID)\n") + [0, 0x6a]) }, token: "marker-invalid")
    swapAndRead("換成空檔", plant: { writeFile(m, []) }, token: "marker-invalid")
    _ = close(fd); _ = unlink(d + "/../rdfifo"); _ = unlink(d + "/../rdgood")
}

// ================================================================ 6. 白名單判定
do {
    let d = validContext("allow"); let fd = openDirFD(d)
    writeFile(d + "/signing.keychain-db", cstr("FAKE-KEYCHAIN v1\n")); writeFile(d + "/p12.tmp", cstr("x"))
    let rep = try? classifyEntries(fd, try enumerateEntries(fd))
    check("三個白名單項目皆一般檔 → present = keychain + p12", rep?.present.sorted { $0.lexicographicallyPrecedes($1) } ?? [], [cstr("p12.tmp"), cstr("signing.keychain-db")])
    writeFile(d + "/user-file.txt", cstr("x"))
    expectError("白名單以外 → unexpected-entry", .rejected, "unexpected-entry") { _ = try classifyEntries(fd, try enumerateEntries(fd)) }
    _ = unlink(d + "/user-file.txt"); _ = unlink(d + "/signing.keychain-db"); _ = symlink("/etc/hosts", d + "/signing.keychain-db")
    expectError("keychain 是 symlink → entry-type", .rejected, "entry-type") { _ = try classifyEntries(fd, try enumerateEntries(fd)) }
    _ = unlink(d + "/signing.keychain-db"); _ = unlink(d + "/p12.tmp"); mkdirp(d + "/p12.tmp")
    expectError("p12.tmp 是目錄 → entry-type", .rejected, "entry-type") { _ = try classifyEntries(fd, try enumerateEntries(fd)) }
    _ = rmdir(d + "/p12.tmp"); _ = mkfifo(d + "/signing.keychain-db", 0o600)
    timed("keychain 是 FIFO → entry-type(fstatat,不開啟、不阻塞)", limit: 2.0) { expectError("FIFO keychain", .rejected, "entry-type") { _ = try classifyEntries(fd, try enumerateEntries(fd)) } }
    _ = unlink(d + "/signing.keychain-db")
    let hidden: [UInt8] = cstr(".aipet-kc-context") + [0x20]   // 名稱只差一個空白 → 不是白名單
    let hfd = withCPath(hidden) { openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }; _ = close(hfd)
    expectError("近似名稱(多一個空白)→ unexpected-entry", .rejected, "unexpected-entry") { _ = try classifyEntries(fd, try enumerateEntries(fd)) }
    _ = withCPath(hidden) { unlinkat(fd, $0, 0) }
    _ = close(fd)
}

// ================================================================ 7. base64(嚴格)
check("b64 空", decodeBase64Strict([]) ?? [1], [])
check("b64 Zg==", decodeBase64Strict(cstr("Zg==")) ?? [], cstr("f"))
check("b64 Zm8=", decodeBase64Strict(cstr("Zm8=")) ?? [], cstr("fo"))
check("b64 Zm9v", decodeBase64Strict(cstr("Zm9v")) ?? [], cstr("foo"))
check("b64 Zm9vYg==", decodeBase64Strict(cstr("Zm9vYg==")) ?? [], cstr("foob"))
check("b64 容許換行 / 空白", decodeBase64Strict(cstr("Zm9v\nYmFy\r\n Yg==\n")) ?? [], cstr("foobarb"))
check("b64 未填充 → 拒絕", decodeBase64Strict(cstr("Zm9")) == nil, true)
check("b64 單一 = → 拒絕", decodeBase64Strict(cstr("Zm9v=")) == nil, true)
check("b64 非法字元 → 拒絕", decodeBase64Strict(cstr("Zm9v!!!!")) == nil, true)
check("b64 填充後有資料 → 拒絕", decodeBase64Strict(cstr("Zg==Zg==")) == nil, true)
check("b64 三個填充 → 拒絕", decodeBase64Strict(cstr("Z===")) == nil, true)
check("b64 只有填充 → 拒絕", decodeBase64Strict(cstr("====")) == nil, true)
check("b64 x=y= → 拒絕", decodeBase64Strict(cstr("Zm=v")) == nil, true)
check("b64 只有空白 → 空", decodeBase64Strict(cstr("   \n")) ?? [1], [])
check("b64 二進位往返", decodeBase64Strict(cstr("AAECA/7/")) ?? [], [0, 1, 2, 3, 0xfe, 0xff])

// ================================================================ 8. P12 建立 / 移除(N8)
do {
    let d = validContext("p12"); let fd = openDirFD(d); let p = d + "/p12.tmp"
    expectError("空內容 → p12-decode(拒絕,不留檔)", .rejected, "p12-decode") { try materializeP12(fd, []) }
    check("空內容不留 p12.tmp", exists(p), false)
    expectOK("正常建立") { try materializeP12(fd, cstr("P12-BYTES-OK")) }
    check("內容、0600、一般檔", (readFile(p) ?? [], lmode(p)?.perm, lmode(p)?.type), (cstr("P12-BYTES-OK"), 0o600, S_IFREG))
    expectError("已存在 → p12-path(O_EXCL,不覆寫)", .operational, "p12-path") { try materializeP12(fd, cstr("AGAIN")) }
    check("既存內容未被覆寫", readFile(p) ?? [], cstr("P12-BYTES-OK"))
    expectOK("remove → 消失") { try removeP12(fd) }
    check("remove 後不存在", exists(p), false)
    expectOK("remove 不存在 → 仍成功(冪等)") { try removeP12(fd) }
    writeFile(d + "/../victim-p12", cstr("VICTIM\n")); _ = symlink(d + "/../victim-p12", p)
    expectError("symlink → 一般檔:p12-path", .operational, "p12-path") { try materializeP12(fd, cstr("X")) }
    check("受害檔不變", readFile(d + "/../victim-p12") ?? [], cstr("VICTIM\n"))
    expectOK("remove 對 symlink 只刪連結") { try removeP12(fd) }
    check("受害檔仍在、連結消失", (exists(d + "/../victim-p12"), exists(p)), (true, false))
    _ = symlink("/dev/null", p)
    expectError("symlink → /dev/null:p12-path(不跟隨)", .operational, "p12-path") { try materializeP12(fd, cstr("X")) }
    _ = unlink(p); _ = symlink(d + "/../would-be-created", p)
    expectError("dangling symlink:p12-path", .operational, "p12-path") { try materializeP12(fd, cstr("X")) }
    check("dangling 目標未被建立", exists(d + "/../would-be-created"), false)
    _ = unlink(p); _ = mkfifo(p, 0o600)
    timed("FIFO 佔用:p12-path、不阻塞", limit: 2.0) { expectError("FIFO p12", .operational, "p12-path") { try materializeP12(fd, cstr("X")) } }
    _ = unlink(p)
    // unlink 失敗(uchg)→ p12-unlink;解除後可刪
    writeFile(p, cstr("locked"))
    if chflags(p, UInt32(UF_IMMUTABLE)) == 0 {
        expectError("uchg 的 p12.tmp → p12-unlink(作業失敗)", .operational, "p12-unlink") { try removeP12(fd) }
        check("p12.tmp 仍在", exists(p), true)
        _ = chflags(p, 0)
        expectOK("解除 uchg 後 remove 成功") { try removeP12(fd) }
    } else {
        fputs("SKIP: chflags uchg 不可用 — 跳過 P12 unlink 失敗案\n", stdout); _ = unlink(p)
    }
    // 權限不依賴繼承的 umask(sol attempt-001 D4):umask 0777 下建立的 p12.tmp 仍恰為 0600
    let oldMaskP = umask(0o777)
    expectOK("umask 0777 下建立 P12") { try materializeP12(fd, cstr("X")) }
    _ = umask(oldMaskP)
    check("umask 0777 下 p12.tmp 仍為 0600", lmode(p)?.perm, 0o600)
    expectOK("umask 案收尾 remove") { try removeP12(fd) }
    _ = close(fd); _ = unlink(d + "/../victim-p12")
}

// ================================================================ 9. marker 刪除 + rmdir(父目錄 fd + dev:inode 身分)
do {
    let parent = fresh("fin"); let c = parent + "/ctx"; mkdirp(c)
    var h = try! openContext(cstr(c), uid: myUID)
    expectOK("marker") { try createMarker(h.fd, uid: myUID) }
    expectOK("正常 finalize") { try removeMarkerAndContext(h, path: cstr(c), uid: myUID) }
    check("context 消失", exists(c), false); h.close()
    // 上層不可寫 → rmdir 失敗 → marker 原樣寫回、context 保留
    mkdirp(c); h = try! openContext(cstr(c), uid: myUID); expectOK("marker2") { try createMarker(h.fd, uid: myUID) }
    _ = chmod(parent, 0o500)
    expectError("上層 0500 → rmdir 失敗", .operational, "rmdir") { try removeMarkerAndContext(h, path: cstr(c), uid: myUID) }
    _ = chmod(parent, 0o700)
    check("context 保留且 marker 已寫回(精確位元組、0600)", (readFile(c + "/.aipet-kc-context") ?? [], lmode(c + "/.aipet-kc-context")?.perm), (markerBytes(uid: myUID), 0o600))
    expectOK("修復後重試成功") { try removeMarkerAndContext(h, path: cstr(c), uid: myUID) }; h.close()
    check("重試後 context 消失", exists(c), false)
    // 仍有內容 → rmdir ENOTEMPTY → 寫回
    mkdirp(c); h = try! openContext(cstr(c), uid: myUID); expectOK("marker3") { try createMarker(h.fd, uid: myUID) }
    writeFile(c + "/leftover", cstr("x"))
    expectError("仍有內容 → rmdir 失敗(ENOTEMPTY),不遞迴", .operational, "rmdir") { try removeMarkerAndContext(h, path: cstr(c), uid: myUID) }
    check("leftover 原封不動、marker 寫回", (exists(c + "/leftover"), readFile(c + "/.aipet-kc-context") ?? []), (true, markerBytes(uid: myUID)))
    _ = unlink(c + "/leftover"); h.close()
    // 身分不符:開啟 handle 後把 context 改名、放一個同名的冒牌目錄 → 必須拒絕,冒牌目錄不被移除,marker 寫回原目錄
    h = try! openContext(cstr(c), uid: myUID)
    _ = rename(c, parent + "/moved"); mkdirp(c); writeFile(c + "/impostor-data", cstr("keep"))
    expectError("父目錄中同名項目不是這個 context(dev:inode 不符)→ rmdir 失敗", .operational, "rmdir") { try removeMarkerAndContext(h, path: cstr(c), uid: myUID) }
    check("冒牌目錄與其內容原封不動;marker 寫回被移走的原目錄", (exists(c + "/impostor-data"), readFile(parent + "/moved/.aipet-kc-context") ?? []), (true, markerBytes(uid: myUID)))
    h.close()
    // 「空的」冒牌目錄(grok / sol attempt-001 NIT):rmdir 本身對空目錄會成功,只有 dev:inode 比對能擋 → 必須失敗(token rmdir)、
    // 空的冒牌目錄仍存在、marker 寫回被移走的原目錄(非空冒牌案保留在上面,它額外證明永不遞迴)
    _ = unlink(c + "/impostor-data"); _ = rmdir(c); removeTree(parent + "/moved")
    mkdirp(c); h = try! openContext(cstr(c), uid: myUID); expectOK("marker-empty-impostor") { try createMarker(h.fd, uid: myUID) }
    _ = rename(c, parent + "/moved2"); mkdirp(c)
    check("前提(非虛測):冒牌目錄為空、與 handle 的 dev:inode 不同", (((try? enumerateEntries(openDirFD(c))) ?? [[0]]).isEmpty, lmode(c)?.type), (true, S_IFDIR))
    expectError("空的冒牌目錄 → 只靠 dev:inode 比對擋下(rmdir 失敗)", .operational, "rmdir") { try removeMarkerAndContext(h, path: cstr(c), uid: myUID) }
    check("空的冒牌目錄仍存在;marker 寫回被移走的原目錄", (exists(c), readFile(parent + "/moved2/.aipet-kc-context") ?? []), (true, markerBytes(uid: myUID)))
    h.close(); _ = rmdir(c); removeTree(parent + "/moved2"); mkdirp(c)
    // 寫回失敗:rmdir 失敗後 marker 路徑被 symlink→FIFO 佔用 → 明說、不阻塞
    let c2 = parent + "/ctx2"; mkdirp(c2); h = try! openContext(cstr(c2), uid: myUID); expectOK("marker4") { try createMarker(h.fd, uid: myUID) }
    _ = chmod(parent, 0o500)
    // 先以 unlinkat 模擬「marker 已被 K1 刪除」後的競爭:實際函式會自己 unlink;這裡改讓 rmdir 失敗後的寫回遇到佔用 ——
    // 做法:在 parent 0500 下呼叫一次(寫回成功),再把寫回的 marker 換成 symlink→FIFO,第二次呼叫的 unlink 會刪掉 symlink
    // 本身(不跟隨),rmdir 仍失敗,寫回成功 —— 所以要證明「寫回遇到佔用時不阻塞」改用直接呼叫 createMarker(第 4 節已證)。
    expectError("寫回路徑:上層 0500 → rmdir 失敗、marker 寫回", .operational, "rmdir") { try removeMarkerAndContext(h, path: cstr(c2), uid: myUID) }
    _ = chmod(parent, 0o700); h.close()
    // NUL 邊界(C-F3 / R6):程式庫被直接呼叫、path 含 NUL → 在任何動作之前拒絕(marker 仍在、零 C 字串轉換);對照:同一 handle 以
    // 正規路徑 finalize 成功。
    let c3 = parent + "/ctx3"; mkdirp(c3); h = try! openContext(cstr(c3), uid: myUID); expectOK("marker5") { try createMarker(h.fd, uid: myUID) }
    let before = cPathConversions
    expectError("removeMarkerAndContext 直接呼叫、path 含 NUL → context-nul", .rejected, "context-nul") { try removeMarkerAndContext(h, path: cstr(c3) + [0] + cstr("x"), uid: myUID) }
    check("NUL path:零動作(marker 仍在、context 仍在)、零 C 字串轉換", (readFile(c3 + "/.aipet-kc-context") ?? [], exists(c3), cPathConversions), (markerBytes(uid: myUID), true, before))
    expectOK("對照:正規路徑 finalize 成功") { try removeMarkerAndContext(h, path: cstr(c3), uid: myUID) }
    check("對照:context 消失", exists(c3), false); h.close()
}

// ================================================================ 10. 秘密衛生掃描(N9 / N15 F-N2)
do {
    let t = fresh("scan"); mkdirp(t + "/ok"); mkdirp(t + "/locked"); mkdirp(t + "/locked/deep")
    writeFile(t + "/ok/a.txt", cstr("clean\n")); writeFile(t + "/ok/.hidden", cstr("also clean"))
    writeFile(t + "/locked/deep/leak.txt", cstr("xx SENTINEL-ONE yy\n"))
    var lines: [String] = []
    func scan(_ roots: [String], excludes: [String] = [], sentinels: [String] = ["SENTINEL-ONE"]) -> ScanSummary {
        lines = []
        return scanSecrets(roots: roots.map(cstr), excludes: excludes.map(cstr), sentinels: sentinels.map(cstr)) { lines.append($0) }
    }
    var s = scan([t])
    check("可讀樹 + 深層 sentinel → SECRET_FOUND(2)", (s.status, s.exitStatus, s.matches, s.files, s.dirs, s.errors), ("SECRET_FOUND", .rejected, 1, 3, 4, 0))
    check("MATCH 行指向 leak.txt", lines.contains("MATCH \(escapeBytes(cstr(t + "/locked/deep/leak.txt")))"), true)
    _ = chmod(t + "/locked", 0o000)
    s = scan([t])
    check("F-N2 不可走訪的子樹 + 其下 sentinel → INCOMPLETE_SCAN(1),不是 CLEAN", (s.status, s.exitStatus, s.errors, s.matches), ("INCOMPLETE_SCAN", .operational, 1, 0))
    check("F-N2 ERROR 行指名 locked", lines.contains { $0.hasPrefix("ERROR EACCES opendir ") && $0.hasSuffix("/locked") }, true)
    _ = chmod(t + "/locked", 0o700)
    _ = chmod(t + "/locked/deep/leak.txt", 0o000)
    s = scan([t])
    check("不可讀的檔 → INCOMPLETE_SCAN(unreadable item = FAIL)", (s.status, s.errors), ("INCOMPLETE_SCAN", 1))
    _ = chmod(t + "/locked/deep/leak.txt", 0o600)
    s = scan([t], excludes: [t + "/locked"])
    check("明確排除子樹 → CLEAN、excluded=1、該子樹未被走訪", (s.status, s.excluded, s.dirs, s.files), ("CLEAN", 1, 2, 2))
    _ = unlink(t + "/locked/deep/leak.txt")
    _ = mkfifo(t + "/fifo", 0o600)
    timed("FIFO 不阻塞掃描", limit: 3.0) { s = scan([t]) }
    check("FIFO 計為 special、不是檔案、CLEAN", (s.status, s.special, s.files), ("CLEAN", 1, 2))
    writeFile(t + "/../outside-secret", cstr("SENTINEL-ONE")); _ = symlink(t + "/../outside-secret", t + "/lnk")
    s = scan([t])
    check("symlink 不跟隨(目標含 sentinel 也不算)、計為 symlink", (s.status, s.symlinks), ("CLEAN", 1))
    _ = unlink(t + "/lnk"); _ = unlink(t + "/../outside-secret"); _ = unlink(t + "/fifo")
    // 跨塊邊界的 sentinel
    var big = [UInt8](repeating: 0x41, count: 65536 - 5); big += cstr("SENTINEL-ONE"); big += [UInt8](repeating: 0x42, count: 1000)
    writeFile(t + "/ok/big.bin", big)
    s = scan([t])
    check("sentinel 跨 64 KiB 塊邊界仍命中", (s.status, s.matches), ("SECRET_FOUND", 1))
    _ = unlink(t + "/ok/big.bin")
    s = scan([t], sentinels: ["SENTINEL-ONE", "OTHER-SENT"])
    check("多個 sentinel、無命中 → CLEAN", s.status, "CLEAN")
    writeFile(t + "/ok/SENTINEL-ONE.txt", cstr("name only\n"))
    s = scan([t]); check("sentinel 只在檔名 → 不算內容命中(凍結政策)", s.status, "CLEAN"); _ = unlink(t + "/ok/SENTINEL-ONE.txt")
    s = scan([t + "/missing"])
    check("不存在的根 → INCOMPLETE_SCAN(error),絕不 CLEAN", (s.status, s.errors), ("INCOMPLETE_SCAN", 1))
    s = scan([t + "/ok/a.txt"])
    check("根是一般檔 → error", (s.status, s.errors), ("INCOMPLETE_SCAN", 1))
    s = scan([t, t + "/ok"])
    check("多根:計數累加、完整", (s.status, s.dirs, s.files), ("CLEAN", 5, 4))
    // 路徑語法契約(sol attempt-001 D1):根 / 排除須為絕對正規路徑 —— 非正規拼法在程式庫層記為 ERROR(INCOMPLETE_SCAN,絕非 CLEAN),
    // 在 CLI 層以 scan-args 拒絕;正規拼法下同一情境確實找到 sentinel;根在排除子樹內 → excluded(與子項目一致)
    expectError("根路徑含 '..' → scan-args", .rejected, "scan-args") { try checkScanPathSyntax(cstr(t + "/locked/../ok"), what: "root") }
    expectError("排除路徑結尾 '/' → scan-args", .rejected, "scan-args") { try checkScanPathSyntax(cstr(t + "/locked/"), what: "exclude") }
    expectError("相對路徑 → scan-args", .rejected, "scan-args") { try checkScanPathSyntax(cstr("relative"), what: "root") }
    expectError("根目錄 '/' → scan-args", .rejected, "scan-args") { try checkScanPathSyntax(cstr("/"), what: "root") }
    expectOK("正規路徑通過") { try checkScanPathSyntax(cstr(t + "/ok"), what: "root") }
    mkdirp(t + "/excluded"); mkdirp(t + "/intended"); writeFile(t + "/intended/leak", cstr("SENTINEL-ONE"))
    s = scan([t + "/excluded/../intended"], excludes: [t + "/excluded"])
    check("sol D1 情境(非正規根 + 排除同前綴)→ INCOMPLETE_SCAN,files=0,絕非 CLEAN", (s.status, s.errors, s.files, s.excluded), ("INCOMPLETE_SCAN", 1, 0, 0))
    check("sol D1 情境:報告 ERROR SYNTAX root", lines.contains { $0.hasPrefix("ERROR SYNTAX root ") }, true)
    s = scan([t + "/intended"], excludes: [t + "/excluded"])
    check("正規拼法:排除不相干子樹仍找到 sentinel", (s.status, s.matches, s.excluded), ("SECRET_FOUND", 1, 0))
    s = scan([t + "/intended"], excludes: [t + "/excluded/../intended"])
    check("非正規的排除路徑 → INCOMPLETE_SCAN(排除清單不可信,不掃)", (s.status, s.errors, s.files), ("INCOMPLETE_SCAN", 1, 0))
    mkdirp(t + "/excluded/sub")
    s = scan([t + "/excluded/sub"], excludes: [t + "/excluded"])
    check("根在排除子樹內 → excluded=1、CLEAN、未開啟", (s.status, s.excluded, s.dirs), ("CLEAN", 1, 0))
    s = scan([t + "/intended"], excludes: [t + "/intend"])
    check("排除只在路徑成分邊界比對('/intend' 不排除 '/intended')", (s.status, s.matches), ("SECRET_FOUND", 1))
    _ = unlink(t + "/intended/leak")
    // NUL 邊界(sol attempt-002 C-F3 / owner R6 / R7):根 `<nb>/excluded/..\0junk` 的位元組前綴比對 ≠ `..`、不會被排除,但 C 字串
    // 邊界會把它截成 `<nb>/excluded/..` = `<nb>` —— sentinel(<nb>/leak)在排除子樹之外。程式庫必須在任何排除比對 / 開啟之前以
    // 語法錯誤拒絕(INCOMPLETE_SCAN、excluded=0、零 C 字串轉換),絕不 CLEAN;含 NUL 的排除路徑同樣讓整個掃描 INCOMPLETE。
    let nb = t + "/nulcase"; mkdirp(nb); mkdirp(nb + "/excluded"); writeFile(nb + "/leak", cstr("SENTINEL-ONE"))
    s = scan([nb], excludes: [nb + "/excluded"])
    check("C-F3 對照(非虛測):正規根 + 排除 → SECRET_FOUND、matches=1、excluded=1", (s.status, s.matches, s.excluded, s.files), ("SECRET_FOUND", 1, 1, 1))
    let before = cPathConversions
    s = scan([nb + "/excluded/..\u{0}junk"], excludes: [nb + "/excluded"])
    check("C-F3:NUL 根 → INCOMPLETE_SCAN、errors=1、excluded=0、files=0、dirs=0,絕非 CLEAN", (s.status, s.errors, s.excluded, s.files, s.dirs, s.matches), ("INCOMPLETE_SCAN", 1, 0, 0, 0, 0))
    check("C-F3:報告 ERROR SYNTAX root(detail 經 escapeBytes 顯示 \\x00)", lines.contains { $0.hasPrefix("ERROR SYNTAX root ") && $0.contains("\\x00junk") }, true)
    check("C-F3:被拒的 NUL 根零 C 字串轉換(探針計數不變)", cPathConversions, before)
    s = scan([nb], excludes: [nb + "/excluded\u{0}x"])
    check("含 NUL 的排除路徑 → INCOMPLETE_SCAN、files=0(排除清單不可信,不掃)、ERROR SYNTAX exclude", (s.status, s.files, s.errors >= 1, lines.contains { $0.hasPrefix("ERROR SYNTAX exclude ") }), ("INCOMPLETE_SCAN", 0, true, true))
    check("含 NUL 的排除路徑零 C 字串轉換(探針計數不變)", cPathConversions, before)
    s = scan([nb + "\u{0}"], excludes: [])
    check("結尾 NUL 的根 → INCOMPLETE_SCAN(不是截斷後的 <nb> → SECRET_FOUND)", (s.status, s.matches, s.errors), ("INCOMPLETE_SCAN", 0, 1))
    _ = unlink(nb + "/leak")
    // 深度上限 → error(INCOMPLETE),不是靜默截斷
    var deep = t + "/deep"; mkdirp(deep)
    for _ in 0..<(scanMaxDepth + 2) { deep += "/d"; mkdirp(deep) }
    s = scan([t + "/deep"])
    check("超過深度上限 → INCOMPLETE_SCAN(DEPTH error)", (s.status, s.errors >= 1, lines.contains { $0.hasPrefix("ERROR DEPTH ") }), ("INCOMPLETE_SCAN", true, true))
    check("summary 行格式", s.line.hasPrefix("summary files=") && s.line.hasSuffix("status=INCOMPLETE_SCAN"), true)
}

// ================================================================ 11. K5 顯式 keychain 路徑的物件形狀(原生;shell 不再做 metadata 檢視 — sol attempt-001 D3)
do {
    let d = fresh("kcpath")
    writeFile(d + "/dev.keychain-db", cstr("FAKE-KEYCHAIN v1\n"))
    expectOK("既存一般檔 → 通過") { try checkKeychainPath(cstr(d + "/dev.keychain-db")) }
    expectError("相對路徑 → keychain-path(2)", .rejected, "keychain-path") { try checkKeychainPath(cstr("dev.keychain-db")) }
    expectError("結尾 '/' → keychain-path(2)", .rejected, "keychain-path") { try checkKeychainPath(cstr(d + "/dev.keychain-db/")) }
    expectError("不存在 → keychain-path(2)", .rejected, "keychain-path") { try checkKeychainPath(cstr(d + "/missing.keychain-db")) }
    expectError("上層是一般檔(ENOTDIR)→ keychain-path(2)", .rejected, "keychain-path") { try checkKeychainPath(cstr(d + "/dev.keychain-db/x")) }
    _ = symlink(d + "/dev.keychain-db", d + "/link.keychain-db")
    expectError("symlink → 一般檔:keychain-path(2),不跟隨", .rejected, "keychain-path") { try checkKeychainPath(cstr(d + "/link.keychain-db")) }
    mkdirp(d + "/dir.keychain-db")
    expectError("目錄 → keychain-path(2)", .rejected, "keychain-path") { try checkKeychainPath(cstr(d + "/dir.keychain-db")) }
    _ = mkfifo(d + "/fifo.keychain-db", 0o600)
    timed("FIFO(無寫端)→ keychain-path(2),不阻塞", limit: 2.0) { expectError("FIFO keychain", .rejected, "keychain-path") { try checkKeychainPath(cstr(d + "/fifo.keychain-db")) } }
    _ = chmod(d + "/dev.keychain-db", 0o000)
    expectError("不可讀的既存檔 → keychain-path(1,無法判定)", .operational, "keychain-path") { try checkKeychainPath(cstr(d + "/dev.keychain-db")) }
    _ = chmod(d + "/dev.keychain-db", 0o600)
    check("檢查不改變檔案", readFile(d + "/dev.keychain-db") ?? [], cstr("FAKE-KEYCHAIN v1\n"))
    // NUL 邊界(C-F3 / R6):`<既存一般檔>\0x` 若被截斷就會通過 —— 必須在任何 open(2) 之前拒絕(零 C 字串轉換)
    let before = cPathConversions
    expectError("NUL(既存檔 + \\0x)→ keychain-path(2),不是截斷後的通過", .rejected, "keychain-path") { try checkKeychainPath(cstr(d + "/dev.keychain-db") + [0] + cstr("x")) }
    check("被拒的 NUL keychain 路徑零 C 字串轉換", cPathConversions, before)
    expectOK("對照:同一既存檔的正規路徑仍通過") { try checkKeychainPath(cstr(d + "/dev.keychain-db")) }
}

// ================================================================ 收尾
removeTree(ROOT)
check("測試根目錄已移除", exists(ROOT), false)
let total = passCount + failCount
if failCount == 0 && total > 0 {
    print("k1-native tests: PASS (\(total) checks)")
    exit(0)
}
print("k1-native tests: FAIL (\(failCount) of \(total) checks failed)")
exit(1)
