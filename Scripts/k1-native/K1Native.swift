// K1Native.swift — K1-NATIVE:K1 私有 context 的「原生」檔案系統 / 安全操作核心(release 工具,非 App runtime)。
//
// 責任模型(owner K1-NATIVE N1,凍結):所有安全敏感的 context / 檔案系統行為都在這裡 —— marker 的建立 / 讀取 / 寫回、
// context 列舉與白名單判定、解碼 P12 的建立 / 移除、context 的最後移除(rmdir)、秘密衛生掃描。Shell 只負責編排(呼叫本
// 工具、Apple 的 security / codesign),不得自行檢視或改動 context 內部。
//
// 描述符相對的 context 權威(N4):每個命令先以 open(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC) 開啟 context 目錄,之後
// 一切敏感操作都相對於「這個已開啟、已驗證(fstat:目錄、owner uid、權限恰 0700)的目錄描述符」進行 —— openat / fstatat /
// unlinkat / fdopendir(dup(fd))。沒有任何「先 stat(path) 再 open(path)」的安全依據;安全擁有的檔案(marker、p12.tmp)在最後
// 一段一律禁止跟隨 symlink(O_NOFOLLOW),讀取一律 O_NONBLOCK(FIFO 永不阻塞),且在 open 之後對「同一個已開啟物件」做 fstat
// 判定型別 / owner / 權限 / 大小,再從該 fd 讀取。
//
// 威脅模型(N12):K1 防禦的是「在操作邊界存在的」畸形 / 過期 / 敵意檔案系統輸入,以及描述符相對操作所涵蓋的一般失敗 /
// 競爭情形。K1「不」宣稱能防禦一個已被入侵、同 uid、在整個生命週期中具備任意 syscall 競爭能力的惡意行程(它能在
// 任一步驟之間換掉 Apple CLI 會依路徑開啟的 keychain 檔);此排除不得用來放行可避免的 TOCTOU 錯誤 —— 凡平台 API 允許以
// 描述符相對完成的操作,本檔一律以描述符相對完成。
//
// 退出碼(N7,凍結):0 成功;1 作業失敗(EACCES / ELOOP / I/O / 無法判定 / 列舉不完整);2 拒絕(空 / 相對路徑、既存但違反
// 信任契約、參數錯誤);3 CONTEXT_NOT_FOUND(只在 ENOENT,或路徑鏈中的 ENOTDIR 證明該 context 不可能存在)。
//
// 秘密:P12 內容只經 stdin(pipe)以 base64 文字進入本行程,在行程內解碼後以 O_CREAT|O_EXCL|O_NOFOLLOW、0600 寫進
// context;從不進 argv / 環境 / log / stdout / stderr。本檔不印任何檔案內容;診斷只印 token、errno 與(逸出後的)檔名。
//
// 只用 Darwin(libSystem);不用 Foundation、不下載任何相依。
import Darwin

// MARK: - 狀態 / 錯誤

/// 凍結的退出碼語意。
public enum K1Status: Int32 {
    case ok = 0
    case operational = 1   // 作業失敗 / 無法判定(零動作或已明說的部分動作)
    case rejected = 2      // 拒絕(契約違反、參數錯誤;零動作)
    case notFound = 3      // CONTEXT_NOT_FOUND(只在 errno 可證實不存在;零動作)

    public var word: String {
        switch self {
        case .ok: return "OK"
        case .operational: return "FAILED"
        case .rejected: return "REJECTED"
        case .notFound: return "CONTEXT_NOT_FOUND"
        }
    }
}

/// 每個失敗都帶一個固定詞彙的 token(機器可讀;shell adapter 與測試以 token 判定分支)與一段人讀診斷。
public struct K1Error: Error {
    public let status: K1Status
    public let token: String
    public let detail: String
    public init(_ status: K1Status, _ token: String, _ detail: String) {
        self.status = status; self.token = token; self.detail = detail
    }
}

// MARK: - errno

/// 常見 errno 的符號名稱(診斷與測試用;未列者印 E<數字>)。
public func errnoName(_ e: Int32) -> String {
    switch e {
    case EPERM: return "EPERM"
    case ENOENT: return "ENOENT"
    case EIO: return "EIO"
    case ENXIO: return "ENXIO"
    case EBADF: return "EBADF"
    case EACCES: return "EACCES"
    case EEXIST: return "EEXIST"
    case ENOTDIR: return "ENOTDIR"
    case EISDIR: return "EISDIR"
    case EINVAL: return "EINVAL"
    case ENFILE: return "ENFILE"
    case EMFILE: return "EMFILE"
    case ENOTEMPTY: return "ENOTEMPTY"
    case ELOOP: return "ELOOP"
    case ENAMETOOLONG: return "ENAMETOOLONG"
    case EINTR: return "EINTR"
    case EAGAIN: return "EAGAIN"
    case EOPNOTSUPP: return "EOPNOTSUPP"
    case EROFS: return "EROFS"
    case EBUSY: return "EBUSY"
    case ENOSPC: return "ENOSPC"
    case EFBIG: return "EFBIG"
    case ETIMEDOUT: return "ETIMEDOUT"
    default: return "E\(e)"
    }
}

public func describeErrno(_ e: Int32) -> String {
    let msg = String(cString: strerror(e))
    return "\(errnoName(e)) (\(e)): \(msg)"
}

// MARK: - 位元組字串工具

/// 檔名 / 路徑以「位元組」處理(不假設 UTF-8);診斷時把非可印 ASCII 逸出為 \xNN。
public func escapeBytes(_ b: [UInt8]) -> String {
    var s = ""
    for c in b {
        if c >= 0x21 && c <= 0x7e && c != 0x5c {
            s.append(Character(UnicodeScalar(c)))
        } else {
            let hex = String(c, radix: 16)
            s += "\\x" + (hex.count == 1 ? "0" + hex : hex)
        }
    }
    return s
}

/// 探針計數器:每次 withCPath(= 每次「位元組 → C 字串」的 syscall 面轉換)+1。測試以它證明「被拒的含 NUL 輸入從未到達任何
/// C / POSIX 轉換」(owner R7);生產路徑只遞增、從不讀取。
var cPathConversions = 0

/// 以 NUL 結尾的 C 字串呼叫 body(位元組原樣,不經任何正規化)。呼叫端必須先通過 checkContextPathSyntax(拒絕內嵌 NUL):
/// 內嵌 NUL 會讓 C 字串在該處截斷,使 syscall 看到的路徑 ≠ 位元組所指的路徑(sol attempt-002 C-F3)。
@inline(__always)
func withCPath<R>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) -> R) -> R {
    cPathConversions += 1
    var buf = bytes
    buf.append(0)
    return buf.withUnsafeBufferPointer { p in
        p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { body($0) }
    }
}

public func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

// MARK: - 路徑契約

/// context 路徑的語法契約:不含 NUL(U+0000 / 0x00:C 字串邊界會在該處截斷,使 syscall 看到的路徑 ≠ 位元組所指的路徑;在任何
/// 正規化、排除比對或 C 轉換「之前」即為無效輸入 —— owner R6,sol attempt-002 C-F3)、非空、絕對、正規(不以 '/' 結尾、無 '//'、
/// 無 '.' / '..' 成分)。只做字串判定,零檔案系統存取、零 C 字串轉換。本程式庫每個接受路徑的公開入口(openContext、
/// checkKeychainPath、checkScanPathSyntax / scanSecrets、removeMarkerAndContext)都先經過這裡。
public func checkContextPathSyntax(_ path: [UInt8]) throws {
    if path.contains(0) { throw K1Error(.rejected, "context-nul", "路徑含 NUL 位元組(C 字串會在該處截斷;無效輸入):\(escapeBytes(path))") }
    if path.isEmpty { throw K1Error(.rejected, "context-empty", "context 參數為空") }
    if path[0] != UInt8(ascii: "/") { throw K1Error(.rejected, "context-relative", "context 須為絕對路徑:\(escapeBytes(path))") }
    if path.count > 1 && path[path.count - 1] == UInt8(ascii: "/") {
        throw K1Error(.rejected, "context-noncanonical", "context 不得以 '/' 結尾:\(escapeBytes(path))")
    }
    var comps: [[UInt8]] = []
    var cur: [UInt8] = []
    for (i, c) in path.enumerated() where i > 0 {
        if c == UInt8(ascii: "/") { comps.append(cur); cur = [] } else { cur.append(c) }
    }
    comps.append(cur)
    for comp in comps {
        if comp.isEmpty { throw K1Error(.rejected, "context-noncanonical", "context 不得含 '//' 成分或為根目錄:\(escapeBytes(path))") }
        if comp == bytes(".") || comp == bytes("..") {
            throw K1Error(.rejected, "context-noncanonical", "context 不得含 '.' / '..' 成分:\(escapeBytes(path))")
        }
    }
    if path.count > Int(PATH_MAX) - 1 { throw K1Error(.rejected, "context-noncanonical", "context 路徑過長") }
}

/// 最後一個路徑成分(已通過語法契約的路徑)。
public func lastComponent(_ path: [UInt8]) -> [UInt8] {
    guard let i = path.lastIndex(of: UInt8(ascii: "/")) else { return path }
    return Array(path[(i + 1)...])
}

// MARK: - context 開啟 / 分類

public struct ContextHandle {
    public let fd: Int32
    public let st: stat
    public func close() { _ = Darwin.close(fd) }
}

/// open 失敗的 errno 分類(N7)。ENOENT → 3;ENOTDIR:若 lstat 成功(最後一段存在但不是目錄;macOS 對 O_DIRECTORY|O_NOFOLLOW
/// 開啟「最後一段是 symlink」也回 ENOTDIR,lstat 為 symlink 時歸為 context-symlink)→ 2,lstat 失敗 ENOTDIR / ENOENT(路徑鏈中
/// 有非目錄 / 缺項,該 context 不可能存在)→ 3;ELOOP:若 lstat 成功且為 symlink(最後一段是 symlink)→ 2,否則(祖先迴圈 /
/// 無法判定)→ 1;其他(EACCES、EIO、ENAMETOOLONG、EMFILE…)→ 1。這裡的 lstat 只用來「分類失敗」,不是安全依據(每種分類
/// 結果都是零動作的失敗;即使分類被競爭者干擾,也只會在 1 / 2 / 3 之間變動,絕不會變成成功)。
func classifyContextOpenFailure(_ e: Int32, _ path: [UInt8]) -> K1Error {
    let shown = escapeBytes(path)
    switch e {
    case ENOENT:
        return K1Error(.notFound, "context-missing", "\(describeErrno(e)):\(shown)")
    case ENOTDIR:
        var st = stat()
        let r = withCPath(path) { lstat($0, &st) }
        if r == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK {
                return K1Error(.rejected, "context-symlink", "context 不得是 symlink(最後一段不跟隨;\(describeErrno(e))):\(shown)")
            }
            return K1Error(.rejected, "context-not-dir", "context 不是目錄(\(describeErrno(e))):\(shown)")
        }
        let e2 = errno
        if e2 == ENOTDIR || e2 == ENOENT {
            return K1Error(.notFound, "context-missing", "\(describeErrno(e2)):\(shown)")
        }
        return K1Error(.operational, "context-inaccessible", "無法判定 context 是否存在(\(describeErrno(e2))):\(shown)")
    case ELOOP:
        var st = stat()
        let r = withCPath(path) { lstat($0, &st) }
        if r == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
            return K1Error(.rejected, "context-symlink", "context 不得是 symlink(\(describeErrno(e))):\(shown)")
        }
        let e2 = (r == 0) ? e : errno
        return K1Error(.operational, "context-inaccessible", "無法判定 context 是否存在(\(describeErrno(e2))):\(shown)")
    default:
        return K1Error(.operational, "context-inaccessible", "無法判定 context 是否存在(\(describeErrno(e))):\(shown)")
    }
}

/// 開啟並驗證 context:語法 → open(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)→ fstat 同一個 fd:目錄、owner == uid、權限
/// (含特殊位元)恰 0700。任一不符 → 關閉 fd 並丟出對應錯誤(零動作)。`uid` 由呼叫端傳入(CLI 傳 getuid()),讓 owner 判定
/// 可被單元測試以不同 uid 決定性地驗證。
public func openContext(_ path: [UInt8], uid: uid_t) throws -> ContextHandle {
    try checkContextPathSyntax(path)
    let fd = withCPath(path) { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    if fd < 0 { throw classifyContextOpenFailure(errno, path) }
    var st = stat()
    if fstat(fd, &st) != 0 {
        let e = errno; _ = close(fd)
        throw K1Error(.operational, "context-inaccessible", "fstat 失敗(\(describeErrno(e))):\(escapeBytes(path))")
    }
    if (st.st_mode & S_IFMT) != S_IFDIR {
        _ = close(fd)
        throw K1Error(.rejected, "context-not-dir", "context 不是目錄:\(escapeBytes(path))")
    }
    if st.st_uid != uid {
        _ = close(fd)
        throw K1Error(.rejected, "context-owner", "context 不屬於目前 uid(\(st.st_uid) ≠ \(uid)):\(escapeBytes(path))")
    }
    let mode = st.st_mode & 0o7777
    if mode != 0o700 {
        _ = close(fd)
        throw K1Error(.rejected, "context-mode", "context 權限須恰為 0700(實際 \(String(mode, radix: 8).leftPad(4))):\(escapeBytes(path))")
    }
    return ContextHandle(fd: fd, st: st)
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

// MARK: - 列舉

/// 以 fdopendir(dup(fd)) 真正列舉目錄:含隱藏項與非隱藏項、只排除 "." 與 ".."、檔名保留原始位元組;opendir / readdir / closedir
/// 任一失敗 → 丟出 context-enumerate(作業失敗,fail-closed)。不受任何 shell glob 狀態影響。
public func enumerateEntries(_ dirfd: Int32) throws -> [[UInt8]] {
    let dupfd = dup(dirfd)
    if dupfd < 0 { throw K1Error(.operational, "context-enumerate", "dup 失敗(\(describeErrno(errno)))") }
    if lseek(dupfd, 0, SEEK_SET) < 0 {
        let e = errno; _ = close(dupfd)
        throw K1Error(.operational, "context-enumerate", "lseek 失敗(\(describeErrno(e)))")
    }
    guard let dir = fdopendir(dupfd) else {
        let e = errno; _ = close(dupfd)
        throw K1Error(.operational, "context-enumerate", "fdopendir 失敗(\(describeErrno(e)))")
    }
    var names: [[UInt8]] = []
    while true {
        errno = 0
        guard let ent = readdir(dir) else {
            let e = errno
            if e != 0 {
                _ = closedir(dir)
                throw K1Error(.operational, "context-enumerate", "readdir 失敗(\(describeErrno(e)))")
            }
            break
        }
        let len = Int(ent.pointee.d_namlen)
        let base = UnsafeRawPointer(ent).advanced(by: MemoryLayout<dirent>.offset(of: \dirent.d_name)!)
        let name = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: len))
        if name == bytes(".") || name == bytes("..") { continue }
        names.append(name)
    }
    if closedir(dir) != 0 {
        throw K1Error(.operational, "context-enumerate", "closedir 失敗(\(describeErrno(errno)))")
    }
    return names
}

// MARK: - marker

public let markerName = bytes(".aipet-kc-context")
public let keychainName = bytes("signing.keychain-db")
public let p12Name = bytes("p12.tmp")
/// cleanup 白名單:context 內只允許這三個名稱(皆須為一般檔、非 symlink)。
public let allowedEntries: [[UInt8]] = [markerName, keychainName, p12Name]

/// 精確的 v1 marker 位元組:"aipet-kc-context v1\nuid=<uid>\n"。
public func markerBytes(uid: uid_t) -> [UInt8] { bytes("aipet-kc-context v1\nuid=\(uid)\n") }

/// 把整個緩衝寫進 fd(EINTR 重試;短寫續寫);失敗回傳 errno。
func writeAll(_ fd: Int32, _ data: [UInt8]) -> Int32? {
    var off = 0
    while off < data.count {
        let n = data.withUnsafeBufferPointer { p in write(fd, p.baseAddress! + off, data.count - off) }
        if n < 0 {
            if errno == EINTR { continue }
            return errno
        }
        if n == 0 { return EIO }
        off += n
    }
    return nil
}

/// 讀取最多 count 個位元組(EINTR 重試;EOF 提前結束)。
func readUpTo(_ fd: Int32, _ count: Int) -> ([UInt8], Int32?) {
    var out = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
        let n = out.withUnsafeMutableBufferPointer { p in read(fd, p.baseAddress! + got, count - got) }
        if n < 0 {
            if errno == EINTR { continue }
            return (Array(out[0..<got]), errno)
        }
        if n == 0 { break }
        got += n
    }
    return (Array(out[0..<got]), nil)
}

/// 新建檔的權限不依賴繼承的 umask(openat 的 mode 參數會被 umask 遮罩):對「同一個已開啟的 fd」fchmod 到 0600,再以 fstat
/// 同一 fd 複驗(一般檔、權限恰 0600 —— 與 readMarker 的要求一致)。失敗回傳描述,成功回傳 nil。
func ensureMode0600(_ fd: Int32) -> String? {
    if fchmod(fd, 0o600) != 0 { return "fchmod: \(describeErrno(errno))" }
    var st = stat()
    if fstat(fd, &st) != 0 { return "fstat: \(describeErrno(errno))" }
    if (st.st_mode & S_IFMT) != S_IFREG { return "不是一般檔" }
    if (st.st_mode & 0o7777) != 0o600 { return "權限 \(String(st.st_mode & 0o7777, radix: 8).leftPad(4)) ≠ 0600" }
    return nil
}

/// 安全建立 marker(N5 Create):openat(dirfd, ".aipet-kc-context", O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600)——
/// 路徑被任何物件佔用(一般檔、任何 symlink 含 dangling、FIFO、目錄)即 EEXIST 立刻失敗、絕不開啟、絕不跟隨、絕不阻塞;
/// fchmod + fstat 複驗 0600(不依賴 umask);寫入精確位元組(checked write)、fsync、checked close。失敗 token:marker-create
/// (作業失敗;若因 EEXIST 則 detail 註明);任何失敗都會把已建立的檔 unlink。
public func createMarker(_ dirfd: Int32, uid: uid_t, token: String = "marker-create") throws {
    let fd = withCPath(markerName) { openat(dirfd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
    if fd < 0 {
        let e = errno
        throw K1Error(.operational, token, "無法建立 marker(\(describeErrno(e));路徑被佔用或不可寫)")
    }
    if let why = ensureMode0600(fd) {
        _ = close(fd); _ = withCPath(markerName) { unlinkat(dirfd, $0, 0) }
        throw K1Error(.operational, token, "marker 權限設定 / 複驗失敗(\(why))")
    }
    if let e = writeAll(fd, markerBytes(uid: uid)) {
        _ = close(fd); _ = withCPath(markerName) { unlinkat(dirfd, $0, 0) }
        throw K1Error(.operational, token, "marker 寫入失敗(\(describeErrno(e)))")
    }
    if fsync(fd) != 0 {
        let e = errno; _ = close(fd); _ = withCPath(markerName) { unlinkat(dirfd, $0, 0) }
        throw K1Error(.operational, token, "marker fsync 失敗(\(describeErrno(e)))")
    }
    if close(fd) != 0 {
        let e = errno; _ = withCPath(markerName) { unlinkat(dirfd, $0, 0) }
        throw K1Error(.operational, token, "marker close 失敗(\(describeErrno(e)))")
    }
}

/// 安全讀取 marker(N5 Read):只 open 一次 —— openat(dirfd, ".aipet-kc-context", O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC):
/// symlink → ELOOP(拒絕,從不解析目標)、FIFO → O_NONBLOCK 立刻返回(不阻塞)。open 之後對「同一個已開啟物件」fstat:
/// 必須是一般檔、owner == uid、權限恰 0600、大小 == 精確 marker 長度;再從該 fd 讀取(多讀一個位元組以確認 EOF)並逐位元組
/// 比對。沒有任何「先 lstat 路徑再另開」的步驟,所以在較早的 metadata 觀察與這次 open 之間換掉 marker,也只會換成
/// 「這次 open 到的物件被 fstat 拒絕」,不可能變成 symlink 解析、FIFO 阻塞或讀到不相關的檔案。
public func readMarker(_ dirfd: Int32, uid: uid_t) throws {
    let fd = withCPath(markerName) { openat(dirfd, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
    if fd < 0 {
        let e = errno
        switch e {
        case ENOENT: throw K1Error(.rejected, "marker-missing", "不是 K1 context(缺 ownership marker;\(describeErrno(e)))")
        case ELOOP: throw K1Error(.rejected, "marker-type", "ownership marker 是 symlink(不跟隨;\(describeErrno(e)))")
        case EOPNOTSUPP, ENXIO, ENODEV: throw K1Error(.rejected, "marker-type", "ownership marker 不是一般檔(\(describeErrno(e)))")
        default: throw K1Error(.operational, "marker-read", "無法開啟 ownership marker(\(describeErrno(e)))")
        }
    }
    defer { _ = close(fd) }
    var st = stat()
    if fstat(fd, &st) != 0 { throw K1Error(.operational, "marker-read", "fstat marker 失敗(\(describeErrno(errno)))") }
    let type = st.st_mode & S_IFMT
    if type != S_IFREG {
        let kind: String
        switch type {
        case S_IFIFO: kind = "FIFO"
        case S_IFDIR: kind = "directory"
        case S_IFSOCK: kind = "socket"
        case S_IFCHR, S_IFBLK: kind = "device"
        case S_IFLNK: kind = "symlink"
        default: kind = "non-regular"
        }
        throw K1Error(.rejected, "marker-type", "ownership marker 不是一般檔(開啟到的物件為 \(kind))")
    }
    if st.st_uid != uid { throw K1Error(.rejected, "marker-invalid", "ownership marker 不屬於目前 uid(\(st.st_uid) ≠ \(uid))") }
    if (st.st_mode & 0o7777) != 0o600 {
        throw K1Error(.rejected, "marker-invalid", "ownership marker 權限須恰為 0600(實際 \(String(st.st_mode & 0o7777, radix: 8).leftPad(4)))")
    }
    let expected = markerBytes(uid: uid)
    if st.st_size != off_t(expected.count) {
        throw K1Error(.rejected, "marker-invalid", "ownership marker 大小不符 K1 v1(\(st.st_size) ≠ \(expected.count))")
    }
    let (data, rerr) = readUpTo(fd, expected.count + 1)
    if let e = rerr { throw K1Error(.operational, "marker-read", "讀取 marker 失敗(\(describeErrno(e)))") }
    if data != expected { throw K1Error(.rejected, "marker-invalid", "ownership marker 內容不符 K1 v1 / 目前 uid") }
}

// MARK: - 白名單

public struct EntryReport {
    /// 白名單內「存在且為一般檔」的非 marker 名稱(keychain / p12)。
    public var present: [[UInt8]] = []
}

/// 對已列舉的項目做白名單判定(N6):名稱 ∉ 白名單 → unexpected-entry(2);fstatat(dirfd, name, AT_SYMLINK_NOFOLLOW)
/// 失敗 → entry-stat(1);不是一般檔(symlink / FIFO / 目錄 / socket / 裝置)→ entry-type(2)。marker 本身須存在(由
/// readMarker 另行逐位元組驗證);這裡只回報其餘存在的白名單項目。
public func classifyEntries(_ dirfd: Int32, _ names: [[UInt8]]) throws -> EntryReport {
    var rep = EntryReport()
    for name in names {
        guard allowedEntries.contains(name) else {
            throw K1Error(.rejected, "unexpected-entry", "context 含白名單以外的項目:\(escapeBytes(name))")
        }
        var st = stat()
        let r = withCPath(name) { fstatat(dirfd, $0, &st, AT_SYMLINK_NOFOLLOW) }
        if r != 0 { throw K1Error(.operational, "entry-stat", "無法 stat 項目 \(escapeBytes(name))(\(describeErrno(errno)))") }
        if (st.st_mode & S_IFMT) != S_IFREG {
            throw K1Error(.rejected, "entry-type", "白名單項目不是一般檔(或是 symlink):\(escapeBytes(name))")
        }
        if name != markerName { rep.present.append(name) }
    }
    return rep
}

// MARK: - base64(嚴格;只用於 P12 輸入通道)

/// 嚴格 RFC 4648 解碼:只接受標準字母表與結尾 '=' 填充(長度須為 4 的倍數),忽略 ASCII 空白(空格 / tab / CR / LF);其他任何
/// 字元、錯誤填充 → nil。
public func decodeBase64Strict(_ input: [UInt8]) -> [UInt8]? {
    var vals: [UInt8] = []
    vals.reserveCapacity(input.count)
    var pad = 0
    for c in input {
        switch c {
        case 0x20, 0x09, 0x0d, 0x0a: continue
        case UInt8(ascii: "="): pad += 1; vals.append(0xff)
        default:
            if pad > 0 { return nil }   // '=' 之後不得再有資料字元
            let v: UInt8
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): v = c - UInt8(ascii: "A")
            case UInt8(ascii: "a")...UInt8(ascii: "z"): v = c - UInt8(ascii: "a") + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): v = c - UInt8(ascii: "0") + 52
            case UInt8(ascii: "+"): v = 62
            case UInt8(ascii: "/"): v = 63
            default: return nil
            }
            vals.append(v)
        }
    }
    if vals.isEmpty { return [] }
    if vals.count % 4 != 0 || pad > 2 { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(vals.count / 4 * 3)
    var i = 0
    while i < vals.count {
        let a = vals[i], b = vals[i + 1], c = vals[i + 2], d = vals[i + 3]
        if a == 0xff || b == 0xff { return nil }              // 前兩個不可為填充
        if c == 0xff && d != 0xff { return nil }              // "x=y=" 不合法
        out.append((a << 2) | (b >> 4))
        if c != 0xff { out.append(((b & 0x0f) << 4) | (c >> 2)) }
        if d != 0xff { out.append(((c & 0x03) << 6) | d) }
        i += 4
    }
    return out
}

/// 讀完 stdin(上限 maxBytes;超過 → nil)。
public func readAllStdin(maxBytes: Int) -> ([UInt8], Int32?) {
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = chunk.withUnsafeMutableBufferPointer { p in read(0, p.baseAddress!, p.count) }
        if n < 0 {
            if errno == EINTR { continue }
            return (out, errno)
        }
        if n == 0 { break }
        out.append(contentsOf: chunk[0..<n])
        if out.count > maxBytes { return (out, EFBIG) }
    }
    return (out, nil)
}

// MARK: - P12 建立 / 移除

/// 安全建立解碼 P12(N8):openat(dirfd, "p12.tmp", O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600)—— 路徑已被任何物件
/// 佔用即失敗(p12-path);有界 checked write、checked close;任何寫入失敗都嘗試 unlink 已建立的檔。內容絕不印出。
public func materializeP12(_ dirfd: Int32, _ data: [UInt8]) throws {
    if data.isEmpty { throw K1Error(.rejected, "p12-decode", "解碼後的 P12 為空") }
    let fd = withCPath(p12Name) { openat(dirfd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
    if fd < 0 {
        let e = errno
        if e == EEXIST { throw K1Error(.operational, "p12-path", "解碼 P12 的路徑已被佔用(context 遭竄改?\(describeErrno(e)))") }
        throw K1Error(.operational, "p12-write", "無法建立解碼 P12(\(describeErrno(e)))")
    }
    if let why = ensureMode0600(fd) {
        _ = close(fd); _ = withCPath(p12Name) { unlinkat(dirfd, $0, 0) }
        throw K1Error(.operational, "p12-write", "解碼 P12 權限設定 / 複驗失敗(\(why))")
    }
    if let e = writeAll(fd, data) {
        _ = close(fd); _ = withCPath(p12Name) { unlinkat(dirfd, $0, 0) }
        throw K1Error(.operational, "p12-write", "寫入解碼 P12 失敗(\(describeErrno(e)))")
    }
    if close(fd) != 0 {
        let e = errno; _ = withCPath(p12Name) { unlinkat(dirfd, $0, 0) }
        throw K1Error(.operational, "p12-write", "close 解碼 P12 失敗(\(describeErrno(e)))")
    }
}

/// 移除解碼 P12(N8):unlinkat(dirfd, "p12.tmp", 0)(對 symlink 只刪連結本身);ENOENT 視為已不存在;之後以
/// fstatat(AT_SYMLINK_NOFOLLOW) 確認確實不存在(仍在 → p12-unlink,作業失敗 = 呼叫端必須視為 fatal)。
public func removeP12(_ dirfd: Int32) throws {
    let r = withCPath(p12Name) { unlinkat(dirfd, $0, 0) }
    if r != 0 && errno != ENOENT {
        throw K1Error(.operational, "p12-unlink", "無法刪除解碼 P12(\(describeErrno(errno));秘密材料仍在磁碟上)")
    }
    var st = stat()
    let r2 = withCPath(p12Name) { fstatat(dirfd, $0, &st, AT_SYMLINK_NOFOLLOW) }
    let e2 = errno   // 緊接在 syscall 之後擷取(只在 r2 != 0 時有意義)
    if r2 == 0 { throw K1Error(.operational, "p12-unlink", "unlink 後解碼 P12 仍存在") }
    if e2 != ENOENT { throw K1Error(.operational, "p12-unlink", "無法確認解碼 P12 已消失(\(describeErrno(e2)))") }
}

// MARK: - 最後移除(marker 最後、rmdir)

/// 刪除 marker 並移除 context 目錄:unlinkat(dirfd, marker) → openat(dirfd, "..") 取得「這個實體目錄的」父目錄 fd →
/// fstatat(parentfd, <最後成分>, AT_SYMLINK_NOFOLLOW) 必須與 context 的 dev:inode 相同(目錄被改名 / 換掉即拒絕)→
/// unlinkat(parentfd, <最後成分>, AT_REMOVEDIR)(只能移除空目錄;永不遞迴)。rmdir 失敗(上層不可寫、仍有內容、身分不符)
/// → 以同一個 O_EXCL 原語把 marker 原樣寫回(路徑被佔用就明說、不阻塞)→ 丟出 rmdir(作業失敗,context 保留可重試)。
/// `path` 在任何動作(含 unlink marker)之前先過語法契約(含 NUL 拒絕):CLI 總是傳入已驗證的路徑,但程式庫被直接呼叫時也必須安全。
public func removeMarkerAndContext(_ handle: ContextHandle, path: [UInt8], uid: uid_t) throws {
    try checkContextPathSyntax(path)
    let r = withCPath(markerName) { unlinkat(handle.fd, $0, 0) }
    if r != 0 { throw K1Error(.operational, "marker", "無法刪除 ownership marker(\(describeErrno(errno)))") }
    func restore() -> String {
        do { try createMarker(handle.fd, uid: uid, token: "marker-restore"); return "marker 已寫回,修復後可重試" }
        catch let e as K1Error { return "且無法寫回 marker(\(e.detail))" }
        catch { return "且無法寫回 marker" }
    }
    let name = lastComponent(path)
    let parent = withCPath(bytes("..")) { openat(handle.fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    if parent < 0 {
        let e = errno
        throw K1Error(.operational, "rmdir", "無法開啟 context 的父目錄(\(describeErrno(e)));\(restore())")
    }
    defer { _ = close(parent) }
    var st = stat()
    let r2 = withCPath(name) { fstatat(parent, $0, &st, AT_SYMLINK_NOFOLLOW) }
    if r2 != 0 {
        let e = errno
        throw K1Error(.operational, "rmdir", "父目錄中找不到 context 項目 \(escapeBytes(name))(\(describeErrno(e)));\(restore())")
    }
    if st.st_dev != handle.st.st_dev || st.st_ino != handle.st.st_ino || (st.st_mode & S_IFMT) != S_IFDIR {
        throw K1Error(.operational, "rmdir", "父目錄中的 \(escapeBytes(name)) 不是這個 context(dev:inode 不符);\(restore())")
    }
    let r3 = withCPath(name) { unlinkat(parent, $0, AT_REMOVEDIR) }
    if r3 != 0 {
        let e = errno
        throw K1Error(.operational, "rmdir", "無法移除 context(\(describeErrno(e));上層目錄不可寫或仍有內容?);\(restore())")
    }
}

// MARK: - 秘密衛生掃描(N9)

public struct ScanSummary {
    public var files = 0, dirs = 0, symlinks = 0, special = 0, excluded = 0, errors = 0, matches = 0
    public var status: String {
        if matches > 0 { return "SECRET_FOUND" }
        if errors > 0 { return "INCOMPLETE_SCAN" }
        return "CLEAN"
    }
    public var exitStatus: K1Status {
        if matches > 0 { return .rejected }
        if errors > 0 { return .operational }
        return .ok
    }
    public var line: String {
        "summary files=\(files) dirs=\(dirs) symlinks=\(symlinks) special=\(special) excluded=\(excluded) errors=\(errors) matches=\(matches) status=\(status)"
    }
}

public let scanMaxDepth = 128

func containsSentinel(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty || hay.count < needle.count { return false }
    let first = needle[0]
    var i = 0
    let last = hay.count - needle.count
    while i <= last {
        if hay[i] == first {
            var j = 1
            while j < needle.count && hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
        }
        i += 1
    }
    return false
}

/// 單一一般檔的掃描:openat(O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)→ fstat 必須仍是一般檔(換成 FIFO 也不會阻塞,只會被
/// 計為 special)→ 分塊讀取並以重疊區處理跨塊的 sentinel。
func scanRegularFile(_ dirfd: Int32, _ name: [UInt8], _ shown: String, _ sentinels: [[UInt8]], _ sum: inout ScanSummary, _ report: (String) -> Void) {
    let fd = withCPath(name) { openat(dirfd, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
    if fd < 0 { sum.errors += 1; report("ERROR \(errnoName(errno)) open \(shown)"); return }
    defer { _ = close(fd) }
    var st = stat()
    if fstat(fd, &st) != 0 { sum.errors += 1; report("ERROR \(errnoName(errno)) fstat \(shown)"); return }
    if (st.st_mode & S_IFMT) != S_IFREG { sum.special += 1; report("SPECIAL \(shown)"); return }
    sum.files += 1
    let maxLen = sentinels.map { $0.count }.max() ?? 0
    var carry: [UInt8] = []
    var matched = false
    while true {
        let (chunk, rerr) = readUpTo(fd, 65536)
        if let e = rerr { sum.errors += 1; report("ERROR \(errnoName(e)) read \(shown)"); return }
        if chunk.isEmpty { break }
        let window = carry + chunk
        for s in sentinels where containsSentinel(window, s) { matched = true }
        if matched { break }
        if maxLen > 1 { carry = Array(window.suffix(maxLen - 1)) }
    }
    if matched { sum.matches += 1; report("MATCH \(shown)") }
}

/// 遞迴(迭代深度上限)掃描一個已開啟的目錄 fd。所有路徑都以位元組拼接(root + "/" + name),只用於排除判定與報告。
func scanDir(_ dirfd: Int32, _ path: [UInt8], depth: Int, excludes: [[UInt8]], sentinels: [[UInt8]], _ sum: inout ScanSummary, _ report: (String) -> Void) {
    if depth > scanMaxDepth { sum.errors += 1; report("ERROR DEPTH \(escapeBytes(path))"); return }
    let names: [[UInt8]]
    do { names = try enumerateEntries(dirfd) } catch let e as K1Error {
        sum.errors += 1; report("ERROR ENUM \(escapeBytes(path)) \(e.detail)"); return
    } catch { sum.errors += 1; report("ERROR ENUM \(escapeBytes(path))"); return }
    for name in names {
        let child = path + [UInt8(ascii: "/")] + name
        let shown = escapeBytes(child)
        if excludes.contains(where: { $0 == child || child.starts(with: $0 + [UInt8(ascii: "/")]) }) {
            sum.excluded += 1; continue
        }
        var st = stat()
        let r = withCPath(name) { fstatat(dirfd, $0, &st, AT_SYMLINK_NOFOLLOW) }
        if r != 0 { sum.errors += 1; report("ERROR \(errnoName(errno)) stat \(shown)"); continue }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            // O_NONBLOCK 對目錄沒有作用;加上它只為了讓「fstatat 與 openat 之間被換成 FIFO」的競爭也可證明不會阻塞(O_DIRECTORY 已使其失敗)。
            let cfd = withCPath(name) { openat(dirfd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            if cfd < 0 { sum.errors += 1; report("ERROR \(errnoName(errno)) opendir \(shown)"); continue }
            sum.dirs += 1
            scanDir(cfd, child, depth: depth + 1, excludes: excludes, sentinels: sentinels, &sum, report)
            _ = close(cfd)
        case S_IFREG:
            scanRegularFile(dirfd, name, shown, sentinels, &sum, report)
        case S_IFLNK:
            sum.symlinks += 1   // 凍結政策:symlink 一律不跟隨、不讀取其目標;只計數。
        default:
            sum.special += 1    // FIFO / socket / 裝置:不開啟(不會阻塞);只計數。
        }
    }
}

/// 掃描根目錄 / 排除路徑的語法契約(與 context 相同:不含 NUL、絕對、正規 —— 無結尾 '/'、無 '//'、無 '.' / '..' 成分、非根目錄)。
/// 排除比對是逐位元組的路徑前綴比對,所以根與排除都必須是同一種正規拼法;否則 "/a/x/../b" 這種根會被 "/a/x" 的排除整棵吞掉而
/// 回報 CLEAN(sol attempt-001 D1);"/a/x/..\0junk" 這種含 NUL 的根在 C 字串邊界會變成 "/a/x/.." = "/a",同樣會被 "/a/x"
/// 的排除吞掉(sol attempt-002 C-F3)—— 兩者都在這裡、在任何排除比對之前被拒。違反者 → scan-args(2)。
public func checkScanPathSyntax(_ path: [UInt8], what: String) throws {
    do { try checkContextPathSyntax(path) } catch let e as K1Error {
        throw K1Error(.rejected, "scan-args", "\(what) 須為絕對正規路徑(\(e.token)):\(escapeBytes(path))")
    }
}

/// 掃描多個根目錄(絕對正規路徑;排除清單為絕對正規路徑前綴,對根目錄與其下每個項目一致地套用)。任何非正規的根 / 排除路徑都
/// 計為 error(INCOMPLETE_SCAN;CLI 另在解析參數時就以 scan-args 拒絕);根目錄本身無法開啟 → error。兩者都絕不當成 CLEAN。
public func scanSecrets(roots: [[UInt8]], excludes: [[UInt8]], sentinels: [[UInt8]], report: (String) -> Void) -> ScanSummary {
    var sum = ScanSummary()
    var badSyntax = false
    for ex in excludes {
        if (try? checkScanPathSyntax(ex, what: "exclude")) == nil { sum.errors += 1; badSyntax = true; report("ERROR SYNTAX exclude \(escapeBytes(ex))") }
    }
    for root in roots {
        if (try? checkScanPathSyntax(root, what: "root")) == nil { sum.errors += 1; report("ERROR SYNTAX root \(escapeBytes(root))"); continue }
        if badSyntax { continue }   // 排除清單本身不正規 → 不能信任任何排除判定;整個掃描已是 INCOMPLETE_SCAN
        if excludes.contains(where: { $0 == root || root.starts(with: $0 + [UInt8(ascii: "/")]) }) { sum.excluded += 1; continue }
        let fd = withCPath(root) { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 { sum.errors += 1; report("ERROR \(errnoName(errno)) openroot \(escapeBytes(root))"); continue }
        sum.dirs += 1
        scanDir(fd, root, depth: 1, excludes: excludes, sentinels: sentinels, &sum, report)
        _ = close(fd)
    }
    return sum
}

// MARK: - K5 顯式 keychain 路徑(原生物件形狀判定;shell 不再對 keychain 路徑做 metadata 檢視)

/// K5 顯式 keychain 輸入的物件形狀契約:絕對正規路徑、以 open(O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC) 開啟(最後一段 symlink
/// → ELOOP 拒絕;FIFO 不阻塞)、fstat 同一 fd 必須是一般檔。不讀取內容、不改變任何東西。2 = 拒絕(相對 / 非正規 / 不存在 /
/// symlink / 非一般檔);1 = 無法判定(EACCES / I/O)。
public func checkKeychainPath(_ path: [UInt8]) throws {
    do { try checkContextPathSyntax(path) } catch let e as K1Error {
        throw K1Error(.rejected, "keychain-path", "簽名 keychain 須為顯式的絕對正規路徑(\(e.token)):\(escapeBytes(path))")
    }
    let fd = withCPath(path) { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
    if fd < 0 {
        let e = errno
        switch e {
        case ENOENT, ENOTDIR: throw K1Error(.rejected, "keychain-path", "簽名 keychain 不存在(\(describeErrno(e))):\(escapeBytes(path))")
        case ELOOP: throw K1Error(.rejected, "keychain-path", "簽名 keychain 不得是 symlink(不跟隨;\(describeErrno(e))):\(escapeBytes(path))")
        case EOPNOTSUPP, ENXIO, ENODEV: throw K1Error(.rejected, "keychain-path", "簽名 keychain 不是一般檔(\(describeErrno(e))):\(escapeBytes(path))")
        default: throw K1Error(.operational, "keychain-path", "無法開啟簽名 keychain(\(describeErrno(e))):\(escapeBytes(path))")
        }
    }
    defer { _ = close(fd) }
    var st = stat()
    if fstat(fd, &st) != 0 { throw K1Error(.operational, "keychain-path", "fstat 簽名 keychain 失敗(\(describeErrno(errno))):\(escapeBytes(path))") }
    if (st.st_mode & S_IFMT) != S_IFREG { throw K1Error(.rejected, "keychain-path", "簽名 keychain 須為一般檔(非目錄 / FIFO / 裝置):\(escapeBytes(path))") }
}
