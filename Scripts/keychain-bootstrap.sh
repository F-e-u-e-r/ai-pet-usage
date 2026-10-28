#!/bin/bash
# keychain-bootstrap.sh — K1-NATIVE:顯式「臨時 signing keychain」的 bootstrap / cleanup 編排(thin shell adapter)+ 身分 preflight。
#
# ⚠️ K1 = OFFLINE ONLY:本檔「新增但未接線」—— 沒有任何 workflow 呼叫它;它只定義函式,讓 build-app.sh(developer-id 的
#    身分 preflight)與 Scripts/test-signing-pipeline.sh(以 fake security / codesign 離線驗證)使用。本檔不含、也不產生
#    任何真實 Apple 材料。把它接進 release workflow(context 建立、EXIT / if: always() 清理、GitHub Environment secrets、
#    concurrency 序列化、建置 k1ctx)是 PR-C2 的事。
#
# 責任模型(owner K1-NATIVE N1 / N11,凍結):
#   - 原生工具 k1ctx(Scripts/k1-native;以 Scripts/k1-native/build.sh 建置,路徑由呼叫端經 K1CTX_BIN 顯式提供)擁有所有安全
#     敏感的 context / 檔案系統行為:marker 的建立 / 讀取 / 寫回、context 列舉與白名單、解碼 P12 的建立 / 移除、context 的最後
#     移除、秘密衛生掃描。
#   - 本檔只做編排:呼叫 k1ctx、Apple 的 security / codesign,解讀明確的退出碼與 token。本檔「不」以 `<` 讀 marker、不以 `>`
#     建 marker、不以 glob 列舉 context、不以 grep / find 遞迴掃描、不以 shell 重導向落地 P12、不自行刪除 context 內的任何
#     檔案、不以 stat / [ -e ] 檢視 context 內部;唯一傳給 Apple CLI 的 context 內路徑是確定性的 <context>/signing.keychain-db
#     與 <context>/p12.tmp(Apple CLI 只有路徑介面)。
#
# 公開介面(可被 `source`;也可直接執行 `keychain-bootstrap.sh bootstrap|cleanup <context>`):
#   kc_bootstrap <context>
#       <context> 由呼叫端(未來 PR-C2)自己以 `mktemp -d` 建立並傳入:絕對正規路徑、既存目錄、非 symlink、屬於目前 uid、
#       權限恰為 0700、初始化前完全為空(由 k1ctx 判定)。本函式不建立、也不回傳 context —— 生命週期 handle 從不經 stdout
#       傳遞(成功時 stdout 為空)。臨時 keychain 的路徑是確定性的:<context>/signing.keychain-db(呼叫端自行推導
#       DEVELOPER_ID_KEYCHAIN="<context>/signing.keychain-db")。
#       輸入一律走環境變數(秘密不進本函式的 argv):
#         工具:K1CTX_BIN(已建置的 k1ctx 絕對路徑;一般檔、非 symlink、可執行;kc_bootstrap / kc_cleanup /
#               kc_identity_preflight —— 即 build-app.sh 的 developer-id 模式 —— 都需要它)
#         秘密:DEVELOPER_ID_P12_BASE64、DEVELOPER_ID_P12_PASSWORD、SIGNING_KEYCHAIN_PASSWORD(呼叫端每次 run 產生的隨機值);
#               每個公開函式的 subshell 是一個「秘密作用域」(見 _kc_scrub_secrets):先以 builtin 關掉 allexport,再把需要的值
#               複製到全新、未 export 的 local,然後 unset 三個正式名稱並去掉別名的 export 屬性 —— 任何子行程都不再繼承秘密,
#               不論呼叫端是否 set -a、是否預先 export 了別名名稱(無法 unset / 無法去除 export / 無法複製 → 拒絕)
#         非機密信任設定:DEVELOPER_ID_IDENTITY、EXPECTED_TEAM_ID、EXPECTED_DEVELOPER_ID_CERT_SHA256
#       退出碼:0 = keychain 就緒;1 = 副作用開始後失敗(呼叫端必須呼叫 kc_cleanup);2 = 任何副作用之前就拒絕(context 未被碰)。
#   kc_cleanup <context>
#       退出碼:0 = 清理完成;1 = 作業失敗(保留可診斷的 context,可修復後重試;也涵蓋「無法判定 context 是否存在」——
#       EACCES / ELOOP / I/O 錯誤 —— 與「無法完整列舉 context 內容」,此時零動作);2 = context 被拒(零動作);
#       3 = context 經 errno 可證實不存在(ENOENT / ENOTDIR;零動作)。3 只回報 CONTEXT_NOT_FOUND —— 本檔「不」把 3
#       解讀為清理成功;冪等 / 生命週期的解讀屬 PR-C2。
#   kc_identity_preflight <keychain> <identity> <expected-team-id> <expected-cert-sha256>
#       K7 身分 preflight(唯讀;kc_bootstrap 與 build-app.sh 共用這一份實作 = 同一套規則)。成功時 stdout 只有 derived
#       selector(身分列的憑證 SHA-1;owner F4:DERIVED IDENTITY JOIN / CODESIGN SELECTOR —— 不是信任輸入,見函式說明)。
#   kc_normalize_sha256 <value>
#       K6 形狀規則:恰 64 個十六進位字元 → stdout 輸出小寫;其餘一律拒絕(非零)。
#
# 刻意「不做」的事(owner 凍結的 K1 設計,N10 保留):
#   - 不明確取代 / 快照 / 還原 user 的 keychain search list,也不設定 / 快照 / 還原 default keychain(本檔沒有任何讀寫
#     search list / default keychain 的 security 子命令)。已接受的 Apple 工具副作用:`security create-keychain` 可能把新
#     keychain 加入 user search list、`security delete-keychain` 移除該筆;本檔不以全域快照 / 還原補償它們,其真實行為屬
#     LIVE-REHEARSAL 項目(FAKE-TESTED / LIVE-VERIFY)。
#   - 所有「省略 keychain 參數就作用在 default keychain」的 security 子命令一律帶顯式路徑。
#   - 不安裝任何 trap、不處理 EXIT / INT / TERM:生命週期編排(EXIT trap、if: always() 清理、呼叫端狀態追蹤、退出碼 3 的
#     冪等解讀、concurrency 序列化)全屬 PR-C2。
#   - 宣稱範圍只有:Signing identity lookup is explicitly confined to the specified signing keychain. 不宣稱憑證鏈 /
#     信任評估被隔離(man codesign --keychain:建構內嵌憑證鏈時仍查標準 keychain search path)。
#
# Source 安全(K12):頂層只有函式定義與「直接執行時」的分派 —— 沒有頂層 set / shopt / umask / trap,也不定義任何變數。
# 每個公開函式的本體都在 subshell 內執行,第一個敘述(整組 stdout / stderr 都導向 /dev/null)就清掉呼叫端經 errtrace /
# functrace 帶進來的 DEBUG / ERR / RETURN trap、關掉 xtrace / verbose / functrace / errtrace;接著把其餘會影響語意的 shell
# 狀態設成已知值(_kc_isolate)。這些設定都只在 subshell 內,不外洩給呼叫端。
# 呼叫端 shell 信任邊界(owner F9,凍結):K1 自己不開啟任何 tracing、不經自己的指令 / log / stdout / stderr 洩漏秘密、在
# 支援的乾淨 PR-C2 呼叫端下內部執行保持安靜;但 K1「不」宣稱能防禦在函式本體執行「之前」就已執行程式碼的惡意呼叫端
# shell(例如已啟用、會觀察函式呼叫本身的 DEBUG trap)—— 建立乾淨的生命週期 shell / 行程環境是 PR-C2 的責任。K1 也不為了
# 模擬更強的保證而去改動呼叫端的 shell 狀態(含 GLOBIGNORE 等呼叫端變數:不 unset、不改寫)。本檔沒有任何 shell glob、也
# 沒有任何「建立檔案」的 shell 重導向,所以 GLOBIGNORE / dotglob / nullglob / failglob / noclobber 等呼叫端狀態與本檔的
# 正確性無關。bash 3.2 相容(macOS /bin/bash)。
# 秘密衛生:不得 set -x;不得 echo / 記錄任何秘密值;三個秘密變數(與本檔的別名 local)在進入任何子行程之前就從 subshell 的
# 子行程環境移除(秘密作用域:_kc_isolate 關 allexport → _kc_unexport_aliases → 複製到 local → _kc_scrub_secrets);公開的
# kc_normalize_sha256 自己也是秘密作用域,且正規化只用 builtin、不產生任何子行程;base64 P12 只經 builtin printf → pipe →
# k1ctx(不進任何外部行程的 argv 或環境);security 的 -p / -P / -k 是 Apple 唯一的非互動介面,呼叫期間值會出現在 process
# listing(已知殘留;GitHub-hosted runner 為單租戶 VM)。

# 公開函式 subshell 內的已知 shell 狀態(trap / xtrace 已由各函式第一個敘述處理):關閉 errexit / nounset / noglob /
# errtrace / functrace(本檔以顯式退出碼控制流程;呼叫端若開 set -e,失敗的子命令會讓 subshell 以該子命令的退出碼提早
# 結束,破壞 0/1/2/3 契約)與 allexport(+a:呼叫端 set -a / SHELLOPTS=allexport 會讓本作用域之後的每個賦值 —— 含秘密的
# local 別名 —— 自動 export 給子行程;sol attempt-002 C-F1。這必須是本作用域內「任何賦值之前」的第一件事),關掉會改變 case
# 比對語意的 nocasematch,固定 IFS 與 C locale(十六進位字元類只認 ASCII),umask 077(防禦縱深;本檔自己不建立任何檔案,
# context 內的檔案一律由 k1ctx 以明確的 0600 建立)。
_kc_isolate() {
    set +e +u +f +E +T +a
    set -o pipefail
    shopt -u nocasematch 2>/dev/null
    IFS=$' \t\n'
    LC_ALL=C
    export LC_ALL
    umask 077
}

_kc_err() { printf '%s\n' "$*" >&2; }

# 秘密作用域(owner K1-NATIVE final remediation R1 / R2;sol attempt-001 D2 + attempt-002 C-F1 / C-F2):每個公開函式的 subshell
# 就是一個秘密作用域。在任何外部行程之前必須依序完成:(1) _kc_isolate 以 builtin 關掉 allexport;(2) _kc_unexport_aliases 去掉
# 三個別名名稱(p12b64 / p12pw / kcpw)可能從呼叫端繼承的 export 屬性(bash:local 會繼承同名全域變數的屬性,且 export -n 只
# 作用於可見的那一層 —— 所以要在宣告 local「之前」對呼叫端的全域變數做);(3) 需要的秘密值複製到全新、未 export 的 local
# (只有 kc_bootstrap 需要);(4) _kc_scrub_secrets 把三個正式秘密變數從子行程環境 unset,再複驗:正式名稱已不存在、allexport
# 已關、別名都不帶 export 屬性 —— 任一不成立即 fail-closed(呼叫端拒絕 / 不做任何動作)。只有在這之後才會執行第一個外部行程
# (k1ctx、security、codesign、sed、tr…),它們都不可能繼承任何秘密:不論呼叫端的 allexport 狀態、不論別名名稱是否被呼叫端預先
# export。呼叫端自己的環境 / 選項不受影響(subshell)。唯一的 fork 是 _kc_is_exported 的 command substitution(bash 子 shell 只
# 執行 builtin declare -p,從不 exec 任何外部程式)。呼叫端若把正式名稱設為 readonly,unset 會失敗 → fail-closed。
# 注意:security 的 -p / -P / -k 仍是 Apple 唯一的非互動介面,密碼會短暫出現在 process listing(已知殘留);base64 P12 則只經
# builtin printf → pipe → k1ctx,從不進任何子行程的 argv 或環境。
# 變數是否帶 export 屬性(declare -p 第一行的旗標欄;未定義 → 否)。$1=名稱。
_kc_is_exported() {
    local decl flags nl=$'\n'
    decl="$(declare -p "$1" 2>/dev/null)" || return 1
    decl="${decl%%"$nl"*}"; decl="${decl#declare -}"; flags="${decl%% *}"
    case "$flags" in *x*) return 0 ;; esac
    return 1
}
# allexport 必須已關;三個別名名稱一律去掉 export 屬性並複驗。失敗(allexport 仍開 / 別名仍 export)→ 1。
_kc_unexport_aliases() {
    local n
    case "$-" in *a*) return 1 ;; esac
    export -n p12b64 p12pw kcpw 2>/dev/null
    for n in p12b64 p12pw kcpw; do
        if _kc_is_exported "$n"; then return 1; fi
    done
    return 0
}
_kc_scrub_secrets() {
    unset DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD SIGNING_KEYCHAIN_PASSWORD 2>/dev/null || return 1
    if [ -n "${DEVELOPER_ID_P12_BASE64+x}${DEVELOPER_ID_P12_PASSWORD+x}${SIGNING_KEYCHAIN_PASSWORD+x}" ]; then return 1; fi
    _kc_unexport_aliases || return 1
    return 0
}

# 從 "Developer ID Application: Name (TEAMID)" 取出 TEAMID —— 與 build-app.sh 的 _expected_team_id 逐字相同的推導
# (PR-C1A 語意;test-signing-pipeline.sh 以同一組輸入比對兩者輸出,防漂移)。取不到則空。
_kc_team_of() {
    printf '%s\n' "$1" | sed -n 's/.*(\([A-Za-z0-9]\{1,\}\))[[:space:]]*$/\1/p'
}

# K6:EXPECTED_DEVELOPER_ID_CERT_SHA256 的唯一形狀規則。只接受恰 64 個十六進位字元(大小寫皆可),輸出小寫;
# 不做寬鬆正規化 —— 'SHA256:' 等前綴、冒號、空白 / 換行、截短值、40 hex 的 SHA-1 一律拒絕。
# 這是公開入口(build-app.sh 的 verify_signature 也直接呼叫),所以它自己就是一個秘密作用域(先 _kc_scrub_secrets),而且
# 正規化只用 bash builtin(逐字元 case 對映 A–F → a–f;bash 3.2 沒有 ${v,,}),不產生任何子行程 —— 不可能有任何子行程繼承
# 呼叫端 export 的秘密(sol attempt-002 C-F2;owner R4)。
kc_normalize_sha256() (
    { trap - DEBUG ERR RETURN; set +x +v +T +E; } >/dev/null 2>&1
    _kc_isolate
    _kc_scrub_secrets || return 1
    local v="${1-}" out="" c i=0
    case "$v" in
        '' | *[!0123456789abcdefABCDEF]*) return 1 ;;
    esac
    [ "${#v}" -eq 64 ] || return 1
    while [ "$i" -lt 64 ]; do
        c="${v:$i:1}"
        case "$c" in
            A) c=a ;; B) c=b ;; C) c=c ;; D) c=d ;; E) c=e ;; F) c=f ;;
        esac
        out="$out$c"
        i=$((i + 1))
    done
    printf '%s\n' "$out"
)

# 非機密信任輸入的形狀 / 一致性(在任何 keychain 查詢之前):身分類別、獨立 Team ID 形狀 + 與身分衍生值相符(PR-C1A)、
# 預期 leaf SHA-256 形狀(K6)。$1=identity $2=expected-team $3=expected-sha256 $4=呼叫者 $5=失敗 token。
_kc_check_trust_inputs() {
    local identity="$1" team="$2" sha="$3" who="$4" tok="$5" derived
    case "$identity" in
        "Developer ID Application: "*) ;;
        *) _kc_err "$who: $tok: identity-class: DEVELOPER_ID_IDENTITY 必須是 'Developer ID Application: …' 類別:'$identity'"; return 1 ;;
    esac
    case "$team" in
        '' | *[!A-Za-z0-9]*) _kc_err "$who: $tok: team-shape: EXPECTED_TEAM_ID 須為 10 碼英數:'$team'"; return 1 ;;
    esac
    if [ "${#team}" -ne 10 ]; then
        _kc_err "$who: $tok: team-shape: EXPECTED_TEAM_ID 須為 10 碼英數:'$team'"; return 1
    fi
    derived="$(_kc_team_of "$identity")"
    if [ "$derived" != "$team" ]; then
        _kc_err "$who: $tok: team-mismatch: 身分衍生的 Team('$derived')≠ EXPECTED_TEAM_ID('$team')"; return 1
    fi
    if ! kc_normalize_sha256 "$sha" >/dev/null; then
        _kc_err "$who: $tok: sha256-shape: EXPECTED_DEVELOPER_ID_CERT_SHA256 須恰為 64 個十六進位字元(不接受前綴、冒號、空白、截短值或 SHA-1):'$sha'"
        return 1
    fi
    return 0
}

# 原生工具的解析(N11):K1CTX_BIN 須為絕對路徑、既存一般檔、非 symlink、可執行。這是對「工具本身」的檢查,不是對 context
# 內部的檢視。成功時 stdout 輸出該路徑。
_kc_native_bin() {
    local b="${K1CTX_BIN:-}"
    case "$b" in
        /*) ;;
        *) return 1 ;;
    esac
    if [ -L "$b" ] || [ ! -f "$b" ] || [ ! -x "$b" ]; then return 1; fi
    printf '%s\n' "$b"
}

# 執行一個 k1ctx 命令:stdout 捕捉進 _kc_out(只含 token= / entry= 行,從不含秘密),stderr 透傳(診斷);從 stdout 取出
# token(失敗時)到 _kc_tok(取不到 → "native")。回傳 k1ctx 的退出碼。$1=bin $2=command $3=context。
_kc_native() {
    local bin="$1" cmd="$2" ctx="$3" rc
    _kc_out="$("$bin" "$cmd" "$ctx")"; rc=$?
    _kc_tok="$(_kc_out_field token)"
    [ -n "$_kc_tok" ] || _kc_tok=native
    return "$rc"
}
# 從 _kc_out 取第一個 "<key>=<value>" 行的 value(純 bash 逐行;無外部行程)。$1=key。
_kc_out_field() {
    local key="$1" rest="$_kc_out" line nl=$'\n'
    while [ -n "$rest" ]; do
        line="${rest%%"$nl"*}"
        if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*"$nl"}"; fi
        case "$line" in
            "$key="*) printf '%s\n' "${line#"$key"=}"; return 0 ;;
        esac
    done
    return 1
}
# _kc_out 是否含精確的 "entry=<name>" 行。$1=name。
_kc_out_has_entry() {
    local want="$1" rest="$_kc_out" line nl=$'\n'
    while [ -n "$rest" ]; do
        line="${rest%%"$nl"*}"
        if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*"$nl"}"; fi
        [ "$line" = "entry=$want" ] && return 0
    done
    return 1
}

# K7 身分 preflight —— 只在「顯式給定」的 keychain 檔查詢(find-identity / find-certificate 一律帶該路徑;不帶 keychain
# 參數的查詢會落到 user 的 search list,本函式沒有這種路徑),依序確立(owner F5 的 Step A–E):
#   (1)(2) Step A:該 keychain 內「恰一個」完整名稱精確等於 <identity> 的有效 codesigning 身分(find-identity -v -p
#          codesigning;identity 列 = 憑證 + 私鑰,私鑰存在即由「這是身分列而非純憑證」確立);類別為
#          'Developer ID Application: '(_kc_check_trust_inputs)。精確比對名稱(非子字串):摘要行 "N valid identities
#          found" 不會被誤當身分列。從該列取出 derived 憑證 SHA-1。
#   (3)    身分衍生的 Team == 獨立的 <expected-team-id>(PR-C1A 語意)。
#   (4)    Step B–D:同一個顯式 keychain 的 find-certificate -a -Z 記錄(每筆 SHA-256 / SHA-1 / keychain)中,SHA-1 等於
#          身分列 SHA-1 的記錄須「恰一筆」(0 筆 → cert-join-none;>1 筆 → cert-join-ambiguous;皆 fail-closed),該筆的
#          SHA-256 == 獨立的 <expected-cert-sha256> —— 這個 SHA-256 比對才是受信任的 leaf 綁定。
#   (5)    對應私鑰存在:(1)(2) 的身分列只為「憑證 + 私鑰」產生,(4) 以該列的 SHA-1 把身分連結到「正是這張憑證」的記錄,
#          所以被 SHA-256 釘選的就是擁有私鑰的那一張。標籤("labl")不是連結依據(同名標籤、無私鑰的憑證不能冒充)。
# login / default keychain 裡即使有完全相符的身分,也不能讓不含它的顯式 keychain 通過。
# SHA-1 的地位(owner F4 裁定,OPTION (a) TIGHTENED):DERIVED IDENTITY JOIN / CODESIGN SELECTOR —— 它是 Apple 工具為
# 私鑰身分輸出的衍生值,只用來 (a) 在同一個顯式 keychain 內把身分連到精確的憑證記錄、(b) 全部受信任檢查通過後當
# codesign --sign 的執行選擇器(man codesign:40 hex 視為憑證 SHA-1、不考慮名稱,也不經 identity preference 的間接;名稱
# 選擇則是子字串比對且先查 identity preference)。它「不是」預期設定值、不是信任綁定、不落盤、不是 SHA-256 的替代品;
# 信任綁定是 (3) 與 (4) 的 SHA-256。成功時 stdout 只輸出該 SHA-1(大寫 40 hex)。security 的 stdout 一律被捕捉進變數再
# 解析,從不轉發;stderr 透傳供診斷。
kc_identity_preflight() (
    { trap - DEBUG ERR RETURN; set +x +v +T +E; } >/dev/null 2>&1
    _kc_isolate
    local who=kc_identity_preflight nl=$'\n'
    local kc="${1-}" identity="${2-}" team="${3-}" sha="${4-}"
    local want out rc rest line name hash sel="" n=0 open=0 cur256="" cur1="" njoin=0 got="" bin _kc_out="" _kc_tok=""
    if [ "$#" -ne 4 ]; then
        _kc_err "$who: FAILED: usage: kc_identity_preflight <keychain> <identity> <expected-team-id> <expected-cert-sha256>"; return 1
    fi
    # 本函式不需要任何秘密;先把呼叫端可能 export 的秘密從 subshell 環境移除,之後的 sed / tr / security / k1ctx 都不繼承。
    _kc_scrub_secrets || { _kc_err "$who: FAILED: secret-env: 無法從子行程環境移除秘密變數(呼叫端設為 readonly?)"; return 1; }
    case "$kc" in
        /*) ;;
        *) _kc_err "$who: FAILED: keychain-path: 簽名 keychain 須為顯式的絕對路徑:'$kc'"; return 1 ;;
    esac
    # K5 物件形狀(絕對正規路徑、既存、一般檔、非 symlink)由 k1ctx check-keychain-path 判定(開啟 O_NOFOLLOW|O_NONBLOCK 後
    # fstat 同一 fd;不讀內容):shell 不對 keychain 路徑做任何 metadata 檢視(N1)。developer-id 模式因此需要 K1CTX_BIN。
    bin="$(_kc_native_bin)" || { _kc_err "$who: FAILED: tool-missing: K1CTX_BIN 須指向已建置的 k1ctx(絕對路徑、一般檔、非 symlink、可執行;developer-id 模式的身分 preflight 需要它)"; return 1; }
    if ! _kc_native "$bin" check-keychain-path "$kc"; then
        _kc_err "$who: FAILED: keychain-path: 簽名 keychain 須為既存的一般檔(非 symlink;k1ctx check-keychain-path 拒絕:$_kc_tok):$kc"; return 1
    fi
    _kc_check_trust_inputs "$identity" "$team" "$sha" "$who" FAILED || return 1
    want="$(kc_normalize_sha256 "$sha")" || { _kc_err "$who: FAILED: sha256-shape: 無法正規化 EXPECTED_DEVELOPER_ID_CERT_SHA256"; return 1; }

    out="$(security find-identity -v -p codesigning "$kc")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        _kc_err "$who: FAILED: find-identity: security find-identity 失敗(exit $rc):$kc"; return 1
    fi
    rest="$out"
    while [ -n "$rest" ]; do
        line="${rest%%"$nl"*}"
        if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*"$nl"}"; fi
        case "$line" in
            *[0-9]\)\ [0-9A-Fa-f][0-9A-Fa-f]*\ \"*\") ;;   # 「  N) <hex-hash> "NAME"」;摘要行不匹配
            *) continue ;;
        esac
        name="${line#*\"}"; name="${name%\"*}"           # 首尾雙引號之間 = 完整身分名稱
        [ "$name" = "$identity" ] || continue
        hash="${line#*) }"; hash="${hash%% *}"
        n=$((n + 1))
        sel="$hash"
    done
    if [ "$n" -eq 0 ]; then
        _kc_err "$who: FAILED: identity-absent: 顯式 keychain 中沒有(含私鑰的)有效身分 '$identity':$kc"; return 1
    fi
    if [ "$n" -gt 1 ]; then
        _kc_err "$who: FAILED: identity-ambiguous: 顯式 keychain 中 '$identity' 有 $n 個同名身分(歧義):$kc"; return 1
    fi
    case "$sel" in
        '' | *[!0123456789abcdefABCDEF]*) _kc_err "$who: FAILED: identity-hash: 身分列的憑證 SHA-1 形狀不符:'$sel'"; return 1 ;;
    esac
    if [ "${#sel}" -ne 40 ]; then
        _kc_err "$who: FAILED: identity-hash: 身分列的憑證 SHA-1 須為 40 個十六進位字元:'$sel'"; return 1
    fi
    sel="$(printf '%s\n' "$sel" | tr 'abcdef' 'ABCDEF')" || { _kc_err "$who: FAILED: identity-hash: 無法正規化"; return 1; }

    out="$(security find-certificate -a -Z "$kc")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        _kc_err "$who: FAILED: find-certificate: security find-certificate 失敗(exit $rc):$kc"; return 1
    fi
    # 每筆記錄依序為 'SHA-256 hash: <hex>'、'SHA-1 hash: <hex>'、'keychain: "<path>"'、…、屬性列(本機 macOS 實測格式)。
    # 狀態機(owner F7):'SHA-256 hash:' 開啟新記錄並「重設」全部逐筆欄位;'SHA-1 hash:' 只在記錄開啟時填入;
    # 'keychain:' 提交該記錄 —— 提交時三個構成要素(SHA-256、SHA-1、keychain 列)缺一即為不完整記錄 → 整個 preflight
    # fail-closed,絕不繼承前一筆的值。記錄之外出現 'SHA-1 hash:' / 'keychain:'、記錄開啟時又遇到 'SHA-256 hash:'、
    # 輸出結尾仍有未提交的記錄 → 同樣 fail-closed。屬性列(含 "labl")不參與連結。提交時以該筆 SHA-1 == 身分列 SHA-1
    # 連結(Step C);連結到的記錄數必須恰為 1(Step C),其 SHA-256 再與預期值比對(Step D)。
    rest="$out"
    while [ -n "$rest" ]; do
        line="${rest%%"$nl"*}"
        if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*"$nl"}"; fi
        case "$line" in
            "SHA-256 hash: "*)
                if [ "$open" -eq 1 ]; then
                    _kc_err "$who: FAILED: cert-record-incomplete: 憑證記錄缺 keychain 列(下一筆已開始):$kc"; return 1
                fi
                open=1; cur256="${line#SHA-256 hash: }"; cur1="" ;;
            "SHA-1 hash: "*)
                if [ "$open" -ne 1 ]; then
                    _kc_err "$who: FAILED: cert-record-incomplete: SHA-1 列出現在記錄之外(缺 SHA-256 列):$kc"; return 1
                fi
                cur1="${line#SHA-1 hash: }" ;;
            'keychain: "'?*'"')
                if [ "$open" -ne 1 ] || [ -z "$cur256" ] || [ -z "$cur1" ]; then
                    _kc_err "$who: FAILED: cert-record-incomplete: 憑證記錄缺 SHA-256 或 SHA-1 列:$kc"; return 1
                fi
                case "$cur1" in
                    *[!0123456789abcdefABCDEF]*) _kc_err "$who: FAILED: cert-record-incomplete: 憑證記錄的 SHA-1 形狀不符:'$cur1'"; return 1 ;;
                esac
                if [ "${#cur1}" -ne 40 ]; then
                    _kc_err "$who: FAILED: cert-record-incomplete: 憑證記錄的 SHA-1 須為 40 個十六進位字元:'$cur1'"; return 1
                fi
                cur1="$(printf '%s\n' "$cur1" | tr 'abcdef' 'ABCDEF')" || { _kc_err "$who: FAILED: cert-record-incomplete: 無法正規化 SHA-1"; return 1; }
                if [ "$cur1" = "$sel" ]; then njoin=$((njoin + 1)); got="$cur256"; fi
                open=0; cur256=""; cur1="" ;;
        esac
    done
    if [ "$open" -eq 1 ]; then
        _kc_err "$who: FAILED: cert-record-incomplete: 最後一筆憑證記錄缺 keychain 列:$kc"; return 1
    fi
    if [ "$njoin" -eq 0 ]; then
        _kc_err "$who: FAILED: cert-join-none: 顯式 keychain 中沒有 SHA-1 等於身分列($sel)的憑證記錄(無法把私鑰身分連結到憑證):$kc"; return 1
    fi
    if [ "$njoin" -gt 1 ]; then
        _kc_err "$who: FAILED: cert-join-ambiguous: 顯式 keychain 中 SHA-1 等於身分列($sel)的憑證記錄有 $njoin 筆(無法唯一連結):$kc"; return 1
    fi
    got="$(kc_normalize_sha256 "$got")" || { _kc_err "$who: FAILED: cert-record: 連結到的憑證記錄 SHA-256 形狀不符"; return 1; }
    if [ "$got" != "$want" ]; then
        _kc_err "$who: FAILED: leaf-sha256-mismatch: leaf 憑證 SHA-256($got)≠ EXPECTED_DEVELOPER_ID_CERT_SHA256($want)"; return 1
    fi
    printf '%s\n' "$sel"
)

# K3 臨時 keychain 生命週期(owner 凍結的順序):驗證 → marker(k1ctx context-init)→ (1) create → (2) timeout / 上鎖設定 →
# (3) unlock → (4) 在 context 內安全建立解碼 P12(k1ctx write-p12)→ (5) import → (6) 立即刪除解碼 P12(k1ctx remove-p12;
# 刪除失敗 = bootstrap 失敗)→ (7) signing-key 存取設定 → (8) 以 kc_identity_preflight 驗證預期身分存在於「這個」keychain。
# 每個 security 呼叫:stdout → /dev/null(真實 import 會印 "1 identity imported."、set-key-partition-list 會印 key 屬性),
# stderr 透傳(診斷);任何子命令都帶顯式 keychain 路徑。bootstrap 失敗時「不」自行刪 keychain:唯一的破壞性路徑是
# kc_cleanup(呼叫端必須在任何退出碼 1 之後呼叫它)。
kc_bootstrap() (
    { trap - DEBUG ERR RETURN; set +x +v +T +E; } >/dev/null 2>&1
    _kc_isolate
    local who=kc_bootstrap ctx="${1-}" bin kc p12 rc _kc_out="" _kc_tok=""
    # 秘密作用域(見 _kc_scrub_secrets):allexport 已由 _kc_isolate 關掉;先去掉呼叫端可能預先 export 的別名名稱的 export 屬性
    # (local 會繼承同名全域變數的屬性),再把秘密複製到全新、未 export 的 local;複製失敗(呼叫端把別名設為 readonly)→ 拒絕。
    _kc_unexport_aliases || { _kc_err "$who: REJECTED: secret-env: 無法建立未 export 的秘密作用域(allexport 仍開或別名的 export 屬性無法去除)"; return 2; }
    local p12b64="${DEVELOPER_ID_P12_BASE64:-}" p12pw="${DEVELOPER_ID_P12_PASSWORD:-}" kcpw="${SIGNING_KEYCHAIN_PASSWORD:-}" \
        || { _kc_err "$who: REJECTED: secret-env: 無法把秘密複製到本作用域的 local(呼叫端把別名設為 readonly?)"; return 2; }
    # ---- 任何副作用之前的驗證(失敗 → 2;context 不被碰)
    if [ "$#" -ne 1 ]; then _kc_err "$who: REJECTED: usage: kc_bootstrap <context>"; return 2; fi
    if [ -z "$ctx" ]; then _kc_err "$who: REJECTED: context-empty: context 參數為空"; return 2; fi
    case "$ctx" in
        /*) ;;
        *) _kc_err "$who: REJECTED: context-relative: context 須為絕對路徑:$ctx"; return 2 ;;
    esac
    # 秘密已複製到 local;在呼叫任何子行程(含 _kc_check_trust_inputs 的 sed / tr)之前把它們從 subshell 環境移除。
    _kc_scrub_secrets || { _kc_err "$who: REJECTED: secret-env: 無法從子行程環境移除秘密變數(呼叫端設為 readonly?);拒絕在秘密會外洩給子行程的情況下繼續"; return 2; }
    bin="$(_kc_native_bin)" || { _kc_err "$who: REJECTED: tool-missing: K1CTX_BIN 須指向已建置的 k1ctx(絕對路徑、一般檔、非 symlink、可執行;Scripts/k1-native/build.sh)"; return 2; }
    if [ -z "$p12b64" ]; then _kc_err "$who: REJECTED: input-missing: 缺 DEVELOPER_ID_P12_BASE64"; return 2; fi
    if [ -z "$p12pw" ]; then _kc_err "$who: REJECTED: input-missing: 缺 DEVELOPER_ID_P12_PASSWORD"; return 2; fi
    if [ -z "$kcpw" ]; then _kc_err "$who: REJECTED: input-missing: 缺 SIGNING_KEYCHAIN_PASSWORD"; return 2; fi
    _kc_check_trust_inputs "${DEVELOPER_ID_IDENTITY:-}" "${EXPECTED_TEAM_ID:-}" "${EXPECTED_DEVELOPER_ID_CERT_SHA256:-}" "$who" REJECTED || return 2
    kc="$ctx/signing.keychain-db"
    p12="$ctx/p12.tmp"
    # context 的信任性質(絕對正規路徑、目錄、非 symlink、owner uid、0700、含隱藏項完全為空)與第一個副作用(版本化 ownership
    # marker,O_CREAT|O_EXCL|O_NOFOLLOW、0600、精確位元組)全由 k1ctx 判定 / 執行。errno 分類(owner F2):可證實不存在(3)與
    # 無法判定 / 無法列舉(1)在此都尚無副作用 → 2;只有「驗證全過、marker 建立本身失敗」才是 1。
    _kc_native "$bin" context-init "$ctx"; rc=$?
    case "$rc" in
        0) ;;
        3) _kc_err "$who: REJECTED: context-missing: context 不存在(須由呼叫端預先建立):$ctx"; return 2 ;;
        1)
            if [ "$_kc_tok" = marker-create ]; then
                _kc_err "$who: FAILED: marker: 無法建立 ownership marker(k1ctx context-init):$ctx"; return 1
            fi
            _kc_err "$who: REJECTED: $_kc_tok: 無法判定或列舉 context(k1ctx context-init 作業失敗;不做任何動作):$ctx"; return 2 ;;
        *) _kc_err "$who: REJECTED: $_kc_tok: context 被 k1ctx 拒絕(不做任何動作):$ctx"; return 2 ;;
    esac
    # (1) 在 context 內建立恰一個臨時 keychain(確定性路徑;Apple CLI 只有路徑介面)。
    if ! security create-keychain -p "$kcpw" "$kc" >/dev/null; then
        _kc_err "$who: FAILED: create-keychain: security create-keychain 失敗:$kc"; return 1
    fi
    # create 之後由 k1ctx 重新驗證 context(marker 仍精確、內容 ⊆ 白名單、每項皆一般檔非 symlink)並確認 keychain 檔確實
    # 存在 —— shell 不自行 stat / [ -f ] context 內部。
    _kc_native "$bin" context-validate "$ctx"; rc=$?
    if [ "$rc" -ne 0 ] || ! _kc_out_has_entry signing.keychain-db; then
        _kc_err "$who: FAILED: keychain-file: create-keychain 後預期的 keychain 檔不存在、不是一般檔,或 context 已不符信任契約(k1ctx exit $rc,$_kc_tok):$kc"; return 1
    fi
    # (2) 系統睡眠即上鎖(-l)、閒置逾時即上鎖(-u -t 3600)。理由:不倚賴新建 keychain 的預設逾時(其值未經本機文件
    #     確認;過短會讓無互動環境的 codesign 在 bootstrap → Swift build → 簽名之間因重新上鎖而失敗);一小時足以涵蓋
    #     單一 job 內 build + 簽名(本 repo 的 swift-tests job 上限 20 分鐘;公證等待不需 keychain),又讓遺留未清理的
    #     keychain 在一小時內自動重新上鎖。必帶路徑:省略路徑會改到 default keychain。
    if ! security set-keychain-settings -l -u -t 3600 "$kc" >/dev/null; then
        _kc_err "$who: FAILED: set-keychain-settings: security set-keychain-settings 失敗:$kc"; return 1
    fi
    # (3) 解鎖(必帶路徑:省略會解鎖 default keychain)。
    if ! security unlock-keychain -p "$kcpw" "$kc" >/dev/null; then
        _kc_err "$who: FAILED: unlock-keychain: security unlock-keychain 失敗:$kc"; return 1
    fi
    # (4) 解碼 P12 到 context 內的固定檔名:base64 文字只經 builtin printf → pipe → k1ctx(不進任何外部行程的 argv、不經
    #     暫存檔);k1ctx 在行程內嚴格解碼,再以 O_CREAT|O_EXCL|O_NOFOLLOW(0600)原子建立 —— 路徑上已有任何東西(含 symlink、
    #     FIFO)即失敗,不跟隨、不覆寫、不阻塞。解碼失敗 / 空 / 路徑被佔用都 → 1(此時 keychain 已存在,留給 kc_cleanup)。
    #     k1ctx 保證失敗時不留任何部分檔(解碼在建立之前完成;寫入失敗即自行 unlink),故此處不做任何補救刪除 —— 被植入的
    #     物件(symlink / FIFO…)原封不動留給 kc_cleanup 拒絕(零動作、可診斷)。
    _kc_out="$(printf '%s' "$p12b64" | "$bin" write-p12 "$ctx")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        _kc_tok="$(_kc_out_field token)"; [ -n "$_kc_tok" ] || _kc_tok=native
        _kc_err "$who: FAILED: $_kc_tok: 無法把 DEVELOPER_ID_P12_BASE64 解碼並安全寫成非空的 P12(k1ctx write-p12 exit $rc):$p12"
        return 1
    fi
    # (5) 匯入(必帶 -k:省略會匯入 default keychain)。只授權 /usr/bin/codesign 存取私鑰(-T);不用 -A。
    security import "$p12" -k "$kc" -f pkcs12 -P "$p12pw" -T /usr/bin/codesign >/dev/null; rc=$?
    # (6) 不論匯入成敗,立即刪除解碼 P12(k1ctx remove-p12:unlinkat + 確認消失);刪除失敗 = bootstrap 失敗(fatal)。
    if ! _kc_native "$bin" remove-p12 "$ctx"; then
        _kc_err "$who: FAILED: p12-unlink: 無法刪除解碼後的 P12(秘密材料仍在磁碟上,呼叫端必須處理並執行 kc_cleanup):$p12"
        if [ "$rc" -ne 0 ]; then _kc_err "$who: FAILED: import: security import 失敗(exit $rc)"; fi
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        _kc_err "$who: FAILED: import: security import 失敗(exit $rc):$kc"; return 1
    fi
    # (7) signing-key 存取:man security —— 要讓 /usr/bin/codesign 使用該 key,"apple:" 必須在 partition list 內。只給這一個
    #     分區(最小權限);-s 只匹配可簽名的 key;-k 是唯一的非互動介面(已標 deprecated,值會短暫出現在 process
    #     listing)。是否足夠 = LIVE-REHEARSAL 項目。必帶路徑:省略會套用到 default search list。
    if ! security set-key-partition-list -S apple: -s -k "$kcpw" "$kc" >/dev/null; then
        _kc_err "$who: FAILED: set-key-partition-list: security set-key-partition-list 失敗:$kc"; return 1
    fi
    # (8) 預期身分必須存在於「這個」keychain(與 build-app.sh 相同的 K7 規則;derived selector 在此丟棄)。
    if ! kc_identity_preflight "$kc" "$DEVELOPER_ID_IDENTITY" "$EXPECTED_TEAM_ID" "$EXPECTED_DEVELOPER_ID_CERT_SHA256" >/dev/null; then
        _kc_err "$who: FAILED: identity-preflight: 預期的簽名身分不在這個臨時 keychain(或不符合綁定):$kc"; return 1
    fi
    return 0
)

# K10 cleanup 狀態機。驗證順序(凍結):1 空參數 → 2;2 非絕對路徑 → 2;3 由 k1ctx context-validate 以 errno 判定:可證實
# 不存在(ENOENT / ENOTDIR)→ 3;查找被拒(EACCES)、symlink 迴圈(ELOOP)、I/O 錯誤、列舉不完整 → 1(owner F2:作業失敗,
# 零動作,不是冪等成功);4 既存路徑的信任性質(正規路徑、是目錄、非 symlink、owner uid、權限 0700、逐位元組相符且經 fstat
# 判定型別 / 權限 / 大小的 K1 marker、內容 ⊆ 白名單且皆為一般檔)任一不符 → 2。破壞性動作只發生在全部驗證通過之後,且只
# 動 K1 自己的物件:殘留的解碼 P12(秘密,最先;k1ctx remove-p12)、精確的臨時 keychain(只經 Apple 的 security
# delete-keychain)、marker 與空 context(最後;k1ctx context-finalize:marker 最後刪、以父目錄 fd + dev:inode 身分 rmdir)。
# 永不 rm -rf。任一刪除失敗 → 1,並保留 marker 與 context 供診斷 / 修復後重試(秘密物件仍會各自嘗試刪除);最後的 rmdir
# 失敗時 k1ctx 以同一個 O_EXCL 原語把 marker 原樣寫回(路徑被佔用就明說、不阻塞),讓修復後的重試仍認得這個 context。
kc_cleanup() (
    { trap - DEBUG ERR RETURN; set +x +v +T +E; } >/dev/null 2>&1
    _kc_isolate
    local who=kc_cleanup ctx="${1-}" bin kc rc _kc_out="" _kc_tok="" status=0 has_p12=0 has_kc=0
    if [ "$#" -ne 1 ]; then _kc_err "$who: CONTEXT_REJECTED: usage: kc_cleanup <context>"; return 2; fi
    if [ -z "$ctx" ]; then _kc_err "$who: CONTEXT_REJECTED: context-empty: context 參數為空"; return 2; fi
    case "$ctx" in
        /*) ;;
        *) _kc_err "$who: CONTEXT_REJECTED: context-relative: context 須為絕對路徑:$ctx"; return 2 ;;
    esac
    # cleanup 不需要任何秘密;呼叫端(同一個 job)可能仍 export 著它們 → 先從 subshell 環境移除,k1ctx / security 都不繼承。
    _kc_scrub_secrets || { _kc_err "$who: CLEANUP_FAILED: secret-env: 無法從子行程環境移除秘密變數(呼叫端設為 readonly?);不做任何動作"; return 1; }
    bin="$(_kc_native_bin)" || { _kc_err "$who: CLEANUP_FAILED: tool-missing: K1CTX_BIN 須指向已建置的 k1ctx(絕對路徑、一般檔、非 symlink、可執行);不做任何動作"; return 1; }
    kc="$ctx/signing.keychain-db"
    _kc_native "$bin" context-validate "$ctx"; rc=$?
    case "$rc" in
        0) ;;
        3) _kc_err "$who: CONTEXT_NOT_FOUND: $ctx"; return 3 ;;
        1) _kc_err "$who: CLEANUP_FAILED: $_kc_tok: 無法判定 context 是否存在或無法完整列舉(k1ctx context-validate);不做任何動作:$ctx"; return 1 ;;
        *) _kc_err "$who: CONTEXT_REJECTED: $_kc_tok: 不是可清理的 K1 context(k1ctx context-validate);不做任何動作:$ctx"; return 2 ;;
    esac
    # 存在的白名單項目(從 context-validate 的 stdout 取得;之後的 k1ctx 呼叫會覆寫 _kc_out,故先記下)。
    _kc_out_has_entry p12.tmp && has_p12=1
    _kc_out_has_entry signing.keychain-db && has_kc=1
    # 殘留的解碼 P12(崩潰遺留;秘密最先)。
    if [ "$has_p12" -eq 1 ]; then
        if ! _kc_native "$bin" remove-p12 "$ctx"; then
            _kc_err "$who: CLEANUP_FAILED: p12-unlink: 無法刪除殘留的解碼 P12:$ctx/p12.tmp"; status=1
        fi
    fi
    # 精確的臨時 keychain,只經 Apple 的 delete-keychain(k1ctx 已確認它是 context 內的一般檔、非 symlink)。
    if [ "$has_kc" -eq 1 ]; then
        if ! security delete-keychain "$kc" >/dev/null; then
            _kc_err "$who: CLEANUP_FAILED: delete-keychain: security delete-keychain 失敗(context 保留供診斷 / 重試):$kc"; status=1
        fi
    fi
    if [ "$status" -ne 0 ]; then return 1; fi
    # marker 最後刪、rmdir(k1ctx:要求 context 只剩 marker —— delete-keychain 回報成功但檔仍在、或 P12 仍在 → residual-entry
    # → 1;rmdir 失敗 → marker 寫回 → 1)。
    _kc_native "$bin" context-finalize "$ctx"; rc=$?
    case "$rc" in
        0) return 0 ;;
        2) _kc_err "$who: CONTEXT_REJECTED: $_kc_tok: context 在清理途中已不符信任契約(k1ctx context-finalize);不再動它:$ctx"; return 2 ;;
        *) _kc_err "$who: CLEANUP_FAILED: $_kc_tok: 無法完成 context 的移除(k1ctx context-finalize exit $rc);context 保留供診斷 / 重試:$ctx"; return 1 ;;
    esac
)

# 直接執行時的分派(被 `source` 時不執行)。
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    if [ "$#" -eq 2 ] && [ "$1" = bootstrap ]; then kc_bootstrap "$2"; exit $?; fi
    if [ "$#" -eq 2 ] && [ "$1" = cleanup ]; then kc_cleanup "$2"; exit $?; fi
    echo "usage: keychain-bootstrap.sh bootstrap|cleanup <context>(或 source 後呼叫 kc_bootstrap / kc_cleanup)" >&2
    exit 2
fi
