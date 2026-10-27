# K1-NATIVE — `k1ctx`:K1 私有 context 的原生檔案系統 / 安全工具

`Scripts/k1-native/` 是 **release 工具**(Developer ID 簽名的臨時 keychain 生命週期),不是 App runtime 的一部分。它實作
owner 凍結的 K1 安全語意中「檔案系統 / context」那一半;Apple keychain 語意(顯式 keychain、SHA-1 derived join、SHA-256
binding、post-sign leaf check…)維持在 `Scripts/keychain-bootstrap.sh`(thin shell adapter)+ `Scripts/build-app.sh`,
不在此重新設計。

## 責任模型(N1,凍結)

| 層 | 擁有 | 不得 |
|---|---|---|
| **原生 Swift CLI `k1ctx`** | 所有安全敏感的檔案系統 / context 行為:marker 建立 / 讀取 / 寫回、context 列舉與白名單判定、解碼 P12 的建立 / 移除、context 的最後移除、秘密衛生掃描 | 讀環境變數作為安全依據;印任何檔案內容 |
| **Shell 編排 `keychain-bootstrap.sh`** | 呼叫 `k1ctx`、Apple 的 `/usr/bin/security` 與 `/usr/bin/codesign`,解讀明確的退出碼;`security` 輸出(find-identity / find-certificate)的解析 | 以 `<` 讀 marker、以 `>` 建 marker、以 glob 列舉 context、以 grep / find 遞迴掃描、以 shell 重導向落地 P12、自行刪除 context 內的任何檔案、`stat` / `[ -e ]` 檢視 context 內部 |

## 建置模型(N3)與理由

**選擇:獨立 Swift 原始碼 + `swiftc` 直接編譯**(`Scripts/k1-native/build.sh <絕對輸出路徑>`),**不是** `Package.swift` 的 target。

| 比較軸 | Package target(`Sources/`) | `swiftc` 獨立工具(採用) |
|---|---|---|
| repo 慣例 | `Sources/` = App runtime(UsageCore / PetCore / aipet);release 工具一律在 `Scripts/` | release 工具留在 `Scripts/`,不擴張 App 架構、不動 `Package.swift` |
| CI 成本 | 隨 `swift build` 一起編(已在 job 內),但 harness 仍需定位 `.build/<config>/` 產物 | harness / 未來 PR-C2 以 `build.sh` 編一次(本機 ~2 s,CI macos runner 相近),輸出路徑由呼叫端決定 |
| 不可變來源 | ✓ | ✓(同一份 checkout 的 `*.swift`;tag 即凍結) |
| 編譯失敗 fail-closed | ✓(`swift build` 紅) | ✓(`build.sh` 非零、不留半成品;harness 第一步即 FATAL) |
| 相依 | SwiftPM 解析(本 repo 無外部相依) | 零:只 `import Darwin`(libSystem);不下載任何東西;不新增任何 GitHub Action |
| 本機工具鏈 | 需 `Scripts/swiftpm.sh` 的 CLT workaround | 直接 `swiftc`;可用 `SWIFTC=` 指向其他工具鏈 |

`build.sh --tests <絕對輸出路徑>` 以同一份 `K1Native.swift` + `Tests/main.swift` 編出單元 / 整合測試 runner(與 repo 的
`usagecore-tests` 同一手法:獨立執行檔、手動註冊、退出碼),由 `Scripts/test-signing-pipeline.sh` 建置並執行。

## 命令面(N2)與退出碼(N7,凍結)

```
k1ctx context-init <ctx>        驗證(絕對正規路徑、目錄、非 symlink、owner uid、0700、完全為空)後建立 marker
k1ctx context-validate <ctx>    驗證 + 逐位元組驗 marker + 白名單;stdout 每行 entry=<name>(存在的白名單項目)
k1ctx write-p12 <ctx>           stdin 的 base64 → 解碼 → O_CREAT|O_EXCL|O_NOFOLLOW、fchmod 0600 寫成 <ctx>/p12.tmp
k1ctx remove-p12 <ctx>          unlinkat p12.tmp(不跟隨 symlink)並確認消失;失敗 = 1(呼叫端視為 fatal)
k1ctx context-finalize <ctx>    要求只剩 marker;unlink marker;以父目錄 fd + dev:inode 身分 rmdir;失敗即寫回 marker
k1ctx check-keychain-path <p>   K5 顯式 keychain 輸入的物件形狀:絕對正規路徑、既存一般檔、非 symlink(開啟後 fstat 同一 fd)
k1ctx scan-secrets [--exclude <abs>]... <abs-root>...    stdin 每行一個 sentinel;根與排除都須為絕對「正規」路徑
```

| 退出碼 | 意義 |
|---|---|
| 0 | 成功 / 掃描 CLEAN |
| 1 | 作業失敗:EACCES / ELOOP / I/O / 無法判定 / 列舉不完整 / 刪除失敗 / 掃描 INCOMPLETE_SCAN(零動作或已明說的部分動作) |
| 2 | 拒絕:空 / 相對路徑、既存但違反信任契約(非目錄、最後一段 symlink、owner、權限、marker、白名單)、參數錯誤 / 掃描 SECRET_FOUND |
| 3 | CONTEXT_NOT_FOUND:只在 ENOENT,或路徑鏈中的 ENOTDIR 證明該 context 不可能存在 |

失敗時 stdout 印一行 `token=<token>`(機器可讀),stderr 印 `k1ctx: <cmd>: <STATUS>: <token>: <detail>`。token 詞彙:
`context-nul / context-empty / context-relative / context-noncanonical / context-missing / context-inaccessible / context-not-dir /
context-symlink / context-owner / context-mode / context-not-empty / context-enumerate / marker-missing / marker-type /
marker-invalid / marker-read / marker-create / marker-restore / marker / unexpected-entry / entry-type / entry-stat /
p12-decode / p12-path / p12-write / p12-unlink / residual-entry / rmdir / scan-args / usage`。

## 描述符相對的 context 權威(N4)

**路徑的 NUL 邊界(C-F3)**:程式庫每個接受路徑的公開入口(`openContext`、`checkKeychainPath`、`scanSecrets` 的根 / 排除、
`removeMarkerAndContext`)都先經 `checkContextPathSyntax`,而它的第一個判定就是「含 0x00 位元組 ⇒ 無效輸入(`context-nul`,
2)」—— 在任何正規化、排除比對或「位元組 → C 字串」轉換之前。理由:C 字串在 NUL 處截斷,syscall 看到的路徑會 ≠ 位元組所指的
路徑(例如根 `/a/x/..\0junk` 在排除比對時 ≠ `/a/x/..`,到了 open(2) 卻是 `/a`)。CLI 的 argv 本來就不能帶 NUL;這條規則讓
程式庫被直接呼叫時也安全,單元測試以轉換探針證明被拒的 NUL 輸入從未到達任何 C 轉換。

每個命令:`open(ctx, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` → `fstat` 同一個 fd(目錄、owner、0700)→ 之後一切相對於
該 fd:`fdopendir(dup(fd))` 列舉、`openat(fd, name, …|O_NOFOLLOW)`、`fstatat(fd, name, AT_SYMLINK_NOFOLLOW)`、`unlinkat`、
`unlinkat(parentfd, name, AT_REMOVEDIR)`。**沒有** `stat(path) → open(path)` 的安全依據;open 失敗的 errno 分類中用到的
`lstat` 只決定失敗落在 1 / 2 / 3 哪一類,三者都是零動作。

- **Marker 建立 / 寫回(N5)**:`openat(…, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600)` → `fchmod(fd, 0600)` + `fstat` 同一 fd
  複驗(權限不依賴繼承的 umask)、精確位元組、checked write、`fsync`、checked close。路徑被任何物件(一般檔、任何 symlink、FIFO、
  目錄)佔用即 EEXIST 立刻失敗:不開啟、不跟隨、不阻塞。
- **Marker 讀取(N5)**:只 open 一次 `openat(…, O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)`;之後 `fstat` **同一個已開啟物件**:
  一般檔、owner uid、權限恰 0600、大小 == 精確 marker 長度;從該 fd 讀取(多讀一個位元組確認 EOF)逐位元組比對。symlink →
  ELOOP 拒絕(從不解析目標);FIFO → O_NONBLOCK 立刻返回並被 fstat 拒絕。**F-N1 的根因(shell `<` 讀 marker)在此結構上
  不存在**:在較早的 metadata 觀察與這次 open 之間換掉 marker,結果只會是「這次 open 到的物件被拒絕」。
- **列舉(N6)**:真正的 `readdir`(含隱藏項、只排除 `.` / `..`、檔名保留原始位元組),`opendir / readdir / closedir` 任一失敗
  → `context-enumerate`(fail-closed);與任何 shell glob 狀態無關。
- **P12(N8)**:`openat(…, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600)` + `fchmod` / `fstat` 複驗、有界 checked write、
  checked close;`remove-p12` 以 `unlinkat` + `fstatat(AT_SYMLINK_NOFOLLOW)` 確認消失,失敗 = 1(shell 視為 fatal)。
- **顯式 keychain 路徑(K5)**:`check-keychain-path` 以 `open(O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)` + `fstat` 同一 fd 判定
  「絕對正規路徑、既存、一般檔、非 symlink」(不讀內容);shell adapter 與 `build-app.sh` 的 developer-id 模式都經它判定,shell
  不再對 keychain 路徑做任何 metadata 檢視。
- **最後移除**:marker 最後刪;`openat(fd, "..")` 取得**這個實體目錄的**父目錄 fd,`fstatat(parentfd, <最後成分>)` 的
  dev:inode 必須等於 context 的 dev:inode,才 `unlinkat(parentfd, name, AT_REMOVEDIR)`(只能移除空目錄,永不遞迴)。rmdir
  失敗 → 以同一個 O_EXCL 原語寫回 marker(路徑被佔用就明說、不阻塞)→ 1,context 保留可重試。

## P12 輸入通道(N8)

解碼前的 P12 以 **base64 文字經 stdin(pipe)** 進入 `k1ctx write-p12`;shell adapter 在自己的 subshell(秘密作用域)內先以
builtin 關掉 allexport、去掉別名名稱可能繼承的 export 屬性,再把 `DEVELOPER_ID_P12_BASE64`(與兩個密碼)複製到未 export 的
local、**立即 `unset`** 正式名稱並複驗(無法 unset / 無法去除 export → 拒絕),之後才以 builtin `printf '%s' "$p12b64" |`
餵入 —— 值不進任何子行程的 argv 或環境(呼叫端 `set -a` 也一樣)、不經暫存檔;公開的 `kc_normalize_sha256` 同樣先 scrub,且
以 builtin 正規化、不產生任何子行程。`k1ctx` 在行程內嚴格解碼(RFC 4648 字母表、結尾填充、僅容許 ASCII 空白;
上限 8 MiB),再以 O_EXCL + fchmod 0600 寫進 context。P12 內容從不出現在 argv / 子行程環境 / log / stdout / stderr;`k1ctx` 的
stdout 只有 token / entry / 掃描報告行。(`security import` 讀取的是 context 內的 `p12.tmp`,匯入後立即 `remove-p12`;密碼經
`-P` / `-p` / `-k` 傳給 `security` 仍是 Apple CLI 唯一的非互動介面,值會短暫出現在 process listing —— 既有的已知殘留,不在
本工具範圍。)

## 秘密衛生掃描(N9)

`scan-secrets` 完整走訪每個根目錄(描述符相對、迭代深度上限 128):一般檔以 `openat(O_RDONLY|O_NOFOLLOW|O_NONBLOCK)` 開啟後
`fstat` 確認仍是一般檔才讀取(分塊 + 重疊區處理跨塊的 sentinel);symlink **不跟隨、不讀目標**(只計數);FIFO / socket /
裝置**不開啟**(不會阻塞;只計數);`--exclude <abs>` 的子樹是唯一允許的「明確排除」。根與排除都必須是**絕對正規路徑**
(無結尾 `/`、無 `//`、無 `.` / `..` 成分):排除是逐位元組的路徑成分前綴比對,非正規拼法(如 `/a/x/../b` 配上排除 `/a/x`)會在
CLI 層以 `scan-args` 拒絕、在程式庫層記為 ERROR(INCOMPLETE_SCAN),絕不會變成 CLEAN;根目錄本身位於排除子樹內時與其下項目
一致地計為 excluded。任何 opendir / readdir / stat / open /
read 失敗都記為 ERROR 並繼續走訪其餘部分,最終狀態:`SECRET_FOUND`(2)> `INCOMPLETE_SCAN`(1)> `CLEAN`(0)。**任何走訪錯誤
都不可能收斂成 CLEAN**(F-N2 的根因:count-based grep / find 吞掉 traversal error,在此結構上不存在)。stdout 每行
`MATCH <path>` / `ERROR <ERRNO> <op> <path>` / `SPECIAL <path>`,最後一行 `summary files= dirs= symlinks= special= excluded=
errors= matches= status=`。

## 威脅模型(N12)

K1 防禦的是:在操作邊界存在的畸形 / 過期 / 敵意檔案系統輸入(任意目錄、symlink、FIFO、目錄、錯誤 owner / 權限、偽造或
損壞的 marker、白名單以外的項目、不可存取的路徑),以及描述符相對操作所涵蓋的一般失敗 / 競爭情形(marker 在觀察與讀取之間
被換掉、context 被改名、上層不可寫、刪除失敗)。

K1 **不**宣稱能防禦一個已被入侵、同 uid、在整個生命週期中具備任意 syscall 競爭能力的惡意行程:它仍能在 `k1ctx` 驗證與
Apple CLI 依「路徑」開啟 keychain 之間換掉祖先目錄(Apple CLI 沒有 fd 介面可用);此排除**不得**用來放行可避免的 TOCTOU
錯誤 —— 凡平台 API 允許以描述符相對完成的操作,本工具一律以描述符相對完成,且每個命令都重新開啟並重新驗證 context(跨命令
沒有共享的 fd;連續性由路徑 + 身分檢查 + marker 建立)。

## 測試

- `Scripts/k1-native/Tests/main.swift`(`build.sh --tests`):errno 分類表、路徑語法、列舉(隱藏項、任意位元組檔名、
  失敗傳播、ACL)、marker 建立(symlink / FIFO / 目錄 / dangling / 既存)、marker 讀取(F-N1 決定性重現:較早的觀察 → 置換 →
  原生讀取以開啟到的物件拒絕,且不阻塞)、白名單、嚴格 base64、P12 exclusive 建立 / 移除 / unlink 失敗、rmdir 身分與寫回、
  掃描(F-N2:不可走訪子樹 + sentinel → INCOMPLETE_SCAN;FIFO;symlink;排除;跨塊;深度上限)。
- `Scripts/test-signing-pipeline.sh`:建置工具與測試 runner,再以 stateful fake `security` / `codesign` 驅動整個 K1 契約
  (K1-01…25、K1-R*、K1-S*、K1-N1 / K1-N2),並以 `k1ctx scan-secrets` 做整個 harness 的秘密衛生掃描。
