#!/bin/bash
# L1/L2 離線 falsification 套件:可選 Developer ID 簽名管線(PR-B)。證明「編排會 fail-closed」——以 fake 工具
# (codesign / security / xcrun{notarytool,stapler} / spctl / gh)離線驗證,不碰真實憑證、不聯繫 Apple、不發佈任何東西。
#
# 手法與 Scripts/test-release-version.sh 相同:$TMP/bin 放 PATH-prepend 的 fake 工具,每個 fake 記錄 argv 到 log 並讀
# 環境旗標(FAKE_*)決定 exit code / 輸出;mktemp -d + trap 清理;pass/fail/ok/bad/check。被測的編排以 `source` 取得
# 函式(build-app.sh / notarize-app.sh 的 source-guard 讓 source 時只定義函式、不執行),在 bash -c 子行程內以 fake
# 工具驅動。另有一節以「暫時 root + fake swiftpm」實際「執行」build-app.sh 的 main(),驗證 validate 在 Swift build
# 「之前」的整合順序(光測單一函式無法鎖住此屬性)。
#
# 覆蓋 VERIFICATION-CONTRACT §3 的 17 個預註冊負向案例 + 配對 GREEN。每案「先證 RED 再證 GREEN」(標準 packet-fidelity
# 規則:gate 首用先證明會 RED)。case 1–7/15/16 走 build-app.sh 簽名路徑;case 8–11 走 notarize-app.sh;case 12–14/17
# 另含對「現有」release-app.yml 的靜態斷言(讀取、不執行)+ notarize-app.sh 的 A3 閘/A4 紀錄函式。
#
# K1-NATIVE(Scripts/keychain-bootstrap.sh thin adapter + Scripts/k1-native 原生工具 k1ctx + build-app.sh 的顯式 keychain /
# leaf SHA-256 綁定):fake security 是 stateful oracle —— 每個 fake keychain 檔各自的憑證 / 私鑰集合、模擬的 user search list
# (create-keychain 加入、delete-keychain 移除)、依操作的故障注入、可控的 stdout 雜訊;fake codesign 依 --keychain / selector
# 解析身分,並忠實回報實際所簽身分與內嵌 leaf。K1 一節先以 Scripts/k1-native/build.sh 從這份 checkout 編譯 k1ctx 與其單元測試
# runner(K1-N0;編譯失敗 = FATAL),再涵蓋 owner Gate K15 的 25 項 falsification 矩陣(K1-01…25)、K1-R1…R8 的 remediation
# 契約(readonly GLOBIGNORE、errno 分類、marker O_EXCL 建立 / 寫回與同 uid 競爭者、P12 I/O、身分列 SHA-1 → 憑證記錄 join、
# ACL 列舉失敗)、K1-N1(F-N1 回歸:marker 在較早觀察與原生讀取之間被置換 → 只以開啟到的物件判定、不阻塞)、K1-N2(F-N2
# 回歸:不可走訪子樹 + sentinel → INCOMPLETE_SCAN)、source 安全、靜態的 shell / native 責任分割,以及以 k1ctx scan-secrets
# 做的全 harness 秘密衛生掃描。所有 Apple 工具行為一律 shim;不建立真實 keychain、不碰真實憑證。
#
# 執行:/bin/bash Scripts/test-signing-pipeline.sh   (exit 0 = 全數通過)
set -uo pipefail
export LC_ALL=C

# F8:清除任何繼承的同名工具「函式」與 BASH_ENV,確保子行程一律解析到 PATH-prepend 的 fake shim,而非被 exported
# function / BASH_ENV 劫持到真實 gh/codesign/… —— 否則綠色閘門內模擬的 `gh release create` 可能變成真實發佈。
unset -f gh codesign security xcrun spctl id 2>/dev/null || true
unset BASH_ENV 2>/dev/null || true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/Scripts/build-app.sh"
NOTARIZE="$ROOT/Scripts/notarize-app.sh"
KCB="$ROOT/Scripts/keychain-bootstrap.sh"
K1N="$ROOT/Scripts/k1-native"
RV="$ROOT/Scripts/release-version.sh"
WF="$ROOT/.github/workflows/release-app.yml"
TMP="$(mktemp -d)"
# F7:mktemp 失敗時 TMP 會為空,後續 "$TMP/bin/…" 會塌成 "/bin/…" —— 在可寫環境可能覆寫真實系統工具。先 fail-fast。
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FATAL: mktemp -d 失敗,拒絕執行(避免 shim 寫到 /bin)"; exit 1; }
# K1 的 unlink 故障注入會把檔案設為 uchg(不可刪)、部分案會暫時拿掉目錄權限或加上 ACL deny-list(K1-R8);清理前先遞迴
# 解除 / 恢復,避免殘留在 TMPDIR。
trap 'chmod -RN "$TMP" 2>/dev/null; chflags -R nouchg "$TMP" 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
# new_state 於 $() 子行程偵測到致命狀況時以 kill -TERM $$ 終止「父」行程(exit 只會退出子行程);此 trap 收訊後乾淨退出。
trap 'exit 1' TERM

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
red() { if [ "$2" -ne 0 ]; then ok; else bad "$1: 預期 RED(非零)卻得 0"; fi; }
green() { if [ "$2" -eq 0 ]; then ok; else bad "$1: 預期 GREEN(0)卻得 $2"; fi; }

# ---------------------------------------------------------------- fake 工具(PATH-prepend)
mkdir -p "$TMP/bin"

cat > "$TMP/bin/codesign" <<'FAKE'
#!/bin/bash
# fake codesign。argv → $FAKE_DIR/codesign.log。模式:--sign(簽)/ --verify / -d --extract-certificates=<前綴>(抽憑證)/
# -dvvv(顯示)/ -d --entitlements -(傾印)。
# 旗標:FAKE_SIGN_FAIL=1 簽失敗;FAKE_VERIFY_FAIL=1 verify 失敗;FAKE_RB_NEEDS_SIGNING=1 資源 bundle 未簽前 verify 報
# 其專屬錯誤(A2);FAKE_TEAM_ID / FAKE_AUTHORITY / FAKE_RUNTIME_FLAG(0=無 runtime)控制 -dvvv;FAKE_AIPET_TEAM /
# FAKE_AIPET_RUNTIME 針對巢狀 aipet 覆寫(測 verify 是否對每個 executable 項都查);FAKE_ENTITLEMENTS(sandbox|cs|空)
# 控制 entitlements 傾印(FAKE_AIPET_ENTITLEMENTS 覆寫巢狀 aipet,「設為空字串」= 明確乾淨、不繼承外層)。
# F1:FAKE_TIMESTAMP_FLAG / FAKE_AIPET_TIMESTAMP(0=無安全時間戳)控制 -dvvv 是否印 'Timestamp='(預設忠實依實際所簽
# 的 --timestamp);用來模擬「命令列看似正常但結果簽章無安全時間戳」(如 --timestamp=none / 時間戳遺失)。
# K1:Developer-ID 簽名(--sign 非 '-')依 man codesign 的 SIGNING IDENTITIES 解析身分 —— 有 --keychain <檔> 時「只」在該
# fake keychain 找;沒有時在模擬的 user search list($FAKE_DIR/search.list,未建立時 = FAKE_LOGIN_KEYCHAIN +
# FAKE_SEARCH_LIST_DEFAULT)找;不論哪種,身分所在的 keychain 都必須在模擬 search list 上(man 的前提)。40 個十六進位 =
# 憑證 SHA-1(不看名稱);其他 = 名稱子字串比對(精確優先;多個相符 = 歧義失敗)。只有「有私鑰、有效、可用於 code
# signing」的憑證才是身分;所用 keychain 須已 unlock 且 partition list 含 "apple:"(man security),否則像無互動環境的
# 真實 codesign 一樣失敗。簽名記錄(項目、實際
# 解析出的身分名稱、runtime、timestamp、leaf 憑證 bytes、所用 keychain)寫入 signed.map,供 -dvvv(Authority = 實際所簽
# 身分)與 --extract-certificates(leaf = 實際所簽憑證)「忠實」回報。FAKE_LEAF_CONTENT / FAKE_AIPET_LEAF_CONTENT 覆寫
# 抽出的 leaf bytes(模擬成品內嵌的不是預期那張憑證)。--extract-certificates 不帶 '=' 時,如真實工具般以預設前綴
# "codesign" 寫到目前目錄(man codesign:可選值選項的 '--name value' 形式不會如預期運作)。
D="$FAKE_DIR"
TAB="$(printf '\t')"
printf '%s\n' "$*" >> "$D/codesign.log"
is_sign=0; is_verify=0; is_dumpent=0; is_display=0; is_extract=0; pfx=""
signid=""; kc=""; rt=0; ts=0; prev=""
for a in "$@"; do
    case "$a" in
        --sign) is_sign=1 ;;
        --verify) is_verify=1 ;;
        --entitlements) is_dumpent=1 ;;
        -dvvv) is_display=1 ;;
        --extract-certificates=*) is_extract=1; pfx="${a#--extract-certificates=}" ;;
        --extract-certificates) is_extract=1; pfx="codesign" ;;
        --timestamp) ts=1 ;;
    esac
    [ "$prev" = "--sign" ] && signid="$a"
    [ "$prev" = "--keychain" ] && kc="$a"
    [ "$prev" = "--options" ] && [ "$a" = runtime ] && rt=1
    prev="$a"
done
item="${@: -1}"
# 此項目最後一次簽名記錄 → "name<TAB>runtime<TAB>timestamp<TAB>leaf-content"(無記錄 → 空)。
latest() {
    awk -F'\t' -v it="$1" '$1==it{n=$2; r=$3; t=$4; c=$5; f=1} END{if (f) printf "%s\t%s\t%s\t%s\n", n, r, t, c}' "$D/signed.map" 2>/dev/null
}
if [ "$is_sign" = 1 ]; then
    [ "${FAKE_SIGN_FAIL:-0}" = 1 ] && { echo "codesign: unable to build chain to self-signed root for signer" >&2; exit 1; }
    case "$item" in *AIPetUsage_UsageCore.bundle) : > "$D/rb_signed" ;; esac
    # 記錄此項目「實際以什麼簽」:解析出的身分名稱、是否帶 --options runtime、是否帶 --timestamp、leaf 憑證 bytes。供
    # -dvvv / --extract-certificates「忠實」回報(Authority 依實際所簽身分、runtime flag 依實際 --options runtime)。這把
    # 整類「fake 回報與實際 --sign args 脫鉤」的 oracle 漏洞一次關閉:把簽改成 --sign - / 漏 --options runtime / 漏
    # --keychain(落到 search list)都會被 verify 或身分解析抓到。
    if [ "$signid" = "-" ]; then
        printf '%s\t-\t%s\t%s\t\n' "$item" "$rt" "$ts" >> "$D/signed.map"
        exit 0
    fi
    # 模擬的 user search list(與 fake security 同一套規則):search.list 檔,否則 FAKE_LOGIN_KEYCHAIN + FAKE_SEARCH_LIST_DEFAULT。
    if [ -f "$D/search.list" ]; then
        slist="$(cat "$D/search.list")"
    else
        slist="$(printf '%s\n%s\n' "${FAKE_LOGIN_KEYCHAIN:-}" "${FAKE_SEARCH_LIST_DEFAULT:-}" | tr ':' '\n' | awk 'NF')"
    fi
    if [ -n "$kc" ]; then
        if [ ! -f "$kc" ] || [ "$(head -1 "$kc" 2>/dev/null)" != "FAKE-KEYCHAIN v1" ]; then
            echo "$item: The specified keychain could not be found: $kc" >&2; exit 1
        fi
        kcs="$kc"
    else
        kcs="$slist"
    fi
    # 候選身分(有 key 行、且有效 / 可用於 code signing 的 cert 行)→ "keychain<TAB>SHA1<TAB>name<TAB>content"
    cands="$(printf '%s\n' "$kcs" | while IFS= read -r k; do
        [ -n "$k" ] && [ -f "$k" ] || continue
        awk -F'\t' -v k="$k" '$1=="key" && ($3=="" || $3=="ok"){key[$2]=1} $1=="cert"{m++; s[m]=$2; n[m]=$4; c[m]=$5} END{for (i=1; i<=m; i++) if (key[s[i]]) printf "%s\t%s\t%s\t%s\n", k, s[i], n[i], c[i]}' "$k"
    done)"
    hex40=0
    case "$signid" in '' | *[!0-9A-Fa-f]*) ;; *) [ "${#signid}" -eq 40 ] && hex40=1 ;; esac
    if [ "$hex40" = 1 ]; then
        want="$(printf '%s' "$signid" | tr 'abcdef' 'ABCDEF')"
        hits="$(printf '%s\n' "$cands" | awk -F'\t' -v w="$want" 'NF && $2==w')"
    else
        hits="$(printf '%s\n' "$cands" | awk -F'\t' -v w="$signid" 'NF && $3==w')"
        [ -n "$hits" ] || hits="$(printf '%s\n' "$cands" | awk -F'\t' -v w="$signid" 'NF && index($3, w)')"
    fi
    # 同一張憑證出現在多個 keychain 視為無害(man codesign);以 SHA-1 去重後計數。
    hits="$(printf '%s\n' "$hits" | awk -F'\t' 'NF && !seen[$2]++')"
    nh="$(printf '%s\n' "$hits" | awk 'NF' | wc -l | tr -d ' ')"
    [ "$nh" -eq 0 ] && { echo "$signid: no identity found" >&2; exit 1; }
    [ "$nh" -gt 1 ] && { echo "$signid: ambiguous (matches $nh identities)" >&2; exit 1; }
    IFS="$TAB" read -r hk hs1 hname hcontent <<< "$hits"
    # man codesign(SIGNING IDENTITIES):簽名身分必須存放在 user keychain search list 上的 keychain(--keychain 只把「找身分」
    # 限定在該檔)。
    if ! printf '%s\n' "$slist" | grep -qxF -- "$hk"; then
        echo "$item: the signing identity's keychain is not on the user's keychain search list: $hk" >&2; exit 1
    fi
    # man security(set-key-partition-list):要讓 /usr/bin/codesign 使用該 key,partition list 必須含 "apple:"。
    if ! grep -qx unlocked "$hk" || ! awk -F'\t' '$1=="partition"{n=split($2, a, ","); for (i=1; i<=n; i++) if (a[i]=="apple:") f=1} END{exit f ? 0 : 1}' "$hk"; then
        echo "$item: errSecInternalComponent" >&2; exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$item" "$hname" "$rt" "$ts" "$hcontent" "$hk" >> "$D/signed.map"
    exit 0
fi
if [ "$is_verify" = 1 ]; then
    [ "${FAKE_VERIFY_FAIL:-0}" = 1 ] && { echo "$item: code failed to satisfy specified code requirement(s)" >&2; exit 1; }
    if [ "${FAKE_RB_NEEDS_SIGNING:-0}" = 1 ] && [ ! -e "$D/rb_signed" ]; then
        echo "$item: In subcomponent: $item/Contents/Resources/AIPetUsage_UsageCore.bundle: code object is not signed at all" >&2
        exit 1
    fi
    exit 0
fi
if [ "$is_extract" = 1 ]; then
    # K1:忠實模擬 man codesign --extract-certificates —— 檔名 = 前綴 + 0..n-1,0 = leaf(實際所簽憑證的 bytes),寫到前綴
    # 指定處(預設前綴 "codesign" = 目前目錄)。ad-hoc 簽章沒有憑證鏈 → 不寫任何檔;未簽 → 失敗。
    rec="$(latest "$item")"
    [ -n "$rec" ] || { echo "$item: code object is not signed at all" >&2; exit 1; }
    IFS="$TAB" read -r rname rrt rts rcontent <<< "$rec"
    printf 'Executable=%s\n' "$item" >&2
    [ "$rname" = "-" ] && exit 0
    case "$item" in
        */Contents/MacOS/aipet) leaf="${FAKE_AIPET_LEAF_CONTENT:-$rcontent}" ;;
        *) leaf="${FAKE_LEAF_CONTENT:-$rcontent}" ;;
    esac
    printf '%s' "$leaf" > "${pfx}0" || exit 1
    printf '%s' 'FAKE-CERT-NOT-REAL|Developer ID Certification Authority' > "${pfx}1" || exit 1
    printf '%s' 'FAKE-CERT-NOT-REAL|Apple Root CA' > "${pfx}2" || exit 1
    exit 0
fi
if [ "$is_dumpent" = 1 ]; then
    # per-item entitlements:FAKE_AIPET_ENTITLEMENTS 覆寫巢狀 aipet(讓「把 aipet 從 entitlements 檢查迴圈移除」會被抓到)。
    # F2:用 ${VAR-...}(無冒號)區分「未設定=繼承外層」與「設為空字串=明確乾淨」,使差動 fixture 能獨立設定兩目標
    #     (如外層髒、aipet 乾淨),而非共用單一全域值。
    ent="${FAKE_ENTITLEMENTS:-}"
    case "$item" in */Contents/MacOS/aipet) ent="${FAKE_AIPET_ENTITLEMENTS-$ent}" ;; esac
    case "$ent" in
        sandbox) printf '<?xml version="1.0"?>\n<dict><key>com.apple.security.app-sandbox</key><true/></dict>\n' ;;
        cs)      printf '<?xml version="1.0"?>\n<dict><key>com.apple.security.cs.allow-jit</key><true/></dict>\n' ;;
        *)       printf '<?xml version="1.0"?>\n<dict/>\n' ;;
    esac
    exit 0
fi
if [ "$is_display" = 1 ]; then
    # 從 signed.map 取此項目最後一次簽的記錄(實際解析出的身分 / runtime / timestamp)。未簽或簽成 '-' → Signature=adhoc
    # (grok nit:無記錄視同未簽 adhoc,避免未簽項被回報成 Developer ID)。
    IFS="$TAB" read -r rname rrt rts rcontent <<< "$(latest "$item")"
    if [ -z "$rname" ] || [ "$rname" = "-" ]; then
        printf 'Signature=adhoc\n' >&2
        exit 0
    fi
    # Authority 預設 = 「實際所簽身分」(忠實);FAKE_AUTHORITY 覆寫以模擬換成同團隊的另一張憑證。
    auth="${FAKE_AUTHORITY:-$rname}"
    # Team:FAKE 覆寫 > 從所簽身分名稱的 (TEAMID) 擷取 > 預設。
    team="$(printf '%s\n' "$rname" | sed -n 's/.*(\([A-Za-z0-9]\{1,\}\))[[:space:]]*$/\1/p')"
    [ -z "$team" ] && team=TEAM123456
    # runtime flag 預設 = 「實際所簽的 --options runtime」(忠實);FAKE 覆寫以模擬二進位被竄改。
    rflag="${rrt:-0}"
    # F1:安全時間戳旗標預設 = 「實際所簽的 --timestamp」(忠實;--timestamp=none 不會設 ts 故為 0);FAKE 覆寫以
    #     模擬「命令列看似正常但結果簽章無安全時間戳」。
    tsflag="${rts:-0}"
    case "$item" in
        */Contents/MacOS/aipet)
            team="${FAKE_AIPET_TEAM:-$team}"
            rflag="${FAKE_AIPET_RUNTIME:-$rflag}"
            tsflag="${FAKE_AIPET_TIMESTAMP:-$tsflag}"
            ;;
        *)
            team="${FAKE_TEAM_ID:-$team}"
            rflag="${FAKE_RUNTIME_FLAG:-$rflag}"
            tsflag="${FAKE_TIMESTAMP_FLAG:-$tsflag}"
            ;;
    esac
    printf 'Authority=%s\n' "$auth" >&2
    printf 'TeamIdentifier=%s\n' "$team" >&2
    if [ "$rflag" = 1 ]; then
        printf 'CodeDirectory v=20500 flags=0x10000(runtime)\n' >&2
    else
        printf 'CodeDirectory v=20500 flags=0x0(none)\n' >&2
    fi
    # F1:忠實模擬 codesign -dvvv 的時間戳行為——有安全(TSA)時間戳 → 'Timestamp=';無(如 --timestamp=none)→ 只有
    #     'Signed Time='(簽章者本機時鐘,非安全)。verify_signature 錨定 ^Timestamp= 以區分兩者。
    if [ "$tsflag" = 1 ]; then
        printf 'Timestamp=1 Jan 2026 at 00:00:00\n' >&2
    else
        printf 'Signed Time=1 Jan 2026 at 00:00:00\n' >&2
    fi
    exit 0
fi
exit 0
FAKE
chmod +x "$TMP/bin/codesign"

cat > "$TMP/bin/security" <<'FAKE'
#!/bin/bash
# fake security —— K1 stateful oracle(離線;不碰任何真實 keychain)。狀態:
#   fake keychain 檔(純文字;路徑即身分):首行 "FAKE-KEYCHAIN v1";"pwsha<TAB><密碼 SHA-256>";狀態行 unlocked /
#     settings<TAB>… / partition<TAB>… / acl<TAB>…;憑證 "cert<TAB>SHA1<TAB>SHA256<TAB>NAME<TAB>CONTENT<TAB>LABEL"(雜湊 =
#     CONTENT bytes 的 SHA-1 / SHA-256,大寫;LABEL = find-certificate 的 "labl" 屬性,可與身分名稱 NAME 不同 —— K1 F6)、
#     私鑰 "key<TAB>SHA1<TAB>FLAG"(該憑證有對應私鑰 → 才是身分;FLAG = ok | expired
#     (find-identity -v 不列,不帶 -v 時以 "(CSSMERR_TP_CERT_EXPIRED)" 後綴列出)| nocodesign(-p codesigning 不列))。
#   $FAKE_DIR/search.list:模擬的 user keychain search list(尚未建立時 = FAKE_LOGIN_KEYCHAIN 再加 FAKE_SEARCH_LIST_DEFAULT
#     以冒號分隔的各項)。create-keychain 加入新 keychain、delete-keychain 移除該筆 —— Apple 工具副作用的離線建模
#     (真實行為屬 LIVE-REHEARSAL)。
#   $FAKE_DIR/default.keychain:模擬的 default keychain(尚未建立時 = FAKE_LOGIN_KEYCHAIN)。
#   $FAKE_DIR/security.log:每次呼叫的 argv(create/unlock 的 -p、import 的 -P、set-key-partition-list 的 -k 遮蔽為 <redacted>)。
#   $FAKE_DIR/violations.log:任何 search-list / default / login keychain 子命令(讀或寫 —— K1 沒有任何合法理由呼叫它們)、
#     省略 keychain 參數而落到 default keychain 的子命令、import -A、相對路徑的 create-keychain、不支援的子命令。
#   $FAKE_DIR/import.seen:import 讀到的 P12 路徑與權限(斷言「解碼 P12 在 context 內且為 0600」)。
# 故障注入(依操作,互不連帶):FAKE_SEC_FAIL="<op> …",op ∈ create-keychain set-keychain-settings unlock-keychain import
#   set-key-partition-list find-identity find-certificate delete-keychain(find-* 先印出結果「再」以非零退出,模擬部分失敗);
#   另有 uchg-p12(import 成功後把輸入 P12 設為不可刪 → 模擬 unlink 失敗)、plant-p12-symlink(unlock 成功後在 keychain
#   同目錄放一個 p12.tmp → FAKE_PLANT_TARGET 的 symlink)、keep-keychain-file(delete-keychain 回報成功但不刪檔)。FAKE_SEC_NOISE=1:每個子命令都額外往 stdout 印雜訊(真實
#   import / set-key-partition-list 本來就會印 stdout,fake 一律照印)。
#   K1 F6 / F7 的 find-certificate oracle:FAKE_SEC_OMIT_CERT_SHA1=<SHA1> 讓該 SHA-1 的憑證記錄不出現(身分列仍在);
#   FAKE_SEC_CERT_APPEND=<檔> 在正常記錄之後逐位元組附加該檔(測試用來構造 SHA-1 重複、缺欄位等對抗性記錄)。
D="$FAKE_DIR"
TAB="$(printf '\t')"
sub="${1:-}"
masked=""; prev=""
for a in "$@"; do
    v="$a"
    case "$sub:$prev" in
        create-keychain:-p | unlock-keychain:-p | import:-P | set-key-partition-list:-k) v="<redacted>" ;;
    esac
    masked="${masked:+$masked }$v"
    prev="$a"
done
printf '%s\n' "$masked" >> "$D/security.log"
# K1-N4(sol D2):記錄本行程「環境」中出現的秘密變數名稱(不記錄值)—— adapter 必須在呼叫任何子行程前把它們從 subshell 環境移除;
# 含 adapter 的三個別名名稱(sol attempt-002 C-F1:呼叫端 set -a 會讓 local 別名變成 export)。
secret_names="$(env | grep -oE '^(DEVELOPER_ID_P12_BASE64|DEVELOPER_ID_P12_PASSWORD|SIGNING_KEYCHAIN_PASSWORD|p12b64|p12pw|kcpw)=' | tr -d '=')"
[ -n "$secret_names" ] && printf '%s\n' "$secret_names" >> "$D/env.seen"
# K1-N4b(owner R3):FAKE_ENV_AUDIT=1 時,記錄本行程環境中「每個」變數的名稱與其值的 SHA-256(從不記錄值)—— harness 以秘密值的
# SHA-256 比對,證明秘密「以任何名稱」都沒有進入子行程環境(與 $TMP/auditbin 的 sed / tr / k1ctx 稽核 shim 同一格式)。
if [ "${FAKE_ENV_AUDIT:-0}" = 1 ]; then
    printf 'security\t@invocation\t%s\n' "$sub" >> "$D/env.audit"
    for n in $(compgen -e); do printf 'security\t%s\t%s\n' "$n" "$(printf '%s' "${!n}" | /usr/bin/shasum -a 256 | cut -c1-64)" >> "$D/env.audit"; done
fi
[ "$#" -gt 0 ] && shift
fails() { case " ${FAKE_SEC_FAIL:-} " in *" $1 "*) return 0 ;; esac; return 1; }
noise() { if [ "${FAKE_SEC_NOISE:-0}" = 1 ]; then printf 'security-noise: %s finished (fake stdout chatter)\n' "$sub"; fi; }
violation() { printf '%s\n' "$*" >> "$D/violations.log"; }
pwsha() { printf '%s' "$1" | /usr/bin/shasum -a 256 | cut -d' ' -f1; }
is_kc() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -1 "$1" 2>/dev/null)" = "FAKE-KEYCHAIN v1" ]; }
pw_ok() { [ "$(awk -F'\t' '$1=="pwsha"{print $2; exit}' "$1")" = "$(pwsha "$2")" ]; }
search_list() {
    if [ -f "$D/search.list" ]; then cat "$D/search.list"; return; fi
    if [ -n "${FAKE_LOGIN_KEYCHAIN:-}" ]; then printf '%s\n' "$FAKE_LOGIN_KEYCHAIN"; fi
    if [ -n "${FAKE_SEARCH_LIST_DEFAULT:-}" ]; then printf '%s\n' "$FAKE_SEARCH_LIST_DEFAULT" | tr ':' '\n'; fi
}
set_search_list() { awk 'NF && !seen[$0]++' > "$D/search.list.new" && mv "$D/search.list.new" "$D/search.list"; }
default_kc() { if [ -f "$D/default.keychain" ]; then cat "$D/default.keychain"; else printf '%s\n' "${FAKE_LOGIN_KEYCHAIN:-}"; fi; }
not_found() { echo "security: $1: The specified keychain could not be found." >&2; exit 1; }
# find-* 的 keychain 範圍:顯式參數(每個都須存在)或模擬的 search list。結果放進 KCS 陣列。
scope() {
    KCS=()
    if [ "$#" -gt 0 ]; then
        for k in "$@"; do is_kc "$k" || not_found "SecKeychainOpen $k"; KCS+=("$k"); done
    else
        while IFS= read -r k; do [ -n "$k" ] && KCS+=("$k"); done <<EOF2
$(search_list)
EOF2
    fi
}
case "$sub" in
    create-keychain)
        pw=""; havepw=0; kcs=()
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -p) pw="${2-}"; havepw=1; shift 2 ;;
                -P | -h) shift ;;
                *) kcs+=("$1"); shift ;;
            esac
        done
        [ "${#kcs[@]}" -eq 1 ] || { echo "fake security: create-keychain 需要恰一個 keychain" >&2; exit 2; }
        k="${kcs[0]}"
        case "$k" in
            /*) ;;
            *) violation "create-keychain relative path: $k"; echo "fake security: 拒絕相對路徑(真實工具會建在 ~/Library/Keychains)" >&2; exit 2 ;;
        esac
        [ "$havepw" = 1 ] || { echo "security: create-keychain 會互動式詢問密碼(fake:無 tty)" >&2; exit 1; }
        fails create-keychain && { echo "security: SecKeychainCreate $k: fake injected failure" >&2; exit 1; }
        if [ -e "$k" ] || [ -L "$k" ]; then echo "security: SecKeychainCreate $k: A keychain with the same name already exists." >&2; exit 48; fi
        ( umask 077; printf 'FAKE-KEYCHAIN v1\npwsha\t%s\n' "$(pwsha "$pw")" > "$k" ) || exit 1
        { search_list; printf '%s\n' "$k"; } | set_search_list
        noise; exit 0 ;;
    set-keychain-settings)
        opts=""; kcs=()
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -l | -u) opts="${opts:+$opts }$1"; shift ;;
                -t) opts="${opts:+$opts }-t ${2-}"; shift 2 ;;
                -h) shift ;;
                *) kcs+=("$1"); shift ;;
            esac
        done
        if [ "${#kcs[@]}" -eq 0 ]; then violation "default-targeted set-keychain-settings"; k="$(default_kc)"; else k="${kcs[0]}"; fi
        fails set-keychain-settings && { echo "security: SecKeychainSetSettings $k: fake injected failure" >&2; exit 1; }
        is_kc "$k" || not_found "SecKeychainSetSettings $k"
        printf 'settings\t%s\n' "$opts" >> "$k"
        noise; exit 0 ;;
    unlock-keychain)
        pw=""; havepw=0; kcs=()
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -p) pw="${2-}"; havepw=1; shift 2 ;;
                -u | -h) shift ;;
                *) kcs+=("$1"); shift ;;
            esac
        done
        if [ "${#kcs[@]}" -eq 0 ]; then violation "default-targeted unlock-keychain"; k="$(default_kc)"; else k="${kcs[0]}"; fi
        [ "$havepw" = 1 ] || { echo "security: unlock-keychain 會互動式詢問密碼(fake:無 tty)" >&2; exit 1; }
        fails unlock-keychain && { echo "security: SecKeychainUnlock $k: fake injected failure" >&2; exit 1; }
        is_kc "$k" || not_found "SecKeychainUnlock $k"
        pw_ok "$k" "$pw" || { echo "security: SecKeychainUnlock $k: The user name or passphrase you entered is not correct." >&2; exit 51; }
        printf 'unlocked\n' >> "$k"
        if fails plant-p12-symlink; then ln -s "${FAKE_PLANT_TARGET:-/nonexistent-fake-plant-target}" "$(dirname "$k")/p12.tmp"; fi
        noise; exit 0 ;;
    import)
        in=""; k=""; havek=0; P=""; haveP=0; apps=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -k) k="${2-}"; havek=1; shift 2 ;;
                -P) P="${2-}"; haveP=1; shift 2 ;;
                -t | -f) shift 2 ;;
                -T) apps="${apps:+$apps }${2-}"; shift 2 ;;
                -a) shift 3 ;;
                -A) violation "import -A (allow any application)"; shift ;;
                -w | -x | -h) shift ;;
                -*) echo "fake security: import 不支援的選項 $1" >&2; exit 2 ;;
                *) if [ -z "$in" ]; then in="$1"; else echo "fake security: import 多餘參數 $1" >&2; exit 2; fi; shift ;;
            esac
        done
        if [ "$havek" = 0 ]; then violation "default-targeted import"; k="$(default_kc)"; fi
        fails import && { echo "security: SecKeychainItemImport: fake injected failure" >&2; exit 1; }
        if [ ! -f "$in" ] || [ -L "$in" ]; then echo "security: import: 無法讀取輸入檔 $in" >&2; exit 1; fi
        printf '%s\t%s\n' "$in" "$(/usr/bin/stat -f %Mp%Lp "$in")" >> "$D/import.seen"
        [ "$(head -1 "$in")" = "FAKE-P12 v1" ] || { echo "security: SecKeychainItemImport: Unknown format in import." >&2; exit 1; }
        [ "$haveP" = 1 ] || { echo "security: import 會以 GUI 詢問 passphrase(fake:無互動)" >&2; exit 1; }
        [ "$P" = "$(awk -F'\t' '$1=="password"{print $2; exit}' "$in")" ] \
            || { echo "security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)" >&2; exit 1; }
        is_kc "$k" || not_found "SecKeychainItemImport $k"
        grep -qx unlocked "$k" || { echo "security: SecKeychainItemImport: User interaction is not allowed." >&2; exit 1; }
        nid=0; ncert=0
        while IFS="$TAB" read -r typ name content keyflag label; do
            [ "$typ" = cert ] || continue
            s1="$(printf '%s' "$content" | /usr/bin/shasum -a 1 | cut -d' ' -f1 | tr 'abcdef' 'ABCDEF')"
            s256="$(printf '%s' "$content" | /usr/bin/shasum -a 256 | cut -d' ' -f1 | tr 'abcdef' 'ABCDEF')"
            # 第 6 欄 = keychain 屬性 "labl"(可與身分顯示名稱不同;fake P12 省略時 = 名稱)—— K1 F6 的標籤 / 身分分離案例。
            printf 'cert\t%s\t%s\t%s\t%s\t%s\n' "$s1" "$s256" "$name" "$content" "${label:-$name}" >> "$k"
            ncert=$((ncert + 1))
            case "$keyflag" in
                key) printf 'key\t%s\tok\n' "$s1" >> "$k"; nid=$((nid + 1)) ;;
                key-expired) printf 'key\t%s\texpired\n' "$s1" >> "$k"; nid=$((nid + 1)) ;;
                key-nocodesign) printf 'key\t%s\tnocodesign\n' "$s1" >> "$k"; nid=$((nid + 1)) ;;
            esac
        done < "$in"
        printf 'acl\t%s\n' "$apps" >> "$k"
        if fails uchg-p12; then chflags uchg "$in"; fi
        if [ "$nid" -gt 0 ]; then printf '%d identity imported.\n' "$nid"; else printf '%d certificates imported.\n' "$ncert"; fi
        noise; exit 0 ;;
    set-key-partition-list)
        S=""; kpw=""; havek=0; kcs=(); which=all-keys
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -S) S="${2-}"; shift 2 ;;
                -k) kpw="${2-}"; havek=1; shift 2 ;;
                -a | -c | -D | -j | -l | -t) shift 2 ;;
                -s) which=sign-keys; shift ;;
                -d | -e | -r | -u | -v | -w | -h) shift ;;
                *) kcs+=("$1"); shift ;;
            esac
        done
        if [ "${#kcs[@]}" -eq 0 ]; then violation "default-targeted set-key-partition-list"; k="$(default_kc)"; else k="${kcs[0]}"; fi
        [ "$havek" = 1 ] || { echo "security: set-key-partition-list 會互動式詢問 keychain 密碼(fake:無 tty)" >&2; exit 1; }
        fails set-key-partition-list && { echo "security: SecItemCopyMatching: fake injected failure" >&2; exit 1; }
        is_kc "$k" || not_found "set-key-partition-list $k"
        pw_ok "$k" "$kpw" || { echo "security: SecKeychainItemSetAccessWithPassword: The user name or passphrase you entered is not correct." >&2; exit 1; }
        printf 'partition\t%s\t%s\n' "$S" "$which" >> "$k"
        printf 'attributes:\n    "labl"<blob>="fake private key"\n    "prtn"<blob>="%s"\n' "$S"   # 真實工具會把 key 屬性印到 stdout
        noise; exit 0 ;;
    find-identity)
        # -v:只列有效身分(expired 不列);不帶 -v:列出全部,無效者帶 "(CSSMERR_TP_CERT_EXPIRED)" 後綴(真實格式)。
        # -p codesigning:不列不可用於 code signing 的身分(nocodesign)。
        kargs=(); valid=0; cs=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -p) [ "${2-}" = codesigning ] && cs=1; shift 2 ;;
                -s) shift 2 ;;
                -v) valid=1; shift ;;
                -h) shift ;;
                *) kargs+=("$1"); shift ;;
            esac
        done
        scope ${kargs[@]+"${kargs[@]}"}
        noise
        n=0
        for k in ${KCS[@]+"${KCS[@]}"}; do
            [ -f "$k" ] || continue
            while IFS="$TAB" read -r s1 name flag; do
                [ -n "$s1" ] || continue
                if [ "$cs" = 1 ] && [ "$flag" = nocodesign ]; then continue; fi
                if [ "$flag" = expired ]; then
                    [ "$valid" = 1 ] && continue
                    n=$((n + 1)); printf '  %d) %s "%s" (CSSMERR_TP_CERT_EXPIRED)\n' "$n" "$s1" "$name"; continue
                fi
                n=$((n + 1))
                printf '  %d) %s "%s"\n' "$n" "$s1" "$name"
            done <<EOF2
$(awk -F'\t' '$1=="key"{key[$2]=($3=="" ? "ok" : $3)} $1=="cert"{m++; c[m]=$2; nm[m]=$4} END{for (i=1; i<=m; i++) if (c[i] in key) printf "%s\t%s\t%s\n", c[i], nm[i], key[c[i]]}' "$k")
EOF2
        done
        if [ "$valid" = 1 ]; then printf '     %d valid identities found\n' "$n"; else printf '     %d identities found\n' "$n"; fi
        fails find-identity && exit 1
        exit 0 ;;
    find-certificate)
        all=0; cname=""; havec=0; Z=0; kargs=()
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -a) all=1; shift ;;
                -c) cname="${2-}"; havec=1; shift 2 ;;
                -e) shift 2 ;;
                -Z) Z=1; shift ;;
                -m | -p | -h) shift ;;
                *) kargs+=("$1"); shift ;;
            esac
        done
        scope ${kargs[@]+"${kargs[@]}"}
        noise
        found=0
        for k in ${KCS[@]+"${KCS[@]}"}; do
            [ -f "$k" ] || continue
            while IFS="$TAB" read -r s1 s256 name label; do
                [ -n "$s1" ] || continue
                if [ "$havec" = 1 ]; then case "$name" in *"$cname"*) ;; *) continue ;; esac; fi
                # K1 F6 oracle:FAKE_SEC_OMIT_CERT_SHA1 讓該 SHA-1 的憑證記錄不出現(身分列仍由 find-identity 列出)。
                if [ -n "${FAKE_SEC_OMIT_CERT_SHA1:-}" ] && [ "$s1" = "$FAKE_SEC_OMIT_CERT_SHA1" ]; then continue; fi
                found=$((found + 1))
                if [ "$Z" = 1 ]; then printf 'SHA-256 hash: %s\nSHA-1 hash: %s\n' "$s256" "$s1"; fi
                printf 'keychain: "%s"\nversion: 512\nclass: 0x80001000 \nattributes:\n    "alis"<blob>="%s"\n    "labl"<blob>="%s"\n' "$k" "$name" "${label:-$name}"
                [ "$all" = 1 ] || break 2
            done <<EOF2
$(awk -F'\t' '$1=="cert"{printf "%s\t%s\t%s\t%s\n", $2, $3, $4, $6}' "$k")
EOF2
        done
        # K1 F6 / F7 oracle:FAKE_SEC_CERT_APPEND 在正常記錄之後逐位元組附加一個檔(測試構造 SHA-1 重複、缺欄位等對抗性記錄)。
        if [ -n "${FAKE_SEC_CERT_APPEND:-}" ]; then cat "$FAKE_SEC_CERT_APPEND"; found=$((found + 1)); fi
        if [ "$found" -eq 0 ]; then echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44; fi
        fails find-certificate && exit 1
        exit 0 ;;
    delete-keychain)
        kcs=()
        while [ "$#" -gt 0 ]; do case "$1" in -h) shift ;; *) kcs+=("$1"); shift ;; esac; done
        [ "${#kcs[@]}" -ge 1 ] || { violation "delete-keychain without keychain"; echo "fake security: delete-keychain 需要 keychain" >&2; exit 2; }
        for k in "${kcs[@]}"; do
            fails delete-keychain && { echo "security: SecKeychainDelete $k: fake injected failure" >&2; exit 1; }
            is_kc "$k" || not_found "SecKeychainDelete $k"
            # keep-keychain-file:回報成功但不刪檔(模擬「delete-keychain 成功、檔仍在」→ 測 cleanup 的 residual-entry 分支)。
            if ! fails keep-keychain-file; then rm -f "$k"; fi
            search_list | awk -v k="$k" '$0 != k' | set_search_list
        done
        noise; exit 0 ;;
    list-keychains | default-keychain | login-keychain)
        case " $* " in
            *" -s "* | *" -s") violation "global-write $sub $*" ;;
            *) violation "global-read $sub $*" ;;
        esac
        if [ "$sub" = list-keychains ]; then search_list | sed 's/^/    "/; s/$/"/'; else printf '    "%s"\n' "$(default_kc)"; fi
        exit 0 ;;
    *)
        violation "unsupported $sub"
        echo "fake security: 不支援的子命令:$sub" >&2
        exit 2 ;;
esac
FAKE
chmod +x "$TMP/bin/security"

cat > "$TMP/bin/xcrun" <<'FAKE'
#!/bin/bash
# fake xcrun(dispatch notarytool / stapler)。argv → $FAKE_DIR/xcrun.log。
# FAKE_NOTARY_SUBMIT_FAIL=1 提交/認證失敗;FAKE_NOTARY_STATUS 控制終態;FAKE_NOTARY_ID 提交 id(空=模擬缺 id);
# FAKE_STAPLE_FAIL=1 staple 失敗;FAKE_STAPLER_VALIDATE_FAIL=1 validate 失敗。
D="$FAKE_DIR"
printf '%s\n' "$*" >> "$D/xcrun.log"
case "${1:-} ${2:-}" in
    "notarytool submit")
        [ "${FAKE_NOTARY_SUBMIT_FAIL:-0}" = 1 ] && { echo "notarytool: authentication failed" >&2; exit 1; }
        printf '{"id":"%s","status":"%s"}\n' "${FAKE_NOTARY_ID-sub-123}" "${FAKE_NOTARY_STATUS:-Accepted}"
        ;;
    "notarytool log")
        printf '{"issues":[{"message":"example"}]}\n'
        ;;
    "stapler staple")
        [ "${FAKE_STAPLE_FAIL:-0}" = 1 ] && { echo "stapler: could not staple" >&2; exit 1; }
        printf 'The staple and validate action worked!\n'
        ;;
    "stapler validate")
        [ "${FAKE_STAPLER_VALIDATE_FAIL:-0}" = 1 ] && { echo "stapler: validate failed" >&2; exit 1; }
        printf 'The validate action worked!\n'
        ;;
    *) exit 3 ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/xcrun"

cat > "$TMP/bin/spctl" <<'FAKE'
#!/bin/bash
# fake spctl。FAKE_SPCTL_REJECT=1 直接拒絕;FAKE_SPCTL_DECEPTIVE=1 拒絕(非零)但輸出含 'accepted' 子字串 +
# source=Notarized(測 validate_ticket 以 exit status 為權威,不被子字串矇過);FAKE_SPCTL_WRONG_SOURCE=1 exit 0 但
# source=Developer ID;FAKE_SPCTL_PATHSPOOF=1 exit 0 但 source=Notarized 僅出現在路徑;FAKE_SPCTL_NOTARIZED_PREFIX=1
# (F3)exit 0 但 source=NotarizedFake(以 Notarized 開頭卻非 exact);否則 accepted + source=Notarized Developer ID。
D="$FAKE_DIR"
printf '%s\n' "$*" >> "$D/spctl.log"
item="${@: -1}"
if [ "${FAKE_SPCTL_DECEPTIVE:-0}" = 1 ]; then
    printf '%s: not accepted\n' "$item" >&2
    printf 'source=Notarized Developer ID\n' >&2
    exit 3
fi
if [ "${FAKE_SPCTL_REJECT:-0}" = 1 ]; then
    printf '%s: rejected\n' "$item" >&2
    printf 'source=no usable signature\n' >&2
    exit 3
fi
if [ "${FAKE_SPCTL_WRONG_SOURCE:-0}" = 1 ]; then
    # 退出 0(被接受)但 source 非 Notarized —— 證明 validate_ticket 的 source 檢查真的把關(非僅看 exit code)。
    printf '%s: accepted\n' "$item" >&2
    printf 'source=Developer ID\n' >&2
    exit 0
fi
if [ "${FAKE_SPCTL_PATHSPOOF:-0}" = 1 ]; then
    # 退出 0,「被接受」行含 'source=Notarized' 子字串(模擬 app 路徑含該字串被回顯),真正的 source 行卻是 Developer ID。
    # 未錨定的 grep 會被路徑行矇過;錨定整行(exact)只看真正的 source 行 → 正確地 RED。
    printf '/tmp/source=Notarized/App.app: accepted\n' >&2
    printf 'source=Developer ID\n' >&2
    exit 0
fi
if [ "${FAKE_SPCTL_NOTARIZED_PREFIX:-0}" = 1 ]; then
    # F3:退出 0,source 以 'Notarized' 「開頭」卻非恰為 'Notarized Developer ID'(如 NotarizedFake)。前綴比對
    #     (^source=Notarized)會誤放行;exact 比對(^source=Notarized Developer ID$)須擋下 → 正確地 RED。
    printf '%s: accepted\n' "$item" >&2
    printf 'source=NotarizedFake\n' >&2
    exit 0
fi
printf '%s: accepted\n' "$item" >&2
printf 'source=Notarized Developer ID\n' >&2
exit 0
FAKE
chmod +x "$TMP/bin/spctl"

cat > "$TMP/bin/gh" <<'FAKE'
#!/bin/bash
# fake gh。只記錄 argv → $FAKE_DIR/gh.log(用於斷言「publish gate 擋下時 gh release create 從未被呼叫」)。
D="$FAKE_DIR"
printf '%s\n' "$*" >> "$D/gh.log"
exit 0
FAKE
chmod +x "$TMP/bin/gh"

# M10:確認每個 fake shim 都已建立且可執行。若任何 shim 建立失敗,bare-name 查找會「fall through」到 PATH 上的
# 真實工具 —— 綠色閘門內含真實的 `gh release create`,搭配繼承的 GH_TOKEN 可能變成真的網路/發佈動作,且會觸及真實
# codesign/xcrun/spctl。故在使用任何 shim 前先 fail-fast。
for t in codesign security xcrun spctl gh; do
    [ -x "$TMP/bin/$t" ] || { echo "FATAL: fake shim '$t' 未建立/不可執行 — 拒絕執行(可能觸及真實工具)"; exit 1; }
done

# ---- K1-NATIVE:從這份 checkout 編譯原生工具 k1ctx 與其單元測試 runner(fail-closed:編譯失敗即 FATAL)。adapter 與
#      build-app.sh 的 developer-id 路徑(K5 的 keychain 物件形狀由 k1ctx check-keychain-path 判定)都經 K1CTX_BIN 找到它,
#      所以必須在任何案例之前建好並 export;個別案例可在 env 覆寫(含設為空測 tool-missing)。
K1CTX="$TMP/k1ctx"; K1CTX_TESTS="$TMP/k1ctx-tests"
"$K1N/build.sh" "$K1CTX" > "$TMP/k1ctx-build.log" 2>&1 || { cat "$TMP/k1ctx-build.log"; echo "FATAL: k1ctx 編譯失敗 — 拒絕執行"; exit 1; }
"$K1N/build.sh" --tests "$K1CTX_TESTS" > "$TMP/k1ctx-tests-build.log" 2>&1 || { cat "$TMP/k1ctx-tests-build.log"; echo "FATAL: k1ctx 單元測試編譯失敗"; exit 1; }
[ -x "$K1CTX" ] && [ -x "$K1CTX_TESTS" ] || { echo "FATAL: k1ctx / k1ctx-tests 不可執行"; exit 1; }
export K1CTX_BIN="$K1CTX"

# ---- K1-N4b 環境稽核 shim(owner R3;只在個別案例以 PATH 前綴 $TMP/auditbin + K1CTX_BIN=$TMP/auditbin/k1ctx-audit 啟用):
#      FAKE_ENV_AUDIT=1 時,每個 sed / tr / k1ctx 子行程先把自己環境中「每個」變數的名稱 + 值的 SHA-256(從不記錄值)寫進
#      $FAKE_DIR/env.audit(每次呼叫另記一列 @invocation),再 exec 真正的工具(stdin / argv 原樣透傳)。
mkdir -p "$TMP/auditbin"
for tool in sed tr k1ctx; do
    if [ "$tool" = k1ctx ]; then real="$K1CTX"; shim="$TMP/auditbin/k1ctx-audit"; else real="/usr/bin/$tool"; shim="$TMP/auditbin/$tool"; fi
    cat > "$shim" <<FAKE
#!/bin/bash
if [ "\${FAKE_ENV_AUDIT:-0}" = 1 ] && [ -n "\${FAKE_DIR:-}" ]; then
    printf '$tool\t@invocation\t%s\n' "\${1:-}" >> "\$FAKE_DIR/env.audit"
    for n in \$(compgen -e); do printf '$tool\t%s\t%s\n' "\$n" "\$(printf '%s' "\${!n}" | /usr/bin/shasum -a 256 | cut -c1-64)" >> "\$FAKE_DIR/env.audit"; done
fi
exec '$real' "\$@"
FAKE
    chmod +x "$shim"
done
for t in sed tr k1ctx-audit; do [ -x "$TMP/auditbin/$t" ] || { echo "FATAL: 稽核 shim '$t' 未建立"; exit 1; }; done

# ---------------------------------------------------------------- 共用:fake bundle + 驅動器
APP="$TMP/app/AI Pet Usage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/AIPetUsage_UsageCore.bundle/Contents"
printf '#!/bin/sh\n' > "$APP/Contents/MacOS/AIPetUsage"
printf '#!/bin/sh\n' > "$APP/Contents/MacOS/aipet"
printf '{}' > "$APP/Contents/Resources/AIPetUsage_UsageCore.bundle/Contents/model-prices.json"

# 每案一個隔離 state dir(fake 工具的 log 寫在此)。用 mktemp 確保唯一 —— 不可用 $(...) 內遞增的全域計數器:
# 命令替換在 subshell 執行,計數器遞增會遺失,導致所有案例共用同一 dir、log 跨案累積。
new_state() {
    # 檔案計數器(非 $() 子行程內的變數,否則遞增遺失)+ mkdir(在已 guard 的 $TMP 下可靠)。若 mkdir 竟失敗
    # (如 ENOSPC),以 kill -TERM "$$" 終止「父」harness —— 注意:在 `d="$(new_state)"` 的子行程裡 `exit` 只會
    # 退出子行程、留下 d="" 讓後續寫到根路徑(sol#2);故必須 signal 父行程。
    local n d
    n="$(( $(cat "$TMP/.state_ctr" 2>/dev/null || echo 0) + 1 ))"
    echo "$n" > "$TMP/.state_ctr"
    d="$TMP/s.$n"
    mkdir -p "$d" || { echo "FATAL: mkdir $d 失敗,終止整個 harness(避免 driver/shim 寫到根路徑)" >&2; kill -TERM "$$" 2>/dev/null; exit 1; }
    printf '%s' "$d"
}

# 驅動 build-app.sh 的 validate_signing_env。$1=state ; $2… = VAR=val。rc=子行程退出碼。
# PR-C1A:developer-id 的 EXPECTED_TEAM_ID 預設由本檔稍後的全域 `export EXPECTED_TEAM_ID=TEAM123456` 提供(= DEVID
# 衍生值),使既有 developer-id 案在新 mandatory 契約下續綠;要測 mandatory/mismatch 的案在 "$@" 傳 EXPECTED_TEAM_ID=…
# (env 的 assignment 覆寫繼承的環境值)。K1:DEVELOPER_ID_KEYCHAIN / EXPECTED_DEVELOPER_ID_CERT_SHA256 同樣由稍後的全域
# export 提供預設(= KC_DEV fixture keychain 與 DEV_CERT 的 SHA-256);要測缺值 / 形狀 / 其他 keychain 的案在 "$@" 覆寫。
drive_validate() {
    local d="$1"; shift
    ( cd "$ROOT" && env "$@" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
        bash -c 'source "$1"; validate_signing_env' _ "$BUILD" ) >"$d/out" 2>&1
}
# 驅動 build-app.sh 的 sign_app_bundle(+ developer-id 時 verify_signature)。$1=state $2=bundle ; $3… = VAR=val。
# TMPDIR 指向本案專屬的空目錄,讓 K1 能斷言 verify 的憑證抽取暫存區事後不留任何東西。
drive_sign() {
    local d="$1" bundle="$2"; shift 2
    mkdir -p "$d/tmp"
    ( cd "$ROOT" && env TMPDIR="$d/tmp" "$@" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
        bash -c 'source "$1"; sign_app_bundle "$2"; if [ "${SIGN_MODE:-adhoc}" = developer-id ]; then verify_signature "$2"; fi' \
        _ "$BUILD" "$bundle" ) >"$d/out" 2>&1
}
# 驅動 notarize-app.sh:source 後 eval 一段 snippet。$1=state $2=snippet ; $3… = VAR=val。
# PR-C1A:NOTARY_* 預設置於 "$@" 前(供 require_notary_env 缺值測試以 "$@" 覆寫成空值);建立「非空、明顯非真實 .p8」的
# fake key 檔,讓 preflight 的 key material 檢查(存在、一般檔、非空、可讀)通過。
drive_notarize() {
    local d="$1" snippet="$2"; shift 2
    printf 'FAKE-NOTARY-KEY-NOT-A-REAL-P8\n' > "$d/key.p8"
    ( cd "$ROOT" && env NOTARY_KEY_PATH="$d/key.p8" NOTARY_KEY_ID=KID NOTARY_ISSUER_ID=ISS "$@" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
        bash -c 'source "$1"; eval "$2"' _ "$NOTARIZE" "$snippet" ) >"$d/out" 2>&1
}

DEVID='Developer ID Application: AI Pet Usage Test (TEAM123456)'
# PR-C1A:developer-id 現要求獨立的 EXPECTED_TEAM_ID(mandatory)。全域預設 = DEVID 衍生的 TEAM123456,使既有 developer-id
# 案續綠且順帶行使「實際 TeamIdentifier vs EXPECTED_TEAM_ID」的獨立比對;export 讓所有 `env …` 子程序繼承,個別案可於
# "$@" 以 EXPECTED_TEAM_ID=… 覆寫(含設為空字串測 mandatory)。adhoc 路徑忽略此值。
export EXPECTED_TEAM_ID=TEAM123456

# ---------------------------------------------------------------- K1 fixtures(明顯是假的材料)
# fake「憑證」= 一行可印字串(不是 DER、不是真實憑證);fake security / codesign 只對其 bytes 計算 SHA-1 / SHA-256。
# 所有身分 / Team / 指紋都是測試值(非真實 Developer ID / Team ID / 生產指紋)。秘密 fixture 一律帶 SENT 標記,供最後的
# 秘密衛生掃描(只證明「verbatim 未外洩」)。
SENT='K1SENTINEL'
P12PW="${SENT}-p12-password-not-real"
KCPW="${SENT}-keychain-password-not-real"
NOTEAM='Developer ID Application: No Team Here'
EVID='Developer ID Application: Evil Co (EVILTEAM02)'   # 自我一致但「別團隊」的身分(derived=EVILTEAM02)
SHORTID='Developer ID Application: Short Co (ABC12)'
APPLEDEV='Apple Development: X (TEAM123456)'
OTHERNAME_ID='Developer ID Application: Someone Else (TEAM123456)'
SIBLING_ID="$DEVID Old"                                # 名稱以 DEVID 為子字串的另一身分(真實 keychain 常見)
DEV_CERT="FAKE-CERT-NOT-REAL|$DEVID|serial=1001"
OTHER_CERT="FAKE-CERT-NOT-REAL|$DEVID|serial=2002"     # 同名、同團隊,但不是預期那張(SHA-256 不同)
SIBLING_CERT="FAKE-CERT-NOT-REAL|$SIBLING_ID|serial=3003"
OTHERNAME_CERT="FAKE-CERT-NOT-REAL|$OTHERNAME_ID|serial=4004"
EVIL_CERT="FAKE-CERT-NOT-REAL|$EVID|serial=6666"
NOTEAM_CERT="FAKE-CERT-NOT-REAL|$NOTEAM|serial=7007"
SHORT_CERT="FAKE-CERT-NOT-REAL|$SHORTID|serial=8008"
APPLEDEV_CERT="FAKE-CERT-NOT-REAL|$APPLEDEV|serial=9009"
sha256_of() { printf '%s' "$1" | /usr/bin/shasum -a 256 | cut -d' ' -f1; }
sha1_of() { printf '%s' "$1" | /usr/bin/shasum -a 1 | cut -d' ' -f1 | tr 'abcdef' 'ABCDEF'; }
DEV_SHA256="$(sha256_of "$DEV_CERT")"
DEV_SHA1="$(sha1_of "$DEV_CERT")"
OTHER_SHA256="$(sha256_of "$OTHER_CERT")"
FIX="$TMP/fixtures"; FIXSTATE="$FIX/state"
mkdir -p "$FIXSTATE" || { echo "FATAL: 無法建立 fixture 目錄"; exit 1; }
# fake P12(純文字):header + 密碼 + 每個憑證一行(key = 含私鑰的身分;nokey = 只有憑證)。$1=輸出 $2=密碼,其後每 3 個
# 參數一組:<名稱> <內容> key|nokey。
mk_p12() {
    local out="$1" pw="$2"; shift 2
    { printf 'FAKE-P12 v1\npassword\t%s\n' "$pw"
      while [ "$#" -ge 3 ]; do printf 'cert\t%s\t%s\t%s\n' "$1" "$2" "$3"; shift 3; done
    } > "$out" || { echo "FATAL: mk_p12 $out"; exit 1; }
}
b64_of() { /usr/bin/base64 < "$1" | tr -d '\n'; }
# 計數(檔案不存在 → 0;grep -c 在 0 匹配時退出 1 但仍印 "0")。F = 固定字串、E = ERE。
cntF() { local n; n="$(grep -cF -- "$2" "$1" 2>/dev/null)"; echo "${n:-0}"; }
cntE() { local n; n="$(grep -cE -- "$2" "$1" 2>/dev/null)"; echo "${n:-0}"; }
# 以 fake security 建立 fixture keychain(與 kc_bootstrap 相同的 create / unlock / import / partition 序列;狀態寫在
# FIXSTATE,不污染各案的 search list)。$1=keychain $2=P12(可省略 = 空 keychain)$3=partition list(預設 apple:)。
mk_kc() {
    local k="$1" p="${2:-}" part="${3:-apple:}"
    ( export FAKE_DIR="$FIXSTATE" PATH="$TMP/bin:$PATH"
      security create-keychain -p fixture-keychain-pw "$k" &&
      security unlock-keychain -p fixture-keychain-pw "$k" &&
      { [ -z "$p" ] || security import "$p" -k "$k" -f pkcs12 -P "$P12PW" -T /usr/bin/codesign; } &&
      security set-key-partition-list -S "$part" -s -k fixture-keychain-pw "$k" ) >/dev/null 2>&1 \
        || { echo "FATAL: fixture keychain 建立失敗:$k"; exit 1; }
}
P12_GOOD="$FIX/good.p12";            mk_p12 "$P12_GOOD"      "$P12PW" "$DEVID" "$DEV_CERT" key
P12_NOKEY="$FIX/nokey.p12";          mk_p12 "$P12_NOKEY"     "$P12PW" "$DEVID" "$DEV_CERT" nokey
P12_OTHERSHA="$FIX/othersha.p12";    mk_p12 "$P12_OTHERSHA"  "$P12PW" "$DEVID" "$OTHER_CERT" key
P12_OTHERNAME="$FIX/othername.p12";  mk_p12 "$P12_OTHERNAME" "$P12PW" "$OTHERNAME_ID" "$OTHERNAME_CERT" key
P12_EVIL="$FIX/evil.p12";            mk_p12 "$P12_EVIL"      "$P12PW" "$EVID" "$EVIL_CERT" key
P12_DUP="$FIX/dup.p12";              mk_p12 "$P12_DUP"       "$P12PW" "$DEVID" "$DEV_CERT" key "$DEVID" "$OTHER_CERT" key
P12_SIBLING="$FIX/sibling.p12";      mk_p12 "$P12_SIBLING"   "$P12PW" "$DEVID" "$DEV_CERT" key "$SIBLING_ID" "$SIBLING_CERT" key
P12_NOTEAM="$FIX/noteam.p12";        mk_p12 "$P12_NOTEAM"    "$P12PW" "$NOTEAM" "$NOTEAM_CERT" key
P12_SHORT="$FIX/short.p12";          mk_p12 "$P12_SHORT"     "$P12PW" "$SHORTID" "$SHORT_CERT" key
P12_APPLEDEV="$FIX/appledev.p12";    mk_p12 "$P12_APPLEDEV"  "$P12PW" "$APPLEDEV" "$APPLEDEV_CERT" key
P12_EXPIRED="$FIX/expired.p12";      mk_p12 "$P12_EXPIRED"   "$P12PW" "$DEVID" "$DEV_CERT" key-expired      # 預期那張,但已失效
P12_NOCS="$FIX/nocs.p12";            mk_p12 "$P12_NOCS"      "$P12PW" "$DEVID" "$DEV_CERT" key-nocodesign   # 預期那張,但不可 code signing
P12_DUPCERT="$FIX/dupcert.p12";      mk_p12 "$P12_DUPCERT"   "$P12PW" "$DEVID" "$OTHER_CERT" key "$DEVID" "$DEV_CERT" nokey  # 同名兩張憑證、一個身分
KC_DEV="$FIX/dev.keychain-db";                 mk_kc "$KC_DEV" "$P12_GOOD"
KC_EMPTY="$FIX/empty.keychain-db";             mk_kc "$KC_EMPTY"
KC_NOKEY="$FIX/nokey.keychain-db";             mk_kc "$KC_NOKEY" "$P12_NOKEY"
KC_OTHERSHA="$FIX/othersha.keychain-db";       mk_kc "$KC_OTHERSHA" "$P12_OTHERSHA"
KC_DUP="$FIX/dup.keychain-db";                 mk_kc "$KC_DUP" "$P12_DUP"
KC_SIBLING="$FIX/sibling.keychain-db";         mk_kc "$KC_SIBLING" "$P12_SIBLING"
KC_EVIL="$FIX/evil.keychain-db";               mk_kc "$KC_EVIL" "$P12_EVIL"
KC_NOTEAM="$FIX/noteam.keychain-db";           mk_kc "$KC_NOTEAM" "$P12_NOTEAM"
KC_SHORT="$FIX/short.keychain-db";             mk_kc "$KC_SHORT" "$P12_SHORT"
KC_APPLEDEV="$FIX/appledev.keychain-db";       mk_kc "$KC_APPLEDEV" "$P12_APPLEDEV"
KC_LOGIN_MATCH="$FIX/login-match.keychain-db"; mk_kc "$KC_LOGIN_MATCH" "$P12_GOOD"      # 誘餌:login 有「完全相符」身分
KC_LOGIN_DECOY="$FIX/login-decoy.keychain-db"; mk_kc "$KC_LOGIN_DECOY" "$P12_OTHERSHA"  # 誘餌:login 有同名、不同憑證的身分
KC_EXPIRED="$FIX/expired.keychain-db";         mk_kc "$KC_EXPIRED" "$P12_EXPIRED"
KC_NOCS="$FIX/nocs.keychain-db";               mk_kc "$KC_NOCS" "$P12_NOCS"
KC_DUPCERT="$FIX/dupcert.keychain-db";         mk_kc "$KC_DUPCERT" "$P12_DUPCERT"
KC_WRONGPART="$FIX/wrongpart.keychain-db";     mk_kc "$KC_WRONGPART" "$P12_GOOD" "apple-tool:"   # partition list 缺 apple:
# K1 F6(owner):標籤("labl")與身分顯示名稱分離的 fixture —— 每 4 個參數一組:<名稱> <內容> key|nokey <標籤>。
mk_p12l() {
    local out="$1" pw="$2"; shift 2
    { printf 'FAKE-P12 v1\npassword\t%s\n' "$pw"
      while [ "$#" -ge 4 ]; do printf 'cert\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; shift 4; done
    } > "$out" || { echo "FATAL: mk_p12l $out"; exit 1; }
}
# F-G1 攻擊狀態(先列無私鑰那張):DEV_CERT 無私鑰、掛著身分標籤、SHA-256 == 預期;OTHER_CERT 有私鑰、標籤已改名。
P12_SPLIT_ATTACK="$FIX/split-attack.p12";   mk_p12l "$P12_SPLIT_ATTACK"   "$P12PW" "$DEVID" "$DEV_CERT" nokey "$DEVID" "$DEVID" "$OTHER_CERT" key "renamed-old"
# 反向(標籤無關):有私鑰的 DEV_CERT 標籤改名;無私鑰的 OTHER_CERT 掛著身分標籤 → 仍須通過(selector = DEV_CERT)。
P12_SPLIT_GOOD="$FIX/split-good.p12";       mk_p12l "$P12_SPLIT_GOOD"     "$P12PW" "$DEVID" "$OTHER_CERT" nokey "$DEVID" "$DEVID" "$DEV_CERT" key "renamed-old"
# 同標籤兩張、有私鑰的是預期那張 → 通過(標籤重複不是失敗理由)。
P12_DUPLABEL_GOOD="$FIX/duplabel-good.p12"; mk_p12l "$P12_DUPLABEL_GOOD" "$P12PW" "$DEVID" "$DEV_CERT" key "$DEVID" "$DEVID" "$OTHER_CERT" nokey "$DEVID"
KC_SPLIT_ATTACK="$FIX/split-attack.keychain-db";   mk_kc "$KC_SPLIT_ATTACK" "$P12_SPLIT_ATTACK"
KC_SPLIT_GOOD="$FIX/split-good.keychain-db";       mk_kc "$KC_SPLIT_GOOD" "$P12_SPLIT_GOOD"
KC_DUPLABEL_GOOD="$FIX/duplabel-good.keychain-db"; mk_kc "$KC_DUPLABEL_GOOD" "$P12_DUPLABEL_GOOD"
OTHER_SHA1="$(sha1_of "$OTHER_CERT")"
DEV_SHA256_UPPER="$(printf '%s' "$DEV_SHA256" | tr 'abcdef' 'ABCDEF')"
OTHER_SHA256_UPPER="$(printf '%s' "$OTHER_SHA256" | tr 'abcdef' 'ABCDEF')"
# K1 預設:既有 developer-id 案改用顯式 fixture keychain(含 DEVID 身分)+ 其獨立 leaf SHA-256(export 讓所有 `env …`
# 子程序繼承;個別案在 "$@" 覆寫)。adhoc 路徑忽略兩者。man codesign 要求簽名身分所在的 keychain 也在 user search list 上,
# 故模擬 search list 的預設內容含 KC_DEV(FAKE_SEARCH_LIST_DEFAULT;個別案可覆寫成空或其他)。
export DEVELOPER_ID_KEYCHAIN="$KC_DEV"
export EXPECTED_DEVELOPER_ID_CERT_SHA256="$DEV_SHA256"
export FAKE_SEARCH_LIST_DEFAULT="$KC_DEV"
# 以 fake codesign 直接(帶 --keychain 與 selector)簽 aipet + 外層 —— 繞過 sign_app_bundle 的 pre-sign preflight,用來
# 單獨證明 verify_signature 這一層自己的斷言。該 keychain 放進模擬 search list(man codesign 的前提)。呼叫端須以退出碼
# 斷言前置簽名確實成功(否則之後的 verify RED 可能是「因錯誤原因」)。$1=state $2=keychain $3=selector(憑證 SHA-1)。
sign_direct() {
    ( cd "$ROOT" && env FAKE_DIR="$1" FAKE_SEARCH_LIST_DEFAULT="$2" PATH="$TMP/bin:$PATH" bash -c \
        'codesign --force --options runtime --timestamp --keychain "$1" --sign "$2" "$3/Contents/MacOS/aipet" &&
         codesign --force --options runtime --timestamp --keychain "$1" --sign "$2" "$3"' _ "$2" "$3" "$APP" ) >/dev/null 2>&1
}
# 單獨跑 verify_signature(TMPDIR 指向本案空目錄)。$1=state ; $2… = VAR=val。
drive_verify() {
    local d="$1"; shift
    mkdir -p "$d/tmp"
    ( cd "$ROOT" && env TMPDIR="$d/tmp" "$@" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
        bash -c 'source "$1"; verify_signature "$2"' _ "$BUILD" "$APP" ) >"$d/out" 2>&1
}

# ================================================================ build-app.sh 簽名路徑(case 1–7, 15, 16)

# ---- case 1:缺失 / 不可解析的 Developer ID 身分 → 在 Swift build 前 fail-closed,不產出 bundle ----
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY=""; red "case1 RED: developer-id 無身分 → validate 非零" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_EMPTY"; red "case1 RED: 身分不可解析 → validate 非零" $?
# M1(歷史案):'valid' / 'found' 這類非 'Developer ID Application: …' 的身分如今在「類別閘」就被擋下(早於身分列解析),
# 故這兩案鎖住的是類別閘;摘要行解析由下一案以「確實查到 keychain」的完整名稱另行鎖住。
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="valid" DEVELOPER_ID_KEYCHAIN="$KC_EMPTY"; red "case1 RED(M1/class): 'valid' 非 Developer ID 類別 → 解析前即 fail-closed" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="found" DEVELOPER_ID_KEYCHAIN="$KC_EMPTY"; red "case1 RED(M1/class): 'found' 非 Developer ID 類別 → 解析前即 fail-closed" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_EMPTY"; red "case1 RED(M1/parser): 完整名稱 + 只有摘要行的 keychain → identity-absent" $?
check "case1(M1/parser): 確實查到該 keychain(解析器有被執行)且未把摘要行當身分列" \
    "$(grep -cxF "find-identity -v -p codesigning $KC_EMPTY" "$d/security.log")|$(cntF "$d/out" 'identity-absent')" "1|1"
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID"; green "case1 GREEN: 身分存在且可解析 → validate 0" $?
# V2:security 印出匹配列「後」卻以非零退出(某 keychain 損壞)→ validate 須以退出碼 fail-closed。關鍵:必須在
# 「set -e 被停用」的語境測(main 以 `validate_signing_env || return 1` 呼叫,bash 於此停用函式內 errexit)——
# 直接呼叫時 set -e 會自己擋掉失敗的 command substitution,反而遮蔽了這個漏洞。故以 `if validate; then echo OK` 驗。
d="$(new_state)"
( cd "$ROOT" && env SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SEC_FAIL=find-identity FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
    bash -c 'source "$1"; if validate_signing_env; then echo VALIDATE_OK; fi' _ "$BUILD" ) >"$d/out" 2>&1
check "case1 RED(V2): security 非零退出(set -e 停用語境)→ validate fail-closed,不印 VALIDATE_OK" "$(grep -c VALIDATE_OK "$d/out")" 0
check "case1 RED(V2): fake 確實先印出了相符的身分列(部分失敗,非空輸出)" "$(grep -c '^find-identity' "$d/security.log")" 1
# V3:裸 hash 形式身分 → preflight 拒絕(只接受完整 'Name (TEAMID)',與 verify 的 Team ID 推導保持一致)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="ABCDEF0123456789ABCDEF0123456789ABCDEF01"; red "case1 RED(V3): 裸 hash 身分 → preflight 拒絕(須完整名稱)" $?
# sol#1 類別:非 'Developer ID Application:' 類別(如 Apple Development,雖通過 -p codesigning 但不可公證發行)→ preflight 拒絕
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$APPLEDEV" DEVELOPER_ID_KEYCHAIN="$KC_APPLEDEV"; red "case1 RED(sol#1 class): 非 Developer ID Application 類別 → preflight 拒絕" $?
# sol#1 唯一性:兩個同名(續期)憑證 → 歧義(codesign 可能選錯)→ preflight 拒絕
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_DUP"; red "case1 RED(sol#1 uniq): 同名重複憑證(歧義)→ preflight 拒絕" $?
check "case1 RED(sol#1 uniq): 失敗原因是歧義(identity-ambiguous)" "$(grep -c 'identity-ambiguous' "$d/out")" 1
# grok N2:身分缺可解析的 (TEAMID) → preflight(非等 verify)就拒絕,省一次無謂建置
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$NOTEAM" DEVELOPER_ID_KEYCHAIN="$KC_NOTEAM"; red "case1 RED(grok N2): 身分缺 (TEAMID) → preflight 拒絕(非等到 verify)" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=adhoc; green "case1 GREEN: adhoc 不需身分 → validate 0" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=bogus; red "case1 RED: 未知 SIGN_MODE 被拒" $?

# ---- case 2:無效簽名身分(codesign --sign 失敗)→ RED ----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SIGN_FAIL=1; red "case2 RED: codesign --sign 失敗 → 非零" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID"; green "case2 GREEN: 簽名成功 → 0" $?

# ---- case 3:錯誤 Team ID(verify 的 TeamIdentifier 斷言)→ RED ----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_TEAM_ID=WRONG99999; red "case3 RED: TeamIdentifier 不符 → verify 非零" $?
# M2b:僅「巢狀 aipet」team 錯(外層正確)也須被抓到(verify 對每個 executable 項都查)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_AIPET_TEAM=WRONG99999; red "case3 RED(M2b): 僅 aipet team 錯 → verify 非零" $?
# M2a:身分無 (TEAMID) 可推導 → verify fail-closed(不靜默跳過 team 斷言)。K1 起 sign_app_bundle 的 pre-sign preflight
# 會先擋;為了仍單獨證明 verify 這一層,另以 sign_direct(繞過 preflight)簽好後只跑 verify_signature。
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$NOTEAM" DEVELOPER_ID_KEYCHAIN="$KC_NOTEAM"; red "case3 RED(M2a): 身分無 (TEAMID) → fail-closed(K1:pre-sign preflight 即擋)" $?
check "case3 RED(M2a): pre-sign preflight 擋下 → 沒有任何 Developer-ID codesign --sign" "$(cntF "$d/codesign.log" '--sign')" 0
d="$(new_state)"; sign_direct "$d" "$KC_NOTEAM" "$(sha1_of "$NOTEAM_CERT")"; green "case3(M2a) 前置:sign_direct 以 KC_NOTEAM 的身分簽名成功" $?
drive_verify "$d" DEVELOPER_ID_IDENTITY="$NOTEAM" EXPECTED_DEVELOPER_ID_CERT_SHA256="$(sha256_of "$NOTEAM_CERT")"; red "case3 RED(M2a): verify 單獨對無 (TEAMID) 身分的簽章 fail-closed" $?
check "case3 RED(M2a): verify 的失敗原因是無法推導 Team" "$(grep -c '無法從 DEVELOPER_ID_IDENTITY 推導 Team ID' "$d/out")" 1
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_TEAM_ID=TEAM123456; green "case3 GREEN: TeamIdentifier 相符 → 0" $?
# V1:verify 綁定「所請求的身分」—— 同團隊但不同名稱的憑證也須 RED(非只比 'Developer ID Application' 前綴)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_AUTHORITY="Developer ID Application: Someone Else (TEAM123456)"; red "case3 RED(V1): 同團隊不同名稱憑證 → leaf Authority 不符所請求身分 → verify 非零" $?

# ---- case 4:簽名順序(每個 executable-code 項須在外層 .app 之前被簽)----
order_ok() { # <log> : 0 iff 首個 aipet 簽在最後一個外層 .app 簽之前
    local log="$1" aipet_line outer_line
    aipet_line="$(grep -n -- '--sign' "$log" | grep -- '/Contents/MacOS/aipet$' | head -1 | cut -d: -f1)"
    outer_line="$(grep -n -- '--sign' "$log" | grep -E -- '/AI Pet Usage\.app$' | tail -1 | cut -d: -f1)"
    [ -n "$aipet_line" ] && [ -n "$outer_line" ] && [ "$aipet_line" -lt "$outer_line" ]
}
# 先證 gate 會 RED:合成「外層先於 aipet」的 log
printf -- '--force --options runtime --timestamp --sign X /x/AI Pet Usage.app\n--force --options runtime --timestamp --sign X /x/Contents/MacOS/aipet\n' > "$TMP/badorder.log"
order_ok "$TMP/badorder.log"; red "case4 RED: 順序 gate 抓到「外層先於巢狀」" $?
# 真實 developer-id 簽名的 log → aipet 在外層之前(GREEN),且預設(不需 A2)外層只簽一次
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID"
order_ok "$d/codesign.log"; green "case4 GREEN: 真實簽名順序 aipet 先於外層" $?
check "case4/A2 預設不簽資源 bundle(由 verify 仲裁)" "$(grep -- '--sign' "$d/codesign.log" | grep -c -- '/Contents/Resources/AIPetUsage_UsageCore.bundle$')" 0
check "case4/A2 預設外層只簽一次(與 A2 重簽的兩次相區別)" "$(grep -- '--sign' "$d/codesign.log" | grep -cE -- '/AI Pet Usage\.app$')" 1
# A2:資源 bundle 需要自己的簽名時 —— 簽它(inside-out 最先)、重簽外層(重新密封)、複驗通過
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_RB_NEEDS_SIGNING=1; green "case4/A2 GREEN: 資源 bundle 需簽時仍通過" $?
check "case4/A2 資源 bundle 於需要時被簽一次" "$(grep -- '--sign' "$d/codesign.log" | grep -c -- '/Contents/Resources/AIPetUsage_UsageCore.bundle$')" 1
# M8:資源簽後外層須被「重簽」(兩次外層簽),否則外層密封失效卻矇過
check "case4/A2(M8) 外層於資源 bundle 後被重簽(兩次外層簽)" "$(grep -- '--sign' "$d/codesign.log" | grep -cE -- '/AI Pet Usage\.app$')" 2
# M8:資源 bundle 的簽帶 --options runtime --timestamp(token-boundary;不把 --timestamp=none 誤算成有效)
check "case4/A2(M8) 資源 bundle 簽帶 --options runtime --timestamp" "$(grep -- '/Contents/Resources/AIPetUsage_UsageCore.bundle$' "$d/codesign.log" | grep -Ec -- '--options runtime --timestamp( |$)')" 1
# M8:資源 bundle 簽在「最後一次外層簽」之前(先密封內層,再重簽外層)
rb_line="$(grep -n -- '--sign' "$d/codesign.log" | grep -- '/Contents/Resources/AIPetUsage_UsageCore.bundle$' | head -1 | cut -d: -f1)"
outer_last="$(grep -n -- '--sign' "$d/codesign.log" | grep -E -- '/AI Pet Usage\.app$' | tail -1 | cut -d: -f1)"
check "case4/A2(M8) 資源 bundle 簽在最後外層簽之前" "$([ -n "$rb_line" ] && [ -n "$outer_last" ] && [ "$rb_line" -lt "$outer_last" ] && echo ok)" ok
order_ok "$d/codesign.log"; green "case4/A2 GREEN: 簽資源 bundle 後 aipet 仍先於外層" $?

# ---- case 5:Hardened Runtime 關閉(--options runtime 被拿掉 / 簽章無 runtime flag)→ RED ----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_RUNTIME_FLAG=0; red "case5 RED: 無 runtime flag → verify 非零" $?
# M2b:僅 aipet 缺 runtime 也須被抓(verify 查每個 executable 項)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_AIPET_RUNTIME=0; red "case5 RED(M2b): 僅 aipet 缺 runtime → verify 非零" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_RUNTIME_FLAG=1; green "case5 GREEN: runtime flag 存在 → 0" $?
check "case5 有 >=2 個 developer-id 簽(aipet+外層;避免 0==0 虛綠)" "$([ "$(grep -c -- '--sign' "$d/codesign.log")" -ge 2 ] && echo ok)" ok
check "case5 每個 developer-id 簽都帶 --options runtime" \
    "$(grep -c -- '--sign' "$d/codesign.log")" "$(grep -- '--sign' "$d/codesign.log" | grep -c -- '--options runtime')"

# ---- case 6:secure timestamp(invocation log oracle + F1 runtime 驗證)----
# (a) invocation log oracle:每個 developer-id 簽的命令列都帶 --timestamp,以 token-boundary 匹配(不把 --timestamp=none
#     誤算成有效)。
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID"
ts_signs="$(grep -c -- '--options runtime' "$d/codesign.log")"
ts_with="$(grep -- '--options runtime' "$d/codesign.log" | grep -Ec -- '(^| )--timestamp( |$)')"
# 先證 gate 會 RED:合成一個「有 runtime 簽但無 --timestamp」的 log
printf -- '--force --options runtime --sign X /x/Contents/MacOS/aipet\n' > "$TMP/nots.log"
ts_signs_bad="$(grep -c -- '--options runtime' "$TMP/nots.log")"
ts_with_bad="$(grep -- '--options runtime' "$TMP/nots.log" | grep -Ec -- '(^| )--timestamp( |$)')"
if [ "$ts_signs_bad" != "$ts_with_bad" ]; then ok; else bad "case6 RED: timestamp gate 應抓到缺 --timestamp 的簽"; fi
check "case6 有 >=2 個 developer-id 簽(避免 0==0 虛綠)" "$([ "$ts_signs" -ge 2 ] && echo ok)" ok
check "case6 GREEN: 每個 developer-id 簽都帶 --timestamp" "$ts_signs" "$ts_with"
# F1 token-boundary oracle:'--timestamp=none' 不得被當成有效 secure timestamp。合成「有 runtime 簽但用 --timestamp=none」
# 的 log;token-boundary 匹配須把它算成 0 個 --timestamp(偵測到缺安全時間戳),而舊的未錨定子字串會誤算成 1。
printf -- '--force --options runtime --timestamp=none --sign X /x/Contents/MacOS/aipet\n' > "$TMP/tsnone.log"
check "case6 RED(F1 token-boundary): --timestamp=none → 算 0(非有效 secure timestamp)" "$(grep -Ec -- '(^| )--timestamp( |$)' "$TMP/tsnone.log")" 0
check "case6(F1 對照,非虛綠): 真正的 --timestamp → 算 1" "$(printf -- '--force --options runtime --timestamp --sign X /x/aipet\n' | grep -Ec -- '(^| )--timestamp( |$)')" 1
# (b) F1 runtime 驗證(核心契約):verify_signature 須在 codesign -dvvv 斷言「安全時間戳」確實存在(^Timestamp=),而非
#     只看命令列曾帶旗標。即使簽名「看似」正常,若 -dvvv 顯示無安全時間戳(FAKE_TIMESTAMP_FLAG=0 模擬 --timestamp=none
#     的結果 / 二進位時間戳遺失)→ verify 須 RED。
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_TIMESTAMP_FLAG=0; red "case6 RED(F1 runtime): 外層無安全時間戳(-dvvv 無 Timestamp=)→ verify 非零" $?
# M2b 式:僅巢狀 aipet 無安全時間戳(外層正常)也須被抓到(verify 對每個 executable 項都查 timestamp)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_AIPET_TIMESTAMP=0; red "case6 RED(F1 runtime,M2b): 僅 aipet 無安全時間戳 → verify 非零" $?
# 配對 GREEN:正常簽(-dvvv 有 Timestamp=)→ verify 0(證明本 gate 非恆 RED)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID"; green "case6 GREEN(F1 runtime): -dvvv 有安全時間戳 → verify 0" $?

# ---- case 7:巢狀 CLI 簽章無效(--verify --deep --strict 失敗)→ RED ----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_VERIFY_FAIL=1; red "case7 RED: --verify --deep --strict 失敗 → 非零" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID"; green "case7 GREEN: verify 通過 → 0" $?
# 絕不用 --deep 簽(--deep 只在 verify 出現,不與 --sign 同行)
check "case7 永不用 --deep 簽" "$(grep -- '--sign' "$d/codesign.log" | grep -c -- '--deep')" 0

# ---- case 16:entitlements regression(sandbox 或 cs.* 偷渡進簽章)→ RED(A1;對已簽二進位 dump)----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_ENTITLEMENTS=sandbox; red "case16 RED: app-sandbox 偷渡 → verify 非零" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_ENTITLEMENTS=cs; red "case16 RED: cs.* 例外偷渡 → verify 非零" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_ENTITLEMENTS=; green "case16 GREEN: entitlements dump 乾淨 → 0" $?
# 預設(A1)不帶 --entitlements
check "case16/A1 預設不帶 --entitlements" "$(grep -- '--sign' "$d/codesign.log" | grep -c -- '--entitlements')" 0
# 僅在 ENTITLEMENTS 設定時才帶 --entitlements(僅驗旗標形狀,entitlements dump 仍乾淨)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" ENTITLEMENTS="$d/x.entitlements" FAKE_ENTITLEMENTS=
check "case16/A1 ENTITLEMENTS 設定時才帶 --entitlements" "$([ "$(grep -- '--sign' "$d/codesign.log" | grep -c -- "--entitlements $d/x.entitlements")" -ge 1 ] && echo yes)" yes

# ---- R2 鑑別性 oracle 測試:確保各 verify 斷言「若被移除即 RED」,非虛綠 ----
# F6a:Authority 非 Developer ID → verify RED(證明 Authority 斷言真的把關)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_AUTHORITY="Software Signing"; red "F6a RED: Authority 非 Developer ID → verify 非零" $?
# F6b:僅 aipet 帶 app-sandbox(外層乾淨)→ verify 的 entitlements 迴圈須查 aipet → RED(證明 aipet 有被查)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_AIPET_ENTITLEMENTS=sandbox; red "F6b RED: 僅 aipet 帶 app-sandbox → verify 非零" $?
# F2(outer-App entitlement oracle 差動):僅「外層 App」帶 app-sandbox、aipet 乾淨 → verify 的 entitlements 迴圈須
# 「獨立」查外層 → RED(與 F6b 的「僅 aipet 髒」互補,證明外層 App 被獨立檢查)。兩目標以獨立 FAKE 值設定,非共用
# 單一全域值(FAKE_AIPET_ENTITLEMENTS= 空字串 = aipet 明確乾淨、不繼承外層)。移除 verify 迴圈中的外層 $app 項會使本案虛綠。
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_ENTITLEMENTS=sandbox FAKE_AIPET_ENTITLEMENTS=; red "F2 RED: 僅外層 App 帶 app-sandbox(aipet 乾淨)→ verify 非零" $?
# cs.* 變體(外層髒、aipet 乾淨)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_ENTITLEMENTS=cs FAKE_AIPET_ENTITLEMENTS=; red "F2 RED: 僅外層 App 帶 cs.* 例外(aipet 乾淨)→ verify 非零" $?
# 配對 GREEN:兩者皆乾淨、且「獨立設定」(非共用單一全域值)→ verify 0
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_ENTITLEMENTS= FAKE_AIPET_ENTITLEMENTS=; green "F2 GREEN: 外層與 aipet entitlements 皆乾淨(獨立設定)→ 0" $?
# F6c:STRICT_SIGN=1 的 adhoc 路徑確有 --verify --deep --strict 把關(verify 失敗即 RED)
d="$(new_state)"; drive_sign "$d" "$APP" STRICT_SIGN=1 FAKE_VERIFY_FAIL=1; red "F6c RED: STRICT_SIGN=1 + verify 失敗 → 非零" $?
# F6d:未知 SIGN_MODE 走到 sign_app_bundle(非僅 validate)也 fail-closed
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=bogus; red "F6d RED: sign_app_bundle 未知 mode → 非零" $?
# R2-M4:verify 對「以 ad-hoc 簽」的 bundle 須 RED(fake -dvvv 忠實回報所簽身分 → Authority 非 Developer ID)
d="$(new_state)"
( cd "$ROOT" && env SIGN_MODE=adhoc FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'source "$1"; sign_app_bundle "$2"' _ "$BUILD" "$APP" ) >/dev/null 2>&1
( cd "$ROOT" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" DEVELOPER_ID_IDENTITY="$DEVID" bash -c 'source "$1"; verify_signature "$2"' _ "$BUILD" "$APP" ) >"$d/v.out" 2>&1
red "R2-M4 RED: verify 對 ad-hoc 簽的 bundle → Authority 非 Developer ID → 非零" $?
# V5:忠實 fake 使 verify 抓到「漏 --options runtime 的 Developer ID 簽」(以正確身分簽但無 runtime → -dvvv 無 runtime)
d="$(new_state)"
( cd "$ROOT" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'codesign --force --timestamp --keychain "$3" --sign "$1" "$2/Contents/MacOS/aipet"; codesign --force --timestamp --keychain "$3" --sign "$1" "$2"' _ "$DEVID" "$APP" "$KC_DEV" ) >/dev/null 2>&1
( cd "$ROOT" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" DEVELOPER_ID_IDENTITY="$DEVID" bash -c 'source "$1"; verify_signature "$2"' _ "$BUILD" "$APP" ) >"$d/v.out" 2>&1
red "V5 RED: 漏 --options runtime 的簽 → fake -dvvv 無 runtime → verify 非零" $?
check "V5 RED 的原因是缺 Hardened Runtime(簽名本身成功,非身分解析失敗)" "$(cntF "$d/v.out" '缺 Hardened Runtime')" 1

# ---- adhoc 預設路徑不變(acceptance A):SIGN_MODE unset → ad-hoc(--sign -),STRICT_SIGN 行為保留 ----
d="$(new_state)"; drive_sign "$d" "$APP"; green "acceptanceA GREEN: 預設(unset)adhoc 簽名成功" $?
check "acceptanceA 預設用 ad-hoc(--sign -)" "$(grep -c -- '--force --sign - ' "$d/codesign.log")" 2
check "acceptanceA 預設不用 Developer ID(無 --options runtime)" "$(grep -c -- '--options runtime' "$d/codesign.log")" 0
check "acceptanceA 預設不驗(非 STRICT_SIGN)" "$(grep -c -- '--verify' "$d/codesign.log")" 0
d="$(new_state)"; drive_sign "$d" "$APP" STRICT_SIGN=1; green "acceptanceA GREEN: STRICT_SIGN=1 adhoc 簽+驗成功" $?
check "acceptanceA STRICT_SIGN=1 仍 ad-hoc(--sign -)" "$(grep -c -- '--force --sign - ' "$d/codesign.log")" 2
check "acceptanceA STRICT_SIGN=1 會 --verify --deep --strict" "$(grep -c -- '--verify --deep --strict' "$d/codesign.log")" 1
d="$(new_state)"; drive_sign "$d" "$APP" STRICT_SIGN=1 FAKE_SIGN_FAIL=1; red "acceptanceA RED: STRICT_SIGN=1 簽失敗即 fail" $?
# M9:非 STRICT 時簽失敗仍成功(歷史 best-effort,2>/dev/null || true)—— 移除該行為會改變 bare build,須被此案鎖住
d="$(new_state)"; drive_sign "$d" "$APP" FAKE_SIGN_FAIL=1; green "acceptanceA GREEN(M9): 非 STRICT 簽失敗仍成功(best-effort)" $?

# ---- case 15:本機 dev build 被標成 release ----
( env VERSION=0.1.0 BUILD_CHANNEL=release RELEASE_TAG="" "$RV" --check-build-env ) >/dev/null 2>&1; red "case15 RED: release 無 RELEASE_TAG 被 --check-build-env 拒" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="" ; red "case15 RED: developer-id 無身分(dev 機缺)被拒" $?
( env VERSION=0.1.0 BUILD_CHANNEL=release RELEASE_TAG=v0.1.0-beta.4 "$RV" --check-build-env ) >/dev/null 2>&1; green "case15 GREEN: 正確 release 環境被接受" $?
( env VERSION=0.0.0 BUILD_CHANNEL=source RELEASE_TAG="" "$RV" --check-build-env ) >/dev/null 2>&1; green "case15 GREEN: source build 無 tag 被接受" $?

# ---- case 1/15(M3):實際「執行」build-app.sh 的 main(),鎖住「validate 在 Swift build 之前」的整合順序 ----
# 光測單一函式無法證明 main 把 validate 排在 build 前。這裡建一個暫時 root,放真實 release-version.sh /
# write-info-plist.sh + 一個 fake swiftpm.sh(只記錄「跑過」並產出 stub build 產物),實際執行 main。
MROOT="$TMP/mainroot"; MDIR="$(new_state)"; SWIFTPM_MARKER="$MDIR/swiftpm.ran"
mkdir -p "$MROOT/Scripts"
cp "$BUILD" "$MROOT/Scripts/build-app.sh"
cp "$KCB" "$MROOT/Scripts/keychain-bootstrap.sh"   # K1:developer-id 的身分 preflight 由 build-app.sh 從此載入
cp "$RV" "$MROOT/Scripts/release-version.sh"
cp "$ROOT/Scripts/write-info-plist.sh" "$MROOT/Scripts/write-info-plist.sh"
cat > "$MROOT/Scripts/swiftpm.sh" <<'FSP'
#!/bin/bash
# fake swiftpm:記錄跑過,並建立 stub build 產物讓 build-app.sh 的 cp 成功。FAKE_SWIFTPM_SKIP=<名> 可略過某產物
# (模擬組裝階段 cp 失敗,用來測 developer-id staging 的失敗清理)。
printf 'ran %s\n' "$*" >> "$SWIFTPM_MARKER"
r="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$r/.build/release/AIPetUsage_UsageCore.bundle/Contents"
printf '{}' > "$r/.build/release/AIPetUsage_UsageCore.bundle/Contents/model-prices.json"
[ "${FAKE_SWIFTPM_SKIP:-}" = AIPetUsage ] || printf '#!/bin/sh\n' > "$r/.build/release/AIPetUsage"
[ "${FAKE_SWIFTPM_SKIP:-}" = aipet ] || printf '#!/bin/sh\n' > "$r/.build/release/aipet"
exit 0
FSP
chmod +x "$MROOT/Scripts/swiftpm.sh"
drive_main() { # $1=signmode $2=identity ; 執行暫時 root 的 build-app.sh(走 source-guard → main);會先 wipe dist/.build
    rm -rf "$MROOT/dist" "$MROOT/.build"; rm -f "$SWIFTPM_MARKER"; : > "$MDIR/codesign.log"
    ( env SIGN_MODE="$1" DEVELOPER_ID_IDENTITY="$2" VERSION=0.0.0 BUILD_CHANNEL=source RELEASE_TAG="" \
        FAKE_DIR="$MDIR" SWIFTPM_MARKER="$SWIFTPM_MARKER" PATH="$TMP/bin:$PATH" \
        bash "$MROOT/Scripts/build-app.sh" ) > "$MDIR/main.out" 2>&1
}
# 「不」wipe dist 的變體(保留先前成功產物,用來鎖 V4 的「失敗重建不毀舊產物」與原子換置);$3… = 額外 env
# (前綴於 env;亦可覆寫 PATH 以注入 fake mv)。
drive_main_keep() {
    local sm="$1" id="$2"; shift 2
    rm -rf "$MROOT/.build"; rm -f "$SWIFTPM_MARKER"; : > "$MDIR/codesign.log"
    ( env SIGN_MODE="$sm" DEVELOPER_ID_IDENTITY="$id" VERSION=0.0.0 BUILD_CHANNEL=source RELEASE_TAG="" \
        FAKE_DIR="$MDIR" SWIFTPM_MARKER="$SWIFTPM_MARKER" PATH="$TMP/bin:$PATH" "$@" \
        bash "$MROOT/Scripts/build-app.sh" ) > "$MDIR/main.out" 2>&1
}
# 隔離的 fake mv(只給 V4 mv-injection 測試用;放獨立目錄,前綴於 PATH 才生效,不影響其他測試的真實 mv)。
# 當來源是 staging(.staging-AIPetUsage.app)時模擬失敗 → 觸發 build-app.sh 的「還原舊的、保留 staging」分支。
MVBIN="$TMP/mvbin"; mkdir -p "$MVBIN"
cat > "$MVBIN/mv" <<'FAKEMV'
#!/bin/bash
case "$1" in *.staging-AIPetUsage.app) echo "mv: simulated staging-promote failure" >&2; exit 1 ;; esac
exec /bin/mv "$@"
FAKEMV
chmod +x "$MVBIN/mv"
# M3 RED:developer-id + 無身分 → validate 失敗 → Swift build 從未跑、dist 無 bundle
drive_main developer-id ""; red "case1(M3) RED: developer-id 無身分 → main 非零" $?
check "case1(M3) RED: Swift build 從未被呼叫(validate 在前)" "$([ -e "$SWIFTPM_MARKER" ] && echo ran || echo none)" none
check "case1(M3) RED: 未產出 dist bundle" "$([ -e "$MROOT/dist/AI Pet Usage.app" ] && echo exists || echo none)" none
# M3 GREEN(adhoc):validate(no-op)通過 → build 跑 → 產出 adhoc bundle
drive_main adhoc ""; green "case1(M3) GREEN: adhoc main 成功" $?
check "case1(M3) GREEN: Swift build 有被呼叫" "$([ -e "$SWIFTPM_MARKER" ] && echo ran || echo none)" ran
check "case1(M3) GREEN: 產出 dist bundle" "$([ -e "$MROOT/dist/AI Pet Usage.app" ] && echo exists || echo none)" exists
# M3 GREEN(developer-id):完整 main 走簽+驗(fake)→ 成功 + developer-id 簽名出現在 log
drive_main developer-id "$DEVID"; green "case1(M3) GREEN: developer-id main 完整走簽+驗成功" $?
check "case1(M3) GREEN: developer-id main 有 Developer ID 簽(--options runtime)" "$([ "$(grep -c -- '--options runtime' "$MDIR/codesign.log")" -ge 1 ] && echo yes)" yes
# 靜態:原始碼中 validate_signing_env 的「呼叫」排在 swiftpm build 之前(抓 reorder 迴歸)
vcall="$(grep -nE '^[[:space:]]+validate_signing_env[[:space:]]*\|\|' "$BUILD" | head -1 | cut -d: -f1)"
bld="$(grep -nF 'swiftpm.sh" build' "$BUILD" | head -1 | cut -d: -f1)"
check "case1(M3) 靜態:validate_signing_env 呼叫排在 Swift build 之前" "$([ -n "$vcall" ] && [ -n "$bld" ] && [ "$vcall" -lt "$bld" ] && echo ok)" ok

# ---- M5:developer-id 簽/驗失敗後,dist 不得留下半簽/錯簽的 bundle(兩個失敗分支都要清)----
# 執行暫時 root 的 main(developer-id + 有效身分),注入某失敗旗標(額外 env 由 $@ 傳給 env)。
run_main_fail() {
    rm -rf "$MROOT/dist" "$MROOT/.build"; rm -f "$SWIFTPM_MARKER"; : > "$MDIR/codesign.log"
    ( env SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" VERSION=0.0.0 BUILD_CHANNEL=source RELEASE_TAG="" \
        FAKE_DIR="$MDIR" SWIFTPM_MARKER="$SWIFTPM_MARKER" PATH="$TMP/bin:$PATH" "$@" \
        bash "$MROOT/Scripts/build-app.sh" ) > "$MDIR/main.out" 2>&1
}
drive_main developer-id "$DEVID"   # 先成功產生一個 bundle(前置)
check "M5 前置:developer-id 成功後 dist 有 bundle" "$([ -e "$MROOT/dist/AI Pet Usage.app" ] && echo exists)" exists
# M5a(wipe-based 最終路徑檢查):簽失敗 → main 非零、最終 dist 路徑無 bundle。(sign-fail 的「staging 清理 + 先前
# 產物保留」由 V4b2 以 drive_main_keep 鎖住;此處僅斷言最終路徑,因 run_main_fail 會先 wipe dist。)
run_main_fail FAKE_SIGN_FAIL=1; red "M5a RED: 簽失敗 → main 非零" $?
check "M5a: 簽失敗後 dist 最終路徑不留 bundle" "$([ -e "$MROOT/dist/AI Pet Usage.app" ] && echo exists || echo none)" none
# M5b:驗失敗分支(sign 成功、verify_signature 因 team 不符失敗)→ main 非零 + 清除 bundle
run_main_fail FAKE_TEAM_ID=WRONG99999; red "M5b RED: verify(team 不符)失敗 → main 非零" $?
check "M5b: verify 失敗後 dist 不留 bundle" "$([ -e "$MROOT/dist/AI Pet Usage.app" ] && echo exists || echo none)" none
# M5c:組裝失敗分支(cp 缺產物)→ staging 被清、最終 dist 路徑無半成品
run_main_fail FAKE_SWIFTPM_SKIP=aipet; red "M5c RED: 組裝失敗(缺 aipet)→ main 非零" $?
check "M5c: 組裝失敗後 dist 不留 bundle" "$([ -e "$MROOT/dist/AI Pet Usage.app" ] && echo exists || echo none)" none
check "M5c: staging 亦被清除" "$([ -e "$MROOT/dist/.staging-AIPetUsage.app" ] && echo exists || echo none)" none
# ---- V4 交易式交出(非虛綠:用「不 wipe dist」的 drive_main_keep,真正鎖住先前產物的保留與原子換置)----
# V4a(happy):成功重建「原子換置」前一版;整個 bundle 被換掉(SENTINEL 消失);不留 .staging/.prev
drive_main developer-id "$DEVID"   # 乾淨基線
printf 'BASE1' > "$MROOT/dist/AI Pet Usage.app/PREV_SENTINEL"
drive_main_keep developer-id "$DEVID"; green "V4a GREEN: 成功重建(不 wipe dist)→ 0" $?
check "V4a: 最終 bundle 存在" "$([ -e "$MROOT/dist/AI Pet Usage.app" ] && echo yes)" yes
check "V4a: 前一版被整個換掉(SENTINEL 不在新 bundle)" "$([ -e "$MROOT/dist/AI Pet Usage.app/PREV_SENTINEL" ] && echo stale || echo replaced)" replaced
check "V4a: 無殘留 .staging" "$([ -e "$MROOT/dist/.staging-AIPetUsage.app" ] && echo exists || echo none)" none
check "V4a: 無殘留 .prev" "$([ -e "$MROOT/dist/.prev-AIPetUsage.app" ] && echo exists || echo none)" none
# V4b(失敗重建保留先前產物;MF3/sol#3):verify 失敗的重建「不 wipe dist」→ 先前成功產物須完整保留
drive_main developer-id "$DEVID"; printf 'BASE2' > "$MROOT/dist/AI Pet Usage.app/PREV_SENTINEL"
drive_main_keep developer-id "$DEVID" FAKE_TEAM_ID=WRONG99999; red "V4b RED: verify 失敗的重建 → main 非零" $?
check "V4b: 失敗重建後先前成功產物保留(SENTINEL 在)" "$([ -f "$MROOT/dist/AI Pet Usage.app/PREV_SENTINEL" ] && echo preserved || echo LOST)" preserved
check "V4b: staging 於 verify 失敗後被清" "$([ -e "$MROOT/dist/.staging-AIPetUsage.app" ] && echo exists || echo none)" none
# V4b2(grok N1:鎖住「sign 失敗」分支的 staging 清理 + 先前產物保留;run_main_fail 先 wipe dist 無法鎖此)
drive_main developer-id "$DEVID"; printf 'BASE5' > "$MROOT/dist/AI Pet Usage.app/PREV_SENTINEL"
drive_main_keep developer-id "$DEVID" FAKE_SIGN_FAIL=1; red "V4b2 RED: sign 失敗的重建 → main 非零" $?
check "V4b2: sign 失敗後先前成功產物保留(SENTINEL 在)" "$([ -f "$MROOT/dist/AI Pet Usage.app/PREV_SENTINEL" ] && echo preserved || echo LOST)" preserved
check "V4b2: sign 失敗後 staging 被清(不留半簽 staging)" "$([ -e "$MROOT/dist/.staging-AIPetUsage.app" ] && echo exists || echo none)" none
# V4c(mv-injection;MF2/N1):staging 已驗證但最終 mv(work→APP)失敗 → 先前產物還原 + 已驗證 staging 保留,絕不同失新舊
drive_main developer-id "$DEVID"; printf 'BASE3' > "$MROOT/dist/AI Pet Usage.app/PREV_SENTINEL"
rm -rf "$MROOT/.build"; rm -f "$SWIFTPM_MARKER"; : > "$MDIR/codesign.log"
( env SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" VERSION=0.0.0 BUILD_CHANNEL=source RELEASE_TAG="" \
    FAKE_DIR="$MDIR" SWIFTPM_MARKER="$SWIFTPM_MARKER" FAKE_MV_FAIL_STAGING=1 PATH="$MVBIN:$TMP/bin:$PATH" \
    bash "$MROOT/Scripts/build-app.sh" ) > "$MDIR/main.out" 2>&1
red "V4c RED(mv-inject): 最終 mv 失敗 → main 非零" $?
check "V4c(mv-inject): 先前成功產物被還原(SENTINEL 在)" "$([ -f "$MROOT/dist/AI Pet Usage.app/PREV_SENTINEL" ] && echo restored || echo LOST)" restored
check "V4c(mv-inject): 已驗證 staging 保留供檢查(未同時失去新舊)" "$([ -e "$MROOT/dist/.staging-AIPetUsage.app" ] && echo kept || echo none)" kept

# ================================================================ notarize-app.sh(case 8–11, 14, 17)

# ---- case 8:公證遭拒(status=Invalid/Rejected)→ RED;不 staple、不發佈 ----
d="$(new_state)"; drive_notarize "$d" 'main "'"$APP"'" "'"$d"'/submit.zip"' FAKE_NOTARY_STATUS=Invalid; red "case8 RED: 公證 Invalid → 非零" $?
check "case8 Invalid 後不 staple" "$(grep -c 'stapler staple' "$d/xcrun.log")" 0
d="$(new_state)"; drive_notarize "$d" 'main "'"$APP"'" "'"$d"'/submit.zip"' FAKE_NOTARY_STATUS=Rejected; red "case8 RED: 公證 Rejected → 非零" $?
d="$(new_state)"; drive_notarize "$d" 'main "'"$APP"'" "'"$d"'/submit.zip"' FAKE_NOTARY_STATUS=Accepted; green "case8 GREEN: 公證 Accepted → 完成編排" $?
check "case8 GREEN 後有 staple" "$(grep -c 'stapler staple' "$d/xcrun.log")" 1
# M4:main 於 「if main」語境被呼叫時仍 fail-closed(顯式 return,不靠 set -e)
d="$(new_state)"; drive_notarize "$d" 'if main "'"$APP"'" "'"$d"'/submit.zip"; then echo MAIN_OK; fi' FAKE_NOTARY_STATUS=Invalid
check "case8(M4) 「if main」語境:Invalid 後不得回報成功" "$(grep -c 'MAIN_OK' "$d/out")" 0
check "case8(M4) 「if main」語境:Invalid 後不 staple" "$(grep -c 'stapler staple' "$d/xcrun.log")" 0

# ---- case 9:公證逾時 / 未知(非 Accepted 終態)→ RED,永不假設成功 ----
d="$(new_state)"; drive_notarize "$d" 'main "'"$APP"'" "'"$d"'/submit.zip"' FAKE_NOTARY_STATUS="In Progress"; red "case9 RED: In Progress → 非零" $?
d="$(new_state)"; drive_notarize "$d" 'check_status "{}"'; red "case9 RED: 無法解析的狀態 → 非零" $?
d="$(new_state)"; drive_notarize "$d" 'check_status "{\"id\":\"x\",\"status\":\"Accepted\"}"'; green "case9 GREEN: Accepted JSON(含 id)→ 0" $?
# nit:Accepted 但缺 submission id → fail-closed(A4 紀錄不可無連結)
d="$(new_state)"; drive_notarize "$d" 'check_status "{\"status\":\"Accepted\"}"'; red "case9 RED: Accepted 但缺 id → 非零" $?
# 提交/認證失敗(case 1/2 的 L2 面)
d="$(new_state)"; drive_notarize "$d" 'json="$(notarize_submit_wait "'"$d"'/submit.zip")"; check_status "$json"' FAKE_NOTARY_SUBMIT_FAIL=1; red "case9 RED: notarytool submit 認證失敗 → 非零" $?

# ---- case 10:staple 失敗 → RED;無最終 zip / 無發佈 ----
d="$(new_state)"; drive_notarize "$d" 'main "'"$APP"'" "'"$d"'/submit.zip"' FAKE_NOTARY_STATUS=Accepted FAKE_STAPLE_FAIL=1; red "case10 RED: staple 失敗 → 非零" $?
check "case10 staple 失敗後不 validate" "$(grep -c 'stapler validate' "$d/xcrun.log")" 0
d="$(new_state)"; drive_notarize "$d" 'staple "'"$APP"'"'; green "case10 GREEN: staple 成功 → 0" $?

# ---- case 11:票據驗證失敗(stapler validate / spctl 拒絕)→ RED(發佈前)----
d="$(new_state)"; drive_notarize "$d" 'validate_ticket "'"$APP"'"' FAKE_STAPLER_VALIDATE_FAIL=1; red "case11 RED: stapler validate 失敗 → 非零" $?
d="$(new_state)"; drive_notarize "$d" 'validate_ticket "'"$APP"'"' FAKE_SPCTL_REJECT=1; red "case11 RED: spctl 拒絕 → 非零" $?
# M6:spctl 以「退出狀態」為權威 —— 拒絕(exit 3)但輸出含 'accepted' 子字串 + source=Notarized 仍須 RED
d="$(new_state)"; drive_notarize "$d" 'validate_ticket "'"$APP"'"' FAKE_SPCTL_DECEPTIVE=1; red "case11 RED(M6): spctl 詐騙輸出(exit 3)仍被 exit-status 擋下" $?
# M6b:spctl exit 0 但 source 非 Notarized → RED(證明 source 檢查非虛綠)
d="$(new_state)"; drive_notarize "$d" 'validate_ticket "'"$APP"'"' FAKE_SPCTL_WRONG_SOURCE=1; red "case11 RED(M6b): spctl exit 0 但 source 非 Notarized → RED" $?
# M6c:exit 0 且輸出含 'source=Notarized' 子字串於「被接受」行,但真 source 行是 Developer ID → exact 匹配須擋下
d="$(new_state)"; drive_notarize "$d" 'validate_ticket "'"$APP"'"' FAKE_SPCTL_PATHSPOOF=1; red "case11 RED(M6c): 路徑含 source=Notarized 子字串但真 source 非 Notarized → exact 匹配擋下" $?
# F3:exact source —— spctl exit 0 但 source 以 'Notarized' 開頭卻非恰為 'Notarized Developer ID'(NotarizedFake)→
# 前綴比對(^source=Notarized)會虛綠;exact 比對(^source=Notarized Developer ID$)須 RED。
d="$(new_state)"; drive_notarize "$d" 'validate_ticket "'"$APP"'"' FAKE_SPCTL_NOTARIZED_PREFIX=1; red "case11 RED(F3): source=NotarizedFake(非 exact)→ 須 RED" $?
d="$(new_state)"; drive_notarize "$d" 'validate_ticket "'"$APP"'"'; green "case11 GREEN: validate + spctl accepted(source=Notarized Developer ID,exact)→ 0" $?

# ---- case 14:A3 硬性 publish gate ── 任一不良狀態 → gate 擋下,gh release create 從未被呼叫 ----
gated() { # <state> <mode> <signmode> <notary> <staple> <spctl>:模擬 release workflow 的 gated publish
    local d="$1"; shift
    drive_notarize "$d" 'assert_publish_allowed "'"$1"'" "'"$2"'" "'"$3"'" "'"$4"'" "'"$5"'" && gh release create v0.1.0-beta.4 "'"$APP"'"'
}
d="$(new_state)"; gated "$d" release adhoc Accepted validated accepted; red "case14 RED: SIGN_MODE=adhoc → gate 擋下" $?
check "case14 adhoc 時 gh release create 從未被呼叫" "$([ -e "$d/gh.log" ] && echo exists || echo none)" none
d="$(new_state)"; gated "$d" release developer-id "In Progress" validated accepted; red "case14 RED: 公證未 Accepted → gate 擋下" $?
check "case14 未 Accepted 時 gh 從未被呼叫" "$([ -e "$d/gh.log" ] && echo exists || echo none)" none
d="$(new_state)"; gated "$d" release developer-id Accepted failed accepted; red "case14 RED: staple 未 validated → gate 擋下" $?
d="$(new_state)"; gated "$d" release developer-id Accepted validated rejected; red "case14 RED: spctl 未 accepted → gate 擋下" $?
d="$(new_state)"; gated "$d" dispatch developer-id Accepted validated accepted; red "case14 RED: MODE!=release → gate 擋下" $?
d="$(new_state)"; gated "$d" release developer-id Accepted validated accepted; green "case14 GREEN: 全部條件符合 → 允許發佈" $?
check "case14 GREEN 時 gh release create 確有被呼叫一次" "$(grep -c 'release create' "$d/gh.log")" 1

# ---- case 17:A4 ── 驗證紀錄被 emit;不宣稱跨回合 byte-equality ----
d="$(new_state)"; drive_notarize "$d" 'emit_verification_record v0.1.0-beta.4 abc123commit https://run/9 deadbeefSHA subid-9 Accepted'
green "case17 GREEN: emit_verification_record 成功" $?
rec="$(cat "$d/out")"
check "case17 紀錄連結 tag" "$(printf '%s' "$rec" | grep -c 'tag=v0.1.0-beta.4')" 1
check "case17 紀錄連結 commit" "$(printf '%s' "$rec" | grep -c 'commit=abc123commit')" 1
check "case17 紀錄連結 workflow run" "$(printf '%s' "$rec" | grep -c 'run=https://run/9')" 1
check "case17 紀錄連結最終 ZIP sha256" "$(printf '%s' "$rec" | grep -c 'final_zip_sha256=deadbeefSHA')" 1
check "case17 紀錄連結公證 submission id" "$(printf '%s' "$rec" | grep -c 'notary_submission_id=subid-9')" 1
check "case17 紀錄連結公證狀態(notary_status=Accepted)" "$(printf '%s' "$rec" | grep -c 'notary_status=Accepted')" 1
check "case17 紀錄明確聲明不宣稱跨回合 byte-equality" "$(printf '%s' "$rec" | grep -c 'cross_run_byte_equality=NOT CLAIMED')" 1
# 靜態:簽名腳本內沒有任何 rehearsal-vs-tag 的 sha 相等比較
check "case17 build-app.sh 無跨回合 sha 相等比較" "$(grep -cE '"\$[A-Za-z_]*[Rr]ehears[A-Za-z_]*" *= *"\$' "$BUILD")" 0
check "case17 notarize-app.sh 無跨回合 sha 相等比較" "$(grep -cE '"\$[A-Za-z_]*[Rr]ehears[A-Za-z_]*" *= *"\$' "$NOTARIZE")" 0

# ================================================================ release-app.yml 靜態 wiring 守則(case 12, 13)
# 這些讀取「現有」release-app.yml(PR-B 不修改它);確認 PR-C 尚未發生、且既有的 publish gate / within-run digest 仍在。

# ---- case 13:workflow_dispatch 永不發佈 ----
check "case13 publish 僅在 push + tag + MODE==release" \
    "$(grep -cF "if: github.event_name == 'push' && github.ref_type == 'tag' && env.MODE == 'release'" "$WF")" 1
check "case13 只有一處 gh release create" "$(grep -cF 'gh release create' "$WF")" 1
check "case13 workflow_dispatch 只映射到 rehearsal/dev MODE(永不 release)" \
    "$([ "$(grep -c 'MODE=rehearsal' "$WF")" -ge 1 ] && [ "$(grep -c 'MODE=dev' "$WF")" -ge 1 ] && echo ok)" ok

# ---- case 12:最終 ZIP 的 within-run 完整性(非跨回合相等 → 見 case 17)----
check "case12 發佈後對已發佈資產的 sha256 digest 再驗(within-run)存在" \
    "$(grep -cF '.assets[0].digest == $digest' "$WF")" 1
check "case12 within-run digest 來自本地剛建的 ZIP(shasum -a 256)" \
    "$(grep -cF 'shasum -a 256 "dist/${ASSET_NAME}"' "$WF")" 1

# ---- 範圍確認:PR-B 不修改 release-app.yml;notarize/SIGN_MODE 的接線仍屬 PR-C(尚未出現在工作流)----
check "scope: release-app.yml 尚無 notarytool(PR-C)" "$(grep -ci 'notarytool' "$WF")" 0
check "scope: release-app.yml 尚無 stapler(PR-C)" "$(grep -ci 'stapler' "$WF")" 0
check "scope: release-app.yml 尚無 SIGN_MODE(PR-C)" "$(grep -cF 'SIGN_MODE' "$WF")" 0

# ================================================================ swift-tests.yml required-check 完整性
# 保留 required-check context 名稱 swift-tests;新 harness 有被跑;三支簽名腳本都加進 push paths。
check "swift-tests job 名稱仍為 swift-tests(required-check context 不改名)" \
    "$(grep -c 'name: swift-tests' "$ROOT/.github/workflows/swift-tests.yml")" 2
check "swift-tests 有跑新的 signing-pipeline 套件" \
    "$(grep -cF '/bin/bash Scripts/test-signing-pipeline.sh' "$ROOT/.github/workflows/swift-tests.yml")" 1
# 比對 push paths filter 的「'Scripts/X'」引號列形(run step 是裸引用無引號,故 test-signing-pipeline.sh 不會算到 run step)。
for p in build-app.sh notarize-app.sh test-signing-pipeline.sh keychain-bootstrap.sh; do
    check "swift-tests push paths 含 Scripts/$p" "$(grep -cF "'Scripts/$p'" "$ROOT/.github/workflows/swift-tests.yml")" 1
done
# pull_request 無 paths filter(bare)→ 每個 PR 都跑此 required check(故不需更新 PR paths)。pull_request 的下一列
# 應是 2 空格縮排的 push:(非 4 空格的 paths: 子鍵)。
check "swift-tests 的 pull_request 無 paths filter(每個 PR 都跑)" \
    "$(grep -A1 '^  pull_request:' "$ROOT/.github/workflows/swift-tests.yml" | grep -c '^    ')" 0

# ================================================================ YAML parse(若有 ruby)
if command -v ruby >/dev/null 2>&1; then
    if ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$ROOT/.github/workflows/swift-tests.yml" >/dev/null 2>&1; then ok; else bad "swift-tests.yml YAML 無法解析"; fi
else
    printf 'SKIP: ruby 不可用 — 跳過 YAML parse 檢查\n'
fi

# ================================================================ PR-C1A:獨立信任輸入(EXPECTED_TEAM_ID)+ 公證環境 preflight
# 新增於既有 signing-pipeline 套件(Gate 8:不另建 workflow machinery;隨 required swift-tests 一起跑)。

# ---- Gate 1:EXPECTED_TEAM_ID 獨立信任根(修正 PR-B 的循環信任)----
# (EVID / SHORTID 定義於 K1 fixtures,並各有含該身分的 fixture keychain。)
# TI-1 mandatory:developer-id 缺 EXPECTED_TEAM_ID → validate RED(簽名前)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_TEAM_ID=""; red "TI-1 RED: developer-id 缺 EXPECTED_TEAM_ID → validate 非零(簽名前)" $?
# TI-2 shape:非 10 碼 / 含非英數 → validate RED
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_TEAM_ID=SHORT; red "TI-2 RED: EXPECTED_TEAM_ID 非 10 碼 → validate 非零" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_TEAM_ID='TEAM!23456'; red "TI-2 RED: EXPECTED_TEAM_ID 含非英數 → validate 非零" $?
# 上兩案的 EXPECTED 也 ≠ 衍生值,故即使形狀閘被移除仍會被一致性比對擋下(遮蔽)。此案讓身分衍生 == EXPECTED == 非 10 碼
# (ABC12),只有 10 碼形狀閘能擋。K1 起 kc_identity_preflight 也獨立檢查 Team 形狀(第二層);為了仍鎖住 build-app.sh
# 這一層,另斷言擋下它的是 build-app 自己的形狀閘訊息。
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$SHORTID" DEVELOPER_ID_KEYCHAIN="$KC_SHORT" EXPECTED_TEAM_ID=ABC12; red "TI-2 RED: 自我一致但非 10 碼的 Team(衍生=EXPECTED=ABC12)→ validate 非零(形狀閘獨立把關)" $?
check "TI-2: 擋下的是 build-app.sh 的 10 碼形狀閘" "$(cntF "$d/out" 'build-app: EXPECTED_TEAM_ID 須為 10 碼')" 1
# TI-3 differential:=T1(=身分衍生)→ proceed;=T2(≠衍生)→ 簽名前 fail-closed
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_TEAM_ID=TEAM123456; green "TI-3 GREEN: EXPECTED_TEAM_ID=T1 → validate 0(可進行)" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_TEAM_ID=WRONG99999; red "TI-3 RED: EXPECTED_TEAM_ID=T2 → 簽名前 fail-closed" $?
# TI-4 self-consistency bypass(check #5):別團隊的自我一致身分 + EXPECTED=T1 → RED(validate 與 verify 兩層)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$EVID" DEVELOPER_ID_KEYCHAIN="$KC_EVIL" EXPECTED_TEAM_ID=TEAM123456; red "TI-4a RED: 別團隊自我一致身分 + EXPECTED=T1 → validate 非零" $?
check "TI-4a: 擋下的是 build-app.sh 的衍生 Team 一致性閘" "$(cntF "$d/out" 'build-app: 身分衍生的 Team(EVILTEAM02)≠ EXPECTED_TEAM_ID')" 1
# TI-4b:verify 這一層自己也以 EXPECTED 擋下別團隊身分 —— K1 起 sign_app_bundle 的 pre-sign preflight 會先擋(TI-4b'),
# 故以 sign_direct(繞過 preflight)用 KC_EVIL 的身分簽好,再單獨跑 verify_signature。
d="$(new_state)"; sign_direct "$d" "$KC_EVIL" "$(sha1_of "$EVIL_CERT")"; green "TI-4b 前置:sign_direct 以 KC_EVIL 的身分簽名成功" $?
drive_verify "$d" DEVELOPER_ID_IDENTITY="$EVID" EXPECTED_TEAM_ID=TEAM123456 EXPECTED_DEVELOPER_ID_CERT_SHA256="$(sha256_of "$EVIL_CERT")"; red "TI-4b RED: verify 以 EXPECTED 比對實際簽出 team(EVILTEAM02≠T1)→ 非零" $?
check "TI-4b: verify 的失敗原因是 Team 與 EXPECTED_TEAM_ID 不一致" "$(cntF "$d/out" 'verify: 身分衍生的 Team(EVILTEAM02)≠ EXPECTED_TEAM_ID')" 1
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$EVID" DEVELOPER_ID_KEYCHAIN="$KC_EVIL" EXPECTED_TEAM_ID=TEAM123456; red "TI-4b' RED: K1 pre-sign preflight 在簽名前就擋下別團隊身分" $?
check "TI-4b': 沒有任何 Developer-ID codesign --sign" "$(cntF "$d/codesign.log" '--sign')" 0
# TI-5 final verify ACTUAL vs EXPECTED(check #4):身分衍生=T1、EXPECTED=T1,但實際簽出=第三團隊 → verify RED
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_TEAM_ID=TEAM123456 FAKE_TEAM_ID=WRONG99999; red "TI-5 RED: 實際 TeamIdentifier(WRONG99999)≠ EXPECTED_TEAM_ID(T1)→ verify 非零" $?
# TI-6 GREEN:EXPECTED=身分=實際=T1 → sign+verify 0(證明非恆 RED)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_TEAM_ID=TEAM123456 FAKE_TEAM_ID=TEAM123456; green "TI-6 GREEN: EXPECTED=身分=實際=T1 → verify 0" $?
# TI-7 靜態:verify 的 team 信任根綁定 EXPECTED_TEAM_ID(非舊的衍生 want_team 循環寫法)
check "TI-7 靜態: verify 以 EXPECTED_TEAM_ID 為 team 信任根" "$(grep -cF 'want_team="$EXPECTED_TEAM_ID"' "$BUILD")" 1

# ---- Gate 5:notary 環境 fail-closed preflight(require_notary_env)----
# 行為矩陣(含 F-C):每一種殘缺輸入 —— 三值任一缺失、key 路徑不存在 / 是目錄 / 是空檔 / 不可讀 —— 都須 (1) preflight
# 非零、(2) main 非零、(3) notarytool submit 呼叫數 = 0(在提交前擋下,無任何 Apple 呼叫)。只斷言行為,不綁定實作的
# 運算式寫法。fixture 一律是明顯的假 key 材料(非真實 .p8)。
NEFX="$TMP/ne-fixtures"; mkdir -p "$NEFX/keydir"
: > "$NEFX/empty.p8"
printf 'FAKE-NOTARY-KEY-NOT-A-REAL-P8\n' > "$NEFX/unreadable.p8"; chmod 000 "$NEFX/unreadable.p8"
# 在 $() 內捕捉 grep -c(0 匹配時 exit 1 但值仍為 "0";log 不存在 → 空 → 0),不用會印出雙 "0" 的 `|| echo 0` 寫法。
xcrun_submit_count() { local n; n="$(grep -c 'notarytool submit' "$1/xcrun.log" 2>/dev/null)"; echo "${n:-0}"; }
NE_CASES=("缺 NOTARY_KEY_PATH|NOTARY_KEY_PATH=" "缺 NOTARY_KEY_ID|NOTARY_KEY_ID=" "缺 NOTARY_ISSUER_ID|NOTARY_ISSUER_ID=" \
    "key 路徑不存在|NOTARY_KEY_PATH=$NEFX/missing.p8" "key 路徑是目錄|NOTARY_KEY_PATH=$NEFX/keydir" "key 是空檔|NOTARY_KEY_PATH=$NEFX/empty.p8")
# 不可讀檔:僅在可決定性測試的環境納入(0000 檔對目前使用者確實不可讀;root 例外),否則印 SKIP。
if [ -r "$NEFX/unreadable.p8" ]; then
    printf 'SKIP: 0000 權限檔對目前使用者仍可讀(可能為 root)— 跳過「key 檔不可讀」案\n'
else
    NE_CASES+=("key 檔不可讀|NOTARY_KEY_PATH=$NEFX/unreadable.p8")
fi
for ne_case in "${NE_CASES[@]}"; do
    ne_name="${ne_case%%|*}"; ne_inj="${ne_case#*|}"
    d="$(new_state)"; drive_notarize "$d" 'require_notary_env' "$ne_inj"; red "NE RED: $ne_name → preflight 非零" $?
    d="$(new_state)"; drive_notarize "$d" 'main "'"$APP"'" "'"$d"'/submit.zip"' "$ne_inj"; red "NE RED: $ne_name → main 非零(提交前)" $?
    check "NE: $ne_name 時 notarytool submit 呼叫數 = 0" "$(xcrun_submit_count "$d")" 0
done
# 配對 GREEN:三值齊備 + 非空、可讀的一般 fake key 檔 → preflight 0、main 走完、submit 恰 1 次(證明矩陣非恆 RED)
d="$(new_state)"; drive_notarize "$d" 'require_notary_env'; green "NE GREEN: 三值齊備 + 非空可讀 fake key 檔 → preflight 0" $?
d="$(new_state)"; drive_notarize "$d" 'main "'"$APP"'" "'"$d"'/submit.zip"'; green "NE GREEN: 有效 fake 憑證 → main 0" $?
check "NE GREEN: notarytool submit 恰呼叫 1 次" "$(xcrun_submit_count "$d")" 1

# ---- Gate 7:PR-C1A 範圍守則(release-app.yml 仍未接線 EXPECTED_TEAM_ID / 公證憑證介面 = PR-C2)----
check "scope: release-app.yml 尚無 EXPECTED_TEAM_ID(PR-C2)" "$(grep -cF 'EXPECTED_TEAM_ID' "$WF")" 0
check "scope: release-app.yml 尚無 NOTARY_* 公證憑證介面(PR-C2)" "$(grep -cF 'NOTARY_' "$WF")" 0

# ================================================================ K1-NATIVE:顯式臨時 signing keychain(Scripts/keychain-bootstrap.sh + Scripts/k1-native)
# 以 source 取得 adapter 函式,在 bash -c 子行程內以 stateful fake security 驅動;context 一律由「呼叫端」(本 harness =
# 未來 PR-C2 的角色)以 mktemp -d 建立。所有 context / 檔案系統的安全操作由原生工具 k1ctx 執行(本節先以
# Scripts/k1-native/build.sh 從這份 checkout 編譯它與其單元測試 runner;編譯失敗 = FATAL)。K1-01…K1-25 對應 owner Gate K15
# 的矩陣;每個 RED 斷言 (1) 退出碼、(2) 該檢查專屬的訊息 token、(3) 危險副作用確實「沒有」發生,並配對 GREEN 證明非恆 RED。
# 每次 drive_kc 都是獨立的 bash 行程:bootstrap 與 cleanup 之間唯一的狀態就是 context 的檔案系統(K12:不依賴跨命令替換
# 存活的 shell 全域變數)。K1-N0 = 原生單元測試;K1-N1 = F-N1 回歸(marker 置換 → 原生讀取以開啟到的物件判定、不阻塞);
# K1-N2 = F-N2 回歸(不可走訪的子樹 + sentinel → INCOMPLETE_SCAN 而非 CLEAN);K1-S8 以 k1ctx scan-secrets 掃整個 harness。

# ---- K1-N0 原生單元測試 runner(k1ctx 與 runner 已在 harness 開頭由 Scripts/k1-native/build.sh 建置 —— 編譯失敗即 FATAL;
#      build-app.sh 的 developer-id 路徑(PR-B / PR-C1A 案)也需要 K1CTX_BIN,故建置在所有案例之前)----
mkdir -p "$TMP/k1n-tests"
( cd "$TMP/k1n-tests" && env TMPDIR="$TMP/k1n-tests" "$K1CTX_TESTS" ) > "$TMP/k1n-tests.out" 2>&1; green "K1-N0 原生單元測試 runner exit 0" $?
check "K1-N0 原生單元測試回報 PASS(非空)" "$(grep -cE '^k1-native tests: PASS \([1-9][0-9]* checks\)$' "$TMP/k1n-tests.out")" 1
check "K1-N0 原生單元測試零 FAIL 行" "$(cntE "$TMP/k1n-tests.out" '^FAIL')" 0
grep -E '^(SKIP|k1-native tests:)' "$TMP/k1n-tests.out"
check "K1-N0 單元測試自行移除其測試根目錄" "$(ls -A "$TMP/k1n-tests" | wc -l | tr -d ' ')" 0

P12_GOOD_B64="$(b64_of "$P12_GOOD")"
P12_NOKEY_B64="$(b64_of "$P12_NOKEY")"
P12_OTHERSHA_B64="$(b64_of "$P12_OTHERSHA")"
P12_OTHERNAME_B64="$(b64_of "$P12_OTHERNAME")"
P12_EVIL_B64="$(b64_of "$P12_EVIL")"
P12_APPLEDEV_B64="$(b64_of "$P12_APPLEDEV")"
TABC="$(printf '\t')"
OK_ENTRIES='.aipet-kc-context signing.keychain-db '
MARKER_EXPECTED="$(printf 'aipet-kc-context v1\nuid=%s\n' "$(id -u)")"   # $() 去掉結尾換行;與 $(cat marker) 同形比較
# 驅動 adapter。$1=state $2=函式 $3=context ; $4… = VAR=val(覆寫預設輸入)。cwd = state;stdout / stderr 分開捕捉
# (kc.out / kc.err);TMPDIR 指向本案空目錄(證明 adapter / k1ctx 不在 context 外產生檔案)。
drive_kc() {
    local d="$1" fn="$2" ctx="$3"; shift 3
    mkdir -p "$d/kctmp"
    ( cd "$d" && env TMPDIR="$d/kctmp" DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" \
        SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" "$@" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
        bash -c 'source "$1"; "$2" "$3"' _ "$KCB" "$fn" "$ctx" ) >"$d/kc.out" 2>"$d/kc.err"
}
# 呼叫端建立的私有 context:$state/parent/ctx.XXXXXXXX(mktemp -d → 0700);parent 另放旁觀檔(證明 cleanup 不碰 context 外)。
new_ctx() {
    local d="$1" c
    { mkdir -p "$d/parent" && printf 'BYSTANDER-DO-NOT-TOUCH\n' > "$d/parent/bystander.txt"; } || { kill -TERM "$$"; exit 1; }
    c="$(mktemp -d "$d/parent/ctx.XXXXXXXX")" || { kill -TERM "$$"; exit 1; }
    printf '%s' "$c"
}
ents() { ( cd "$1" 2>/dev/null && ls -A | LC_ALL=C sort | tr '\n' ' ' ); }   # 目錄內容(排序、含 dotfile;harness 自己的檢視)
gone() { if [ -e "$1" ] || [ -L "$1" ]; then echo present; else echo gone; fi; }
fhash() { /usr/bin/shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
seclog_ops() { awk '{print $1}' "$1/security.log" 2>/dev/null | tr '\n' ' '; }
code_lines() { grep -vE '^[[:space:]]*#' "$1"; }   # 非註解行(靜態斷言只看程式碼)
swift_code_lines() { grep -vE '^[[:space:]]*//' "$1"; }
# 偽造一個「形狀正確」的 marker(harness 自己的 fixture 寫法;k1ctx 要求 0600 一般檔、精確位元組)。
valid_marker() { printf 'aipet-kc-context v1\nuid=%s\n' "$(id -u)" > "$1/.aipet-kc-context" && chmod 600 "$1/.aipet-kc-context"; }
# 以獨立 process group 執行一道指令並設期限:stdout 回報 "FINISHED:<rc>" 或 "BLOCKED"(逾時則整個 group 被終止)。用來證明
# 「到達的是哪一步」:FINISHED 的 rc + 受測函式的 stderr 一起判定,不只靠逾時。$1=秒數 $2…=指令。
run_deadline() {
    local secs="$1" pid i=0; shift
    /usr/bin/perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' -- "$@" & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge $((secs * 10)) ]; then
            kill -TERM -- "-$pid" 2>/dev/null; sleep 0.2; kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            echo BLOCKED; return
        fi
        sleep 0.1; i=$((i + 1))
    done
    wait "$pid"; echo "FINISHED:$?"
}
# 以期限執行 kc_cleanup(F-N1 類案例):stdout = FINISHED:<rc> / BLOCKED;stderr → $2。$1=context $2=stderr 檔 $3=state。
cleanup_deadline() {
    run_deadline 20 env TMPDIR="$3/kctmp" FAKE_DIR="$3" PATH="$TMP/bin:$PATH" bash -c 'source "$1"; kc_cleanup "$2" 2>"$3"' _ "$KCB" "$1" "$2"
}

# ---- K1-G:GREEN 全流程 —— bootstrap → build-app validate / sign / verify → cleanup → 第二次 cleanup = 3 ----
d="$(new_state)"; ctx="$(new_ctx "$d")"; K="$ctx/signing.keychain-db"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-G1 GREEN: 有效 context + 有效 fake P12 → kc_bootstrap 0" $?
check "K1-G1 stdout 為空(生命週期 handle 不經 stdout)" "$(wc -c < "$d/kc.out" | tr -d ' ')" 0
check "K1-G1 context 內容 == {marker, keychain}(無 identity.sha1 等其他檔)" "$(ents "$ctx")" "$OK_ENTRIES"
check "K1-G1 marker 逐位元組 == v1 + 目前 uid" "$(cat "$ctx/.aipet-kc-context")" "$MARKER_EXPECTED"
check "K1-G1 k1ctx 建立的 marker 只有 owner 可讀寫(明確 0600,不靠 umask)" "$(/usr/bin/stat -f %Mp%Lp "$ctx/.aipet-kc-context")" 0600
check "K1-G1 生命週期順序(create → settings → unlock → import → partition → 身分 preflight)" "$(seclog_ops "$d")" \
    "create-keychain set-keychain-settings unlock-keychain import set-key-partition-list find-identity find-certificate "
check "K1-G1 每個 security 呼叫都帶這個 context 的精確 keychain 路徑" "$(cntF "$d/security.log" " $K")" 7
check "K1-G1 timeout / 上鎖設定 = -l -u -t 3600" "$(grep -cxF "settings${TABC}-l -u -t 3600" "$K")" 1
check "K1-G1 keychain 已解鎖" "$(grep -cx unlocked "$K")" 1
check "K1-G1 signing-key 存取 = partition 'apple:'、只匹配簽名 key" "$(grep -cxF "partition${TABC}apple:${TABC}sign-keys" "$K")" 1
check "K1-G1 import 只授權 /usr/bin/codesign(無 -A)" "$(grep -cxF "acl${TABC}/usr/bin/codesign" "$K")" 1
check "K1-G1 解碼 P12 位於 context 內、權限 0600" "$(cat "$d/import.seen")" "$ctx/p12.tmp${TABC}0600"
check "K1-G1 解碼 P12 在 bootstrap 返回後已不存在" "$(gone "$ctx/p12.tmp")" gone
check "K1-G1 預期身分(含私鑰、有效)在這個臨時 keychain" "$(grep -cxF "key${TABC}$DEV_SHA1${TABC}ok" "$K")" 1
check "K1-G1 Apple create-keychain 副作用(fake 建模):臨時 keychain 在模擬 search list" "$(grep -cxF "$K" "$d/search.list")" 1
check "K1-G1 無任何 violation(無全域讀寫、無落到 default keychain、無 -A)" "$(gone "$d/violations.log")" gone
check "K1-G1 不在 context 外產生檔案(TMPDIR 仍為空)" "$(ents "$d/kctmp")" ""
check "K1-G1 任何子行程的環境都沒有秘密變數(fake security 的 env.seen 不存在;sol D2)" "$(gone "$d/env.seen")" gone
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$K"; green "K1-G2 GREEN: build-app validate 以 K1 臨時 keychain 通過" $?
: > "$d/codesign.log"
drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$K"; green "K1-G3 GREEN: sign + verify 以 K1 臨時 keychain 成功" $?
check "K1-G3 Developer-ID codesign = 2 次,每次都 --keychain <K1 keychain> --sign <derived SHA-1>" \
    "$(cntF "$d/codesign.log" '--sign')|$(cntF "$d/codesign.log" "--keychain $K --sign $DEV_SHA1 ")" "2|2"
check "K1-G3 verify 以顯式絕對前綴抽取憑證(--extract-certificates=,每個 executable 項一次)" "$(cntF "$d/codesign.log" "-d --extract-certificates=$d/tmp/aipet-leafcert.")" 2
check "K1-G3 憑證抽取暫存區事後完全移除(TMPDIR 為空)" "$(ents "$d/tmp")" ""
check "K1-G3 repo 根目錄沒有 codesign 預設抽取檔(codesign0… / leaf.N)" "$(ls -A "$ROOT" | grep -cE '^(codesign|leaf\.)[0-9]')" 0
drive_kc "$d" kc_cleanup "$ctx"; green "K1-G4 GREEN: kc_cleanup 0" $?
check "K1-G4 cleanup stdout 為空" "$(wc -c < "$d/kc.out" | tr -d ' ')" 0
check "K1-22 成功 cleanup:context 與臨時 keychain 都不存在" "$(gone "$ctx")|$(gone "$K")" "gone|gone"
check "K1-22 Apple delete-keychain 副作用(fake 建模):已不在模擬 search list" "$(grep -cxF "$K" "$d/search.list")" 0
check "K1-21 delete-keychain 恰一次、引數為精確的臨時 keychain" "$(cntE "$d/security.log" '^delete-keychain')|$(grep -cxF "delete-keychain $K" "$d/security.log")" "1|1"
check "K1-21 parent 只剩旁觀檔且原封不動" "$(ents "$d/parent")|$(cat "$d/parent/bystander.txt")" "bystander.txt |BYSTANDER-DO-NOT-TOUCH"
drive_kc "$d" kc_cleanup "$ctx"; check "K1-G5 第二次 cleanup → 3(K1 不把「不存在」當成功)" "$?" 3
check "K1-G5 adapter 只回報 CONTEXT_NOT_FOUND(恰一行;零 security 呼叫增量)" \
    "$(grep -cxF "kc_cleanup: CONTEXT_NOT_FOUND: $ctx" "$d/kc.err")|$(grep -c '^kc_cleanup:' "$d/kc.err")|$(cntE "$d/security.log" '^delete-keychain')" "1|1|1"

# ---- K1-01 無效 context:空路徑 ----
d="$(new_state)"
drive_kc "$d" kc_bootstrap ""; check "K1-01 bootstrap 空路徑 → 2" "$?" 2
check "K1-01 bootstrap 訊息 context-empty" "$(cntF "$d/kc.err" 'kc_bootstrap: REJECTED: context-empty')" 1
drive_kc "$d" kc_cleanup ""; check "K1-01 cleanup 空路徑 → 2(驗證順序:空參數先於存在性,不是 3)" "$?" 2
check "K1-01 cleanup 訊息 context-empty" "$(cntF "$d/kc.err" 'kc_cleanup: CONTEXT_REJECTED: context-empty')" 1
check "K1-01 全程零 security 呼叫" "$(gone "$d/security.log")" gone

# ---- K1-02 無效 context:相對路徑(即使 cwd 下真有該目錄、甚至是有效 K1 context)----
d="$(new_state)"; mkdir -m 700 "$d/relctx"
drive_kc "$d" kc_bootstrap relctx; check "K1-02 bootstrap 相對路徑 → 2" "$?" 2
check "K1-02 bootstrap 訊息 context-relative,且該目錄未被寫入" "$(cntF "$d/kc.err" 'REJECTED: context-relative')|$(ents "$d/relctx")" "1|"
mkdir -m 700 "$d/relgood"; drive_kc "$d" kc_bootstrap "$d/relgood"; green "K1-02 前置:以絕對路徑建立有效 context" $?
drive_kc "$d" kc_cleanup relgood; check "K1-02 cleanup 相對路徑(指向有效 context)→ 2" "$?" 2
check "K1-02 cleanup 訊息 context-relative" "$(cntF "$d/kc.err" 'CONTEXT_REJECTED: context-relative')" 1
check "K1-02 有效 context 原封不動、未呼叫 delete-keychain" "$(ents "$d/relgood")|$(cntE "$d/security.log" '^delete-keychain')" "$OK_ENTRIES|0"
drive_kc "$d" kc_cleanup no-such-relative; check "K1-02 相對且不存在 → 2(驗證順序:非絕對先於不存在)" "$?" 2
drive_kc "$d" kc_cleanup "$d/no-such-absolute"; check "K1-02 絕對且不存在 → 3" "$?" 3
check "K1-02 3 只回報 CONTEXT_NOT_FOUND" "$(grep -cxF "kc_cleanup: CONTEXT_NOT_FOUND: $d/no-such-absolute" "$d/kc.err")|$(grep -c '^kc_cleanup:' "$d/kc.err")" "1|1"
drive_kc "$d" kc_cleanup "$d/relgood"; green "K1-02 收尾:絕對路徑 cleanup 0" $?

# ---- K1-03 任意目錄(無 marker)/ 非空目錄 ----
d="$(new_state)"; mkdir -m 700 "$d/arb"; printf 'user-data\n' > "$d/arb/notes.txt"
drive_kc "$d" kc_cleanup "$d/arb"; check "K1-03 cleanup 無 marker 的任意目錄 → 2" "$?" 2
check "K1-03 訊息 marker-missing;檔案原封不動" "$(cntF "$d/kc.err" 'CONTEXT_REJECTED: marker-missing')|$(cat "$d/arb/notes.txt")" "1|user-data"
mkdir -m 700 "$d/arbempty"; drive_kc "$d" kc_cleanup "$d/arbempty"; check "K1-03 cleanup 無 marker 的空目錄 → 2" "$?" 2
check "K1-03 空目錄仍在(未被 rmdir)" "$(gone "$d/arbempty")" present
drive_kc "$d" kc_bootstrap "$d/arb"; check "K1-03 bootstrap 非空目錄 → 2" "$?" 2
check "K1-03 bootstrap 訊息 context-not-empty;未寫入任何東西" "$(cntF "$d/kc.err" 'REJECTED: context-not-empty')|$(ents "$d/arb")" "1|notes.txt "
mkdir -m 700 "$d/dotonly"; : > "$d/dotonly/.hidden"
drive_kc "$d" kc_bootstrap "$d/dotonly"; check "K1-03 bootstrap 只有 dotfile 的目錄 → 2(列舉含隱藏項)" "$?" 2
mkdir -m 700 "$d/danglingonly"; ln -s "$d/nowhere" "$d/danglingonly/x"
drive_kc "$d" kc_bootstrap "$d/danglingonly"; check "K1-03 bootstrap 只有 dangling symlink 的目錄 → 2" "$?" 2
mkdir -m 700 "$d/weird"; printf 'x' > "$d/weird/$(printf 'a b\nc')"
drive_kc "$d" kc_bootstrap "$d/weird"; check "K1-03 bootstrap 檔名含空白與換行的目錄 → 2(任意檔名被安全列舉)" "$?" 2
check "K1-03 全程零 security 呼叫" "$(gone "$d/security.log")" gone

# ---- K1-04 symlink context(含結尾 '/' 與 '..' 繞道)----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-04 前置:真實 context bootstrap 0" $?
ln -s "$ctx" "$d/ctxlink"
drive_kc "$d" kc_cleanup "$d/ctxlink"; check "K1-04 cleanup symlink → 2" "$?" 2
check "K1-04 訊息 context-symlink" "$(cntF "$d/kc.err" 'CONTEXT_REJECTED: context-symlink')" 1
drive_kc "$d" kc_cleanup "$d/ctxlink/"; check "K1-04 cleanup symlink + 結尾 '/' → 2" "$?" 2
check "K1-04 訊息 context-noncanonical" "$(cntF "$d/kc.err" 'CONTEXT_REJECTED: context-noncanonical')" 1
drive_kc "$d" kc_cleanup "$d/parent/../parent/${ctx##*/}"; check "K1-04 cleanup 含 '..' 成分 → 2" "$?" 2
drive_kc "$d" kc_cleanup "$d/parent//${ctx##*/}"; check "K1-04 cleanup 含 '//' 成分 → 2" "$?" 2
check "K1-04 真實 context 原封不動、未呼叫 delete-keychain" "$(ents "$ctx")|$(cntE "$d/security.log" '^delete-keychain')" "$OK_ENTRIES|0"
mkdir -m 700 "$d/emptytarget"; ln -s "$d/emptytarget" "$d/emptylink"
drive_kc "$d" kc_bootstrap "$d/emptylink"; check "K1-04 bootstrap symlink(指向空的 0700 目錄)→ 2" "$?" 2
check "K1-04 bootstrap 訊息 context-symlink;symlink 目標未被寫入" "$(cntF "$d/kc.err" 'REJECTED: context-symlink')|$(ents "$d/emptytarget")" "1|"
drive_kc "$d" kc_bootstrap "$d/emptytarget/"; check "K1-04 bootstrap 結尾 '/' → 2" "$?" 2
drive_kc "$d" kc_cleanup "$ctx"; green "K1-04 收尾:正規路徑 cleanup 0" $?

# ---- K1-05 權限 / owner(owner ≠ uid 的判定由原生單元測試以不同 uid 決定性驗證:k1ctx 以 fstat 的 st_uid 比對 getuid();
#      非 root 無法在整合層偽造他人擁有的 0700 目錄)----
d="$(new_state)"; mkdir -m 755 "$d/c755"
drive_kc "$d" kc_bootstrap "$d/c755"; check "K1-05 bootstrap mode 0755 → 2" "$?" 2
check "K1-05 bootstrap 訊息 context-mode" "$(cntF "$d/kc.err" 'REJECTED: context-mode')" 1
mkdir -m 700 "$d/c1700"; chmod 1700 "$d/c1700"
drive_kc "$d" kc_bootstrap "$d/c1700"; check "K1-05 bootstrap mode 1700(含特殊位元)→ 2" "$?" 2
check "K1-05 被拒的 bootstrap 全程零 security 呼叫" "$(gone "$d/security.log")" gone
ctx="$(new_ctx "$d")"; drive_kc "$d" kc_bootstrap "$ctx"; green "K1-05 前置:bootstrap 0" $?
chmod 755 "$ctx"; drive_kc "$d" kc_cleanup "$ctx"; check "K1-05 cleanup mode 0755 → 2" "$?" 2
check "K1-05 cleanup 訊息 context-mode" "$(cntF "$d/kc.err" 'CONTEXT_REJECTED: context-mode')" 1
chmod 700 "$ctx"
check "K1-05 context 原封不動、未呼叫 delete-keychain" "$(ents "$ctx")|$(cntE "$d/security.log" '^delete-keychain')" "$OK_ENTRIES|0"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-05 收尾:cleanup 0" $?
check "K1-05 靜態:k1ctx 以 getuid() 作為 owner 判定的 uid(單元測試以不同 uid 證明 context-owner / marker-invalid 分支)" \
    "$(swift_code_lines "$K1N/main.swift" | grep -cF 'let uid = getuid()')|$(cntF "$K1N/Tests/main.swift" 'context-owner')" "1|1"

# ---- K1-06 P12 decode 失敗(owner 凍結順序:create / settings / unlock 在 decode 之前 → keychain 已存在)----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64='!!!not-base64!!!'; check "K1-06 非 base64 → 1" "$?" 1
check "K1-06 訊息 p12-decode" "$(cntF "$d/kc.err" 'kc_bootstrap: FAILED: p12-decode')" 1
check "K1-06 不曾 import;解碼暫存檔已移除;context = marker + keychain" "$(cntE "$d/security.log" '^import')|$(gone "$ctx/p12.tmp")|$(ents "$ctx")" "0|gone|$OK_ENTRIES"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-06 cleanup 0" $?
check "K1-06 cleanup 精確刪除臨時 keychain 一次;context 消失" "$(grep -cxF "delete-keychain $ctx/signing.keychain-db" "$d/security.log")|$(gone "$ctx")" "1|gone"
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64='    '; check "K1-06 解碼為空(只有空白)→ 1" "$?" 1
check "K1-06 空解碼:訊息 p12-decode、不曾 import、無殘留" "$(cntF "$d/kc.err" 'FAILED: p12-decode')|$(cntE "$d/security.log" '^import')|$(gone "$ctx/p12.tmp")" "1|0|gone"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-06 空解碼 cleanup 0" $?
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64="${P12_GOOD_B64%?}"; check "K1-06 截短(未填充)的 base64 → 1(嚴格解碼)" "$?" 1
check "K1-06 截短:訊息 p12-decode、不曾 import" "$(cntF "$d/kc.err" 'FAILED: p12-decode')|$(cntE "$d/security.log" '^import')" "1|0"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-06 截短 cleanup 0" $?

# ---- K1-07 create-keychain 失敗 ----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_SEC_FAIL=create-keychain; check "K1-07 create-keychain 失敗 → 1" "$?" 1
check "K1-07 訊息 create-keychain" "$(cntF "$d/kc.err" 'kc_bootstrap: FAILED: create-keychain')" 1
check "K1-07 之後的步驟都沒跑" "$(seclog_ops "$d")" "create-keychain "
check "K1-07 P12 從未解碼;context = 只有 marker" "$(gone "$d/import.seen")|$(gone "$ctx/p12.tmp")|$(ents "$ctx")" "gone|gone|.aipet-kc-context "
drive_kc "$d" kc_cleanup "$ctx"; green "K1-07 cleanup 0" $?
check "K1-07 cleanup 沒有 keychain 可刪 → 零 delete-keychain;context 消失" "$(cntE "$d/security.log" '^delete-keychain')|$(gone "$ctx")" "0|gone"

# ---- K1-08 unlock 失敗 ----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_SEC_FAIL=unlock-keychain; check "K1-08 unlock 失敗 → 1" "$?" 1
check "K1-08 訊息 unlock-keychain" "$(cntF "$d/kc.err" 'kc_bootstrap: FAILED: unlock-keychain')" 1
check "K1-08 順序止於 unlock" "$(seclog_ops "$d")" "create-keychain set-keychain-settings unlock-keychain "
check "K1-08 P12 從未解碼(decode 在 unlock 之後)" "$(gone "$d/import.seen")|$(gone "$ctx/p12.tmp")" "gone|gone"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-08 cleanup 0" $?
check "K1-08 cleanup 刪除臨時 keychain 一次" "$(cntE "$d/security.log" '^delete-keychain')" 1

# ---- K1-09 import 失敗(注入失敗 / 錯 P12 密碼)----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_SEC_FAIL=import; check "K1-09 import 失敗 → 1" "$?" 1
check "K1-09 訊息 import;解碼 P12 已刪;沒有 partition" "$(cntF "$d/kc.err" 'kc_bootstrap: FAILED: import')|$(gone "$ctx/p12.tmp")|$(seclog_ops "$d")" \
    "1|gone|create-keychain set-keychain-settings unlock-keychain import "
drive_kc "$d" kc_cleanup "$ctx"; green "K1-09 cleanup 0" $?
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_PASSWORD="${SENT}-wrong-password"; check "K1-09 錯 P12 密碼 → 1" "$?" 1
check "K1-09 錯密碼:import 確實讀到解碼檔、訊息 import、解碼 P12 已刪" "$(cntF "$d/import.seen" "$ctx/p12.tmp")|$(cntF "$d/kc.err" 'FAILED: import')|$(gone "$ctx/p12.tmp")" "1|1|gone"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-09 錯密碼 cleanup 0" $?

# ---- K1-10 解碼 P12 unlink 失敗 = bootstrap 失敗(fatal)----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_SEC_FAIL=uchg-p12; check "K1-10 unlink 失敗 → 1" "$?" 1
check "K1-10 訊息 p12-unlink" "$(cntF "$d/kc.err" 'kc_bootstrap: FAILED: p12-unlink')" 1
check "K1-10 失敗即停(沒有 partition / 身分 preflight)" "$(seclog_ops "$d")" "create-keychain set-keychain-settings unlock-keychain import "
check "K1-10 stderr / stdout 不含任何秘密" "$(cat "$d/kc.err" "$d/kc.out" | grep -cF -- "$SENT")" 0
check "K1-10 解碼 P12 仍在(fault 讓它不可刪;呼叫端必須處理)" "$(gone "$ctx/p12.tmp")" present
drive_kc "$d" kc_cleanup "$ctx"; check "K1-10 cleanup 時 P12 仍不可刪 → 1" "$?" 1
check "K1-10 cleanup 訊息 p12-unlink;仍刪掉臨時 keychain;marker 與 context 保留" \
    "$(cntF "$d/kc.err" 'CLEANUP_FAILED: p12-unlink')|$(gone "$ctx/signing.keychain-db")|$(gone "$ctx/.aipet-kc-context")" "1|gone|present"
chflags nouchg "$ctx/p12.tmp"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-10 修復後重試 cleanup 0" $?
check "K1-10 重試後 context 消失;delete-keychain 總共一次" "$(gone "$ctx")|$(cntE "$d/security.log" '^delete-keychain')" "gone|1"

# ---- K1-11 signing-key 存取設定(partition list)失敗 ----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_SEC_FAIL=set-key-partition-list; check "K1-11 partition 失敗 → 1" "$?" 1
check "K1-11 訊息 set-key-partition-list;P12 已刪;沒有身分 preflight" "$(cntF "$d/kc.err" 'FAILED: set-key-partition-list')|$(gone "$ctx/p12.tmp")|$(cntE "$d/security.log" '^find-identity')" "1|gone|0"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-11 cleanup 0" $?

# ---- K1-12 預期身分不在顯式 keychain ----
d="$(new_state)"; ctx="$(new_ctx "$d")"; K="$ctx/signing.keychain-db"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64="$P12_OTHERNAME_B64"; check "K1-12 P12 只含別的身分 → 1" "$?" 1
check "K1-12 訊息 identity-preflight + identity-absent" "$(cntF "$d/kc.err" 'FAILED: identity-preflight')|$(cntF "$d/kc.err" 'identity-absent')" "1|1"
check "K1-12 身分查詢只帶這個臨時 keychain" "$(grep -cxF "find-identity -v -p codesigning $K" "$d/security.log")|$(cntE "$d/security.log" '^find-identity')" "1|1"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$K"; red "K1-12 build-app validate(該臨時 keychain)→ 非零" $?
check "K1-12 validate 訊息 identity-absent" "$(cntF "$d/out" 'identity-absent')" 1
drive_kc "$d" kc_cleanup "$ctx"; green "K1-12 cleanup 0" $?

# ---- K1-13 login keychain 有「完全相符」身分、臨時 keychain 沒有 → 必須 FAIL ----
d="$(new_state)"; ctx="$(new_ctx "$d")"; K="$ctx/signing.keychain-db"
# 此案的模擬 search list 只有 login 誘餌 + 臨時 keychain(清空預設的 KC_DEV),讓「相符身分只在 login」成為唯一前提。
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64="$P12_NOKEY_B64" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_MATCH" FAKE_SEARCH_LIST_DEFAULT=; check "K1-13 bootstrap → 1" "$?" 1
check "K1-13 訊息 identity-absent" "$(cntF "$d/kc.err" 'identity-absent')" 1
( env FAKE_DIR="$d" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_MATCH" PATH="$TMP/bin:$PATH" security find-identity -v -p codesigning ) > "$d/ctl.out" 2>&1
check "K1-13 前提(非虛綠):不帶 keychain 的查詢會在模擬 search list 的 login 看到完全相符身分" "$(grep -cF "$DEV_SHA1 \"$DEVID\"" "$d/ctl.out")" 1
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$K" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_MATCH"; red "K1-13 build-app validate → 非零" $?
: > "$d/codesign.log"
drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$K" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_MATCH"; red "K1-13 build-app sign → 非零" $?
check "K1-13 沒有任何 Developer-ID codesign --sign(不退回 login 身分)" "$(cntF "$d/codesign.log" '--sign')" 0
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_NOKEY" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_MATCH"; red "K1-13 fixture 版:顯式 keychain 無私鑰 + login 有相符身分 → validate 非零" $?
drive_kc "$d" kc_cleanup "$ctx" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_MATCH"; green "K1-13 cleanup 0" $?

# ---- K1-14 錯誤 Team ID ----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" EXPECTED_TEAM_ID=WRONG99999; check "K1-14 EXPECTED_TEAM_ID ≠ 身分 Team → 2(任何副作用之前)" "$?" 2
check "K1-14 訊息 team-mismatch;context 未被寫入;零 security 呼叫" "$(cntF "$d/kc.err" 'REJECTED: team-mismatch')|$(ents "$ctx")|$(gone "$d/security.log")" "1||gone"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_IDENTITY="$EVID"; check "K1-14 自我一致的他隊身分 + EXPECTED=T1 → 2" "$?" 2
drive_kc "$d" kc_bootstrap "$ctx" EXPECTED_TEAM_ID=SHORT; check "K1-14 EXPECTED_TEAM_ID 形狀錯 → 2" "$?" 2
check "K1-14 形狀錯訊息 team-shape" "$(cntF "$d/kc.err" 'REJECTED: team-shape')" 1
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_IDENTITY="$APPLEDEV" DEVELOPER_ID_P12_BASE64="$P12_APPLEDEV_B64"; check "K1-14 非 Developer ID Application 類別(Apple Development)→ 2" "$?" 2
check "K1-14 類別訊息 identity-class;context 未被寫入" "$(cntF "$d/kc.err" 'REJECTED: identity-class')|$(ents "$ctx")" "1|"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64="$P12_EVIL_B64"; check "K1-14 P12 只含他隊身分(請求 DEVID)→ 1" "$?" 1
check "K1-14 他隊 P12:訊息 identity-absent" "$(cntF "$d/kc.err" 'identity-absent')" 1
drive_kc "$d" kc_cleanup "$ctx"; green "K1-14 cleanup 0" $?

# ---- K1-15 形狀錯的 EXPECTED_DEVELOPER_ID_CERT_SHA256(validate / bootstrap / verify 三層都拒;大寫 64 hex 合法)----
d0="$(new_state)"; sign_direct "$d0" "$KC_DEV" "$DEV_SHA1"; green "K1-15 前置:sign_direct 產生正確簽好的 bundle 狀態(供 verify 案)" $?
SHA_COLON="$(printf '%s' "$DEV_SHA256" | sed 's/../&:/g; s/:$//')"
SHA_BAD_LABELS=("63 hex" "65 hex" "冒號分隔" "SHA256: 前綴" "前置空白" "結尾空白" "結尾換行" "SHA-1(40 hex)" "截短 32 hex" "非 hex 字元")
SHA_BAD_VALUES=("${DEV_SHA256:0:63}" "${DEV_SHA256}0" "$SHA_COLON" "SHA256:$DEV_SHA256" " $DEV_SHA256" "$DEV_SHA256 " "$DEV_SHA256"$'\n' "$DEV_SHA1" "${DEV_SHA256:0:32}" "g${DEV_SHA256:1}")
i=0
while [ "$i" -lt "${#SHA_BAD_VALUES[@]}" ]; do
    lbl="${SHA_BAD_LABELS[$i]}"; v="${SHA_BAD_VALUES[$i]}"
    d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_DEVELOPER_ID_CERT_SHA256="$v"; red "K1-15 validate RED: $lbl" $?
    check "K1-15 validate 訊息 sha256-shape:$lbl" "$(cntF "$d/out" 'sha256-shape')" 1
    ctx="$(new_ctx "$d")"
    drive_kc "$d" kc_bootstrap "$ctx" EXPECTED_DEVELOPER_ID_CERT_SHA256="$v"; check "K1-15 bootstrap → 2:$lbl" "$?" 2
    check "K1-15 bootstrap 訊息 sha256-shape、context 未被寫入:$lbl" "$(cntF "$d/kc.err" 'REJECTED: sha256-shape')|$(ents "$ctx")" "1|"
    drive_verify "$d0" DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_DEVELOPER_ID_CERT_SHA256="$v"; red "K1-15 verify RED: $lbl" $?
    check "K1-15 verify 訊息(形狀):$lbl" "$(cntF "$d0/out" 'verify: EXPECTED_DEVELOPER_ID_CERT_SHA256 須恰為 64 個十六進位字元')" 1
    i=$((i + 1))
done
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_DEVELOPER_ID_CERT_SHA256=""; red "K1-15 validate RED: 缺值" $?
check "K1-15 validate 缺值訊息" "$(cntF "$d/out" '需要 EXPECTED_DEVELOPER_ID_CERT_SHA256')" 1
drive_verify "$d0" DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_DEVELOPER_ID_CERT_SHA256=""; red "K1-15 verify RED: 缺值" $?
check "K1-15 verify 缺值訊息" "$(cntF "$d0/out" 'verify: developer-id 需要 EXPECTED_DEVELOPER_ID_CERT_SHA256')" 1
run_main_fail EXPECTED_DEVELOPER_ID_CERT_SHA256="SHA256:$DEV_SHA256"; red "K1-15 main RED: 形狀錯 → main 非零" $?
check "K1-15 main:Swift build 從未被呼叫(validate 在前)" "$([ -e "$SWIFTPM_MARKER" ] && echo ran || echo none)" none
SHA_UPPER="$(printf '%s' "$DEV_SHA256" | tr 'abcdef' 'ABCDEF')"
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_DEVELOPER_ID_CERT_SHA256="$SHA_UPPER"; green "K1-15 GREEN: 大寫 64 hex(正規化為小寫)→ validate 0" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_DEVELOPER_ID_CERT_SHA256="$SHA_UPPER"; green "K1-15 GREEN: 大寫 64 hex → sign + verify 0" $?
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" EXPECTED_DEVELOPER_ID_CERT_SHA256="$SHA_UPPER"; green "K1-15 GREEN: 大寫 64 hex → bootstrap 0" $?
drive_kc "$d" kc_cleanup "$ctx"; green "K1-15 GREEN cleanup 0" $?

# ---- K1-16 leaf SHA-256 不符(名稱 / Team / 私鑰都相符,只有憑證不是預期那張)—— pre-sign 與 post-sign 兩層 ----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64="$P12_OTHERSHA_B64"; check "K1-16 bootstrap(同名他張憑證)→ 1" "$?" 1
check "K1-16 bootstrap 訊息 leaf-sha256-mismatch(只有 SHA-256 綁定擋得住)" "$(cntF "$d/kc.err" 'leaf-sha256-mismatch')" 1
drive_kc "$d" kc_cleanup "$ctx"; green "K1-16 cleanup 0" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_OTHERSHA"; red "K1-16 validate(同名他張憑證)→ 非零" $?
check "K1-16 validate 訊息 leaf-sha256-mismatch" "$(cntF "$d/out" 'leaf-sha256-mismatch')" 1
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_OTHERSHA"; red "K1-16 sign(同名他張憑證)→ 非零" $?
check "K1-16 pre-sign 就擋下:沒有任何 codesign --sign" "$(cntF "$d/codesign.log" '--sign')" 0
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_LEAF_CONTENT="$OTHER_CERT"; red "K1-16 post-sign:成品外層內嵌 leaf ≠ 預期 → verify 非零" $?
check "K1-16 post-sign 訊息(外層)" "$(cntF "$d/out" '的 leaf 憑證 SHA-256 ≠ EXPECTED_DEVELOPER_ID_CERT_SHA256')" 1
check "K1-16 post-sign 失敗後抽取暫存區仍被移除" "$(ents "$d/tmp")" ""
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_AIPET_LEAF_CONTENT="$OTHER_CERT"; red "K1-16 post-sign:僅巢狀 aipet 的 leaf ≠ 預期 → verify 非零" $?
check "K1-16 post-sign 訊息指向 aipet" "$(cntF "$d/out" 'Contents/MacOS/aipet 的 leaf 憑證 SHA-256')" 1
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID"; green "K1-16 配對 GREEN:內嵌 leaf == 預期 → 0" $?

# ---- K1-17 沒有私鑰(P12 只有憑證)----
d="$(new_state)"; ctx="$(new_ctx "$d")"; K="$ctx/signing.keychain-db"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64="$P12_NOKEY_B64"; check "K1-17 無私鑰 → 1" "$?" 1
check "K1-17 訊息 identity-absent;keychain 內確有該憑證但無私鑰" "$(cntF "$d/kc.err" 'identity-absent')|$(grep -c '^cert' "$K")|$(grep -c '^key' "$K")" "1|1|0"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-17 cleanup 0" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_NOKEY"; red "K1-17 validate(無私鑰 keychain)→ 非零" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_NOKEY"; red "K1-17 sign(無私鑰 keychain)→ 非零" $?
check "K1-17 沒有任何 codesign --sign" "$(cntF "$d/codesign.log" '--sign')" 0

# ---- K1-18 工具 stdout 雜訊不污染 context / selector ----
d="$(new_state)"
( env FAKE_DIR="$d" FAKE_SEC_NOISE=1 PATH="$TMP/bin:$PATH" security find-identity -v -p codesigning "$KC_DEV" ) > "$d/noise-ctl.out" 2>&1
check "K1-18 前提(非虛綠):FAKE_SEC_NOISE 確實讓 fake 印出 stdout 雜訊" "$(cntF "$d/noise-ctl.out" 'security-noise:')" 1
ctx="$(new_ctx "$d")"; K="$ctx/signing.keychain-db"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_SEC_NOISE=1; green "K1-18 雜訊下 bootstrap 0" $?
check "K1-18 stdout 為空;context == 白名單;marker 精確" "$(wc -c < "$d/kc.out" | tr -d ' ')|$(ents "$ctx")|$(cat "$ctx/.aipet-kc-context")" "0|$OK_ENTRIES|$MARKER_EXPECTED"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$K" FAKE_SEC_NOISE=1; green "K1-18 雜訊下 validate 0" $?
: > "$d/codesign.log"
drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$K" FAKE_SEC_NOISE=1; green "K1-18 雜訊下 sign + verify 0" $?
check "K1-18 selector 未被雜訊污染(--sign 恰為 derived SHA-1)" "$(cntF "$d/codesign.log" "--keychain $K --sign $DEV_SHA1 ")" 2
drive_kc "$d" kc_cleanup "$ctx" FAKE_SEC_NOISE=1; green "K1-18 雜訊下 cleanup 0" $?
check "K1-18 cleanup 後 context 消失" "$(gone "$ctx")" gone

# ---- K1-19 任意目錄 / 偽造 context 的 cleanup 一律被拒(零動作)----
d="$(new_state)"; MATCH_HASH0="$(fhash "$KC_LOGIN_MATCH")"
k19() { # $1=名稱 $2=預期 token ;在 $d/$1 上跑 cleanup,斷言 2 + token + 內容不變 + 零 delete-keychain
    local dir="$d/$1" before
    before="$(ents "$dir")"
    drive_kc "$d" kc_cleanup "$dir"; check "K1-19 $1 → 2" "$?" 2
    check "K1-19 $1 訊息 $2;內容不變" "$(cntF "$d/kc.err" "CONTEXT_REJECTED: $2")|$(ents "$dir")" "1|$before"
}
mkdir -m 700 "$d/wrongver"; printf 'aipet-kc-context v2\nuid=%s\n' "$(id -u)" > "$d/wrongver/.aipet-kc-context"; chmod 600 "$d/wrongver/.aipet-kc-context"; k19 wrongver marker-invalid
mkdir -m 700 "$d/wronguid"; printf 'aipet-kc-context v1\nuid=99999\n' > "$d/wronguid/.aipet-kc-context"; chmod 600 "$d/wronguid/.aipet-kc-context"; k19 wronguid marker-invalid
mkdir -m 700 "$d/trailing"; { valid_marker "$d/trailing"; printf 'extra\n' >> "$d/trailing/.aipet-kc-context"; }; k19 trailing marker-invalid
mkdir -m 700 "$d/nulmarker"; printf 'aipet-kc-context v1\nuid=%s\n\000junk' "$(id -u)" > "$d/nulmarker/.aipet-kc-context"; chmod 600 "$d/nulmarker/.aipet-kc-context"; k19 nulmarker marker-invalid
mkdir -m 700 "$d/mode644"; valid_marker "$d/mode644"; chmod 644 "$d/mode644/.aipet-kc-context"; k19 mode644 marker-invalid
mkdir -m 700 "$d/markerlink" "$d/realmarker"; valid_marker "$d/realmarker"; ln -s "$d/realmarker/.aipet-kc-context" "$d/markerlink/.aipet-kc-context"; k19 markerlink marker-type
mkdir -m 700 "$d/markerdir"; mkdir "$d/markerdir/.aipet-kc-context"; k19 markerdir marker-type
mkdir -m 700 "$d/unknown"; valid_marker "$d/unknown"; printf 'x' > "$d/unknown/user-file.txt"; k19 unknown unexpected-entry
mkdir -m 700 "$d/kclink"; valid_marker "$d/kclink"; ln -s "$KC_LOGIN_MATCH" "$d/kclink/signing.keychain-db"; k19 kclink entry-type
mkdir -m 700 "$d/p12dir"; valid_marker "$d/p12dir"; mkdir "$d/p12dir/p12.tmp"; k19 p12dir entry-type
mkdir -m 700 "$d/kcfifo"; valid_marker "$d/kcfifo"; /usr/bin/mkfifo "$d/kcfifo/signing.keychain-db"; k19 kcfifo entry-type
printf 'not a dir\n' > "$d/plainfile"; chmod 600 "$d/plainfile"
drive_kc "$d" kc_cleanup "$d/plainfile"; check "K1-19 一般檔(非目錄)→ 2" "$?" 2
check "K1-19 一般檔訊息 context-not-dir" "$(cntF "$d/kc.err" 'CONTEXT_REJECTED: context-not-dir')" 1
check "K1-19 全部案例零 delete-keychain;被 symlink 指到的 login fixture keychain 未被動到" "$(cntE "$d/security.log" '^delete-keychain')|$(fhash "$KC_LOGIN_MATCH")" "0|$MATCH_HASH0"
rm -f "$d/kcfifo/signing.keychain-db"

# ---- K1-20 delete-keychain 失敗 → 非零,保留可診斷 context;修復後重試成功 ----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-20 前置:bootstrap 0" $?
m_ino0="$(/usr/bin/stat -f %i "$ctx/.aipet-kc-context")"
drive_kc "$d" kc_cleanup "$ctx" FAKE_SEC_FAIL=delete-keychain; check "K1-20 delete-keychain 失敗 → 1" "$?" 1
check "K1-20 訊息 CLEANUP_FAILED: delete-keychain" "$(cntF "$d/kc.err" 'kc_cleanup: CLEANUP_FAILED: delete-keychain')" 1
check "K1-20 marker + keychain + context 全部保留" "$(ents "$ctx")" "$OK_ENTRIES"
check "K1-20 keychain 刪除失敗即停:marker 從未被刪除(inode 不變)、沒有走到 rmdir" \
    "$(/usr/bin/stat -f %i "$ctx/.aipet-kc-context")|$(cntF "$d/kc.err" 'rmdir')" "$m_ino0|0"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-20 修復後重試 cleanup 0" $?
check "K1-20 重試後 context 消失" "$(gone "$ctx")" gone
# delete-keychain 回報成功但檔仍在(fake 不刪檔)→ k1ctx context-finalize 以 residual-entry 擋下 → 1,marker 保留
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-20b 前置:bootstrap 0" $?
drive_kc "$d" kc_cleanup "$ctx" FAKE_SEC_FAIL=keep-keychain-file; check "K1-20b delete-keychain 回報成功但 keychain 檔仍在 → 1" "$?" 1
check "K1-20b 訊息 residual-entry;marker 與 keychain 檔保留(零遞迴刪除)" "$(cntF "$d/kc.err" 'CLEANUP_FAILED: residual-entry')|$(ents "$ctx")" "1|$OK_ENTRIES"
rm -f "$ctx/signing.keychain-db"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-20b 移除殘留檔後重試 cleanup 0" $?

# ---- K1-21 cleanup 只動 adapter / k1ctx 自己的物件(login keychain / 其他 search-list 項 / 旁觀檔)----
d="$(new_state)"; ctx="$(new_ctx "$d")"; K="$ctx/signing.keychain-db"; DECOY_HASH0="$(fhash "$KC_LOGIN_DECOY")"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_DECOY" FAKE_SEARCH_LIST_DEFAULT=; green "K1-21 前置:bootstrap 0(login 在模擬 search list 上)" $?
check "K1-21 bootstrap 後模擬 search list = login + 臨時 keychain" "$(tr '\n' '|' < "$d/search.list")" "$KC_LOGIN_DECOY|$K|"
drive_kc "$d" kc_cleanup "$ctx" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_DECOY" FAKE_SEARCH_LIST_DEFAULT=; green "K1-21 cleanup 0" $?
check "K1-21 cleanup 後模擬 search list 只剩 login(其他項保留)" "$(tr '\n' '|' < "$d/search.list")" "$KC_LOGIN_DECOY|"
check "K1-21 login keychain fixture 位元組未變" "$(fhash "$KC_LOGIN_DECOY")" "$DECOY_HASH0"
check "K1-21 delete-keychain 恰一次、引數精確;parent 只剩原封不動的旁觀檔" \
    "$(cntE "$d/security.log" '^delete-keychain')|$(grep -cxF "delete-keychain $K" "$d/security.log")|$(ents "$d/parent")|$(cat "$d/parent/bystander.txt")" \
    "1|1|bystander.txt |BYSTANDER-DO-NOT-TOUCH"

# ---- K1-22 成功 cleanup 不留 helper keychain / context(K1-G4 已斷言);另含崩潰遺留的解碼 P12 ----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-22 前置:bootstrap 0" $?
printf 'crash-leftover\n' > "$ctx/p12.tmp"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-22 有崩潰遺留 p12.tmp 時 cleanup 0" $?
check "K1-22 遺留 P12、keychain、context 全部消失" "$(gone "$ctx/p12.tmp")|$(gone "$ctx/signing.keychain-db")|$(gone "$ctx")" "gone|gone|gone"

# ---- K1-23 Developer-ID codesign 沒有顯式 keychain 是不可能的 ----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN=""; red "K1-23 sign_app_bundle 無 DEVELOPER_ID_KEYCHAIN → 非零" $?
check "K1-23 沒有任何 codesign 呼叫(pre-sign preflight 即擋)" "$(gone "$d/codesign.log")" gone
for sel_case in "空 keychain|$DEV_SHA1|" "名稱當 selector|$DEVID|$KC_DEV" "39 hex|${DEV_SHA1:0:39}|$KC_DEV" "空 selector||$KC_DEV" \
    "恰 40 字元的名稱片段(非 hex;codesign 會當子字串名稱)|${DEVID:0:40}|$KC_DEV"; do
    sc_name="${sel_case%%|*}"; sc_rest="${sel_case#*|}"; sc_sel="${sc_rest%%|*}"; sc_kc="${sc_rest#*|}"
    d="$(new_state)"
    ( cd "$ROOT" && env SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$sc_kc" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
        bash -c 'source "$1"; _sign_item_developer_id "$2/Contents/MacOS/aipet" "$3"' _ "$BUILD" "$APP" "$sc_sel" ) >"$d/out" 2>&1
    red "K1-23 _sign_item_developer_id 拒絕:$sc_name" $?
    check "K1-23 $sc_name:codesign 從未被呼叫" "$(gone "$d/codesign.log")" gone
done
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN=""; red "K1-23 validate 無 DEVELOPER_ID_KEYCHAIN → 非零" $?
check "K1-23 validate 訊息(必填)" "$(cntF "$d/out" '需要 DEVELOPER_ID_KEYCHAIN')" 1
mkdir -p "$TMP/k1-kcdir"; ln -s "$KC_DEV" "$TMP/k1-kclink"
for kc_case in "相對路徑|dev.keychain-db" "不存在|$TMP/k1-no-such.keychain-db" "是目錄|$TMP/k1-kcdir" "是 symlink|$TMP/k1-kclink"; do
    kc_name="${kc_case%%|*}"; kc_val="${kc_case#*|}"
    d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$kc_val"; red "K1-23 validate DEVELOPER_ID_KEYCHAIN $kc_name → 非零" $?
    check "K1-23 $kc_name:訊息 keychain-path、零 security 呼叫" "$(cntF "$d/out" 'FAILED: keychain-path')|$(gone "$d/security.log")" "1|gone"
done
# 相對路徑在 cwd 下「確實存在」(cwd = fixture 目錄,dev.keychain-db 就在那裡)仍須被拒:顯式 = 絕對路徑,不依 cwd 解析。
d="$(new_state)"
( cd "$FIX" && env SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="dev.keychain-db" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
    bash -c 'source "$1"; validate_signing_env' _ "$BUILD" ) >"$d/out" 2>&1
red "K1-23 validate:相對路徑即使在 cwd 下存在也拒絕" $?
check "K1-23 cwd 相對路徑:訊息 keychain-path、零 security 呼叫" "$(cntF "$d/out" 'FAILED: keychain-path')|$(gone "$d/security.log")" "1|gone"
run_main_fail DEVELOPER_ID_KEYCHAIN=""; red "K1-23 main 無 DEVELOPER_ID_KEYCHAIN → 非零" $?
check "K1-23 main:Swift build 從未被呼叫" "$([ -e "$SWIFTPM_MARKER" ] && echo ran || echo none)" none
# K5 的物件形狀判定現在是原生的(sol D3):developer-id 模式的 validate 需要 K1CTX_BIN;缺工具 → fail-closed、零 security 呼叫
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" K1CTX_BIN=""; red "K1-23 validate 無 K1CTX_BIN(developer-id)→ 非零" $?
check "K1-23 無 K1CTX_BIN:訊息 tool-missing、零 security 呼叫" "$(cntF "$d/out" 'tool-missing')|$(gone "$d/security.log")" "1|gone"
d="$(new_state)"; /usr/bin/mkfifo "$TMP/k1-kcfifo"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$TMP/k1-kcfifo"; red "K1-23 validate DEVELOPER_ID_KEYCHAIN 是 FIFO → 非零(不阻塞)" $?
check "K1-23 FIFO:訊息 keychain-path、零 security 呼叫" "$(cntF "$d/out" 'FAILED: keychain-path')|$(gone "$d/security.log")" "1|gone"
rm -f "$TMP/k1-kcfifo"
check "K1-23 靜態:adapter 的 keychain 形狀判定經 k1ctx check-keychain-path,無 shell 的 [ -f ] / [ -L ] 檢視" \
    "$(code_lines "$KCB" | grep -cF '_kc_native "$bin" check-keychain-path "$kc"')|$(code_lines "$KCB" | grep -cE '\[ (! )?-[efdL] "\$kc"')" "1|0"
check "K1-23 靜態:build-app.sh 的 Developer-ID codesign --sign 都帶 --keychain \"\$DEVELOPER_ID_KEYCHAIN\"(2 行)" \
    "$(code_lines "$BUILD" | grep -E 'codesign .*--sign "' | grep -c -- '--keychain "$DEVELOPER_ID_KEYCHAIN" --sign "$sel"')|$(code_lines "$BUILD" | grep -cE 'codesign .*--sign "')" "2|2"
check "K1-23 靜態:不存在以名稱 / 隱式方式選身分的 Developer-ID codesign" "$(code_lines "$BUILD" | grep -cF -- '--sign "$DEVELOPER_ID_IDENTITY"')" 0

# ---- K1-24 拿掉 codesign 的顯式 keychain 必須 RED ----
# 模擬 search list = login 誘餌(同名、不同憑證的身分)+ KC_DEV(man codesign:簽名 keychain 必須在 search list 上)。以 SHA-1
# selector 簽名時,省略 --keychain 在行為上不一定看得出差異(同一張憑證在哪個 keychain 都一樣),所以「拿掉 --keychain」由
# 下列 argv token 斷言 + K1-23 的靜態斷言抓(mutation 驗證);另附兩個控制組證明 search-list 查找本身不受侷限。
d="$(new_state)"
drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_DECOY"; green "K1-24 GREEN:帶 --keychain 只用顯式 keychain 的身分 → sign + verify 0" $?
check "K1-24 每個 Developer-ID codesign 都是 --keychain <KC_DEV> --sign <DEV SHA-1>(token 邊界)" \
    "$(cntF "$d/codesign.log" '--sign')|$(cntF "$d/codesign.log" "--keychain $KC_DEV --sign $DEV_SHA1 ")" "2|2"
d="$(new_state)"
( cd "$ROOT" && env FAKE_DIR="$d" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_DECOY" PATH="$TMP/bin:$PATH" \
    codesign --force --options runtime --timestamp --sign "$DEVID" "$APP/Contents/MacOS/aipet" ) >"$d/out" 2>&1
red "K1-24 控制組:以名稱且不帶 --keychain → 在 search list 上同時命中誘餌與 KC_DEV → 歧義失敗" $?
check "K1-24 控制組:失敗原因是歧義" "$(cntF "$d/out" 'ambiguous')" 1
d="$(new_state)"
( cd "$ROOT" && env FAKE_DIR="$d" FAKE_LOGIN_KEYCHAIN="$KC_LOGIN_DECOY" FAKE_SEARCH_LIST_DEFAULT= PATH="$TMP/bin:$PATH" bash -c \
    'codesign --force --options runtime --timestamp --sign "$1" "$2/Contents/MacOS/aipet" && codesign --force --options runtime --timestamp --sign "$1" "$2"' _ "$DEVID" "$APP" ) >/dev/null 2>&1
green "K1-24 控制組前置:search list 只有誘餌時,以名稱且不帶 --keychain 會靜默簽到誘餌身分" $?
drive_verify "$d" DEVELOPER_ID_IDENTITY="$DEVID"; red "K1-24 控制組:落到誘餌的簽章 → leaf SHA-256 擋下" $?
check "K1-24 控制組:擋下的是 leaf SHA-256" "$(cntF "$d/out" '的 leaf 憑證 SHA-256 ≠ EXPECTED_DEVELOPER_ID_CERT_SHA256')" 1
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SEARCH_LIST_DEFAULT=; red "K1-24 oracle:顯式 keychain 不在 search list(man 前提不成立)→ fake codesign 拒簽 → 非零" $?
check "K1-24 oracle:拒簽原因是 keychain 不在 search list" "$(cntF "$d/out" 'not on the user')" 1
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_WRONGPART" FAKE_SEARCH_LIST_DEFAULT="$KC_WRONGPART"; red "K1-24 oracle:partition list 缺 'apple:' → fake codesign 無法使用私鑰 → 非零" $?
check "K1-24 oracle:失敗原因是 errSecInternalComponent" "$(cntF "$d/out" 'errSecInternalComponent')" 1

# ---- K1-25 拿掉 SHA-256 綁定必須 RED:K1-16 的 pre-sign / post-sign 案「只有」SHA-256 比對擋得住(名稱、Team、私鑰
# 都相符),並由 mutation 證明;此處另鎖住兩個近似值不被誤當相符 ----
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_DEVELOPER_ID_CERT_SHA256="$OTHER_SHA256"; red "K1-25 validate:預期值 = 他張憑證的 SHA-256 → 非零" $?
check "K1-25 訊息 leaf-sha256-mismatch" "$(cntF "$d/out" 'leaf-sha256-mismatch')" 1
d="$(new_state)"; drive_verify "$d0" DEVELOPER_ID_IDENTITY="$DEVID" EXPECTED_DEVELOPER_ID_CERT_SHA256="$OTHER_SHA256"; red "K1-25 verify:預期值 = 他張憑證的 SHA-256 → 非零" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_SIBLING"; green "K1-25 GREEN:keychain 另有名稱以 DEVID 為子字串的身分 → 精確比對仍只選 DEVID → validate 0" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_SIBLING" FAKE_SEARCH_LIST_DEFAULT="$KC_SIBLING"; green "K1-25 GREEN:sibling keychain → sign + verify 0" $?
check "K1-25 sibling:selector 是 DEVID 那張憑證" "$(cntF "$d/codesign.log" "--keychain $KC_SIBLING --sign $DEV_SHA1 ")" 2

# ---- K1-R1 呼叫端 GLOBIGNORE 不得讓 context 列舉漏項(空目錄檢查 / 白名單 / verify 的憑證清理)----
d="$(new_state)"; mkdir -m 700 "$d/gi"; printf 'user\n' > "$d/gi/notes.txt"
( cd "$d" && env DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'GLOBIGNORE="*notes.txt"; for f in "$1"/*; do [ -e "$f" ] || echo CALLER_GLOB_HIDDEN; done
        source "$2"; kc_bootstrap "$1"; echo "RC=$?"' _ "$d/gi" "$KCB" ) >"$d/gi.out" 2>&1
check "K1-R1 前提(非虛綠):呼叫端自己的 glob 確實被 GLOBIGNORE 遮掉 notes.txt" "$(cntF "$d/gi.out" CALLER_GLOB_HIDDEN)" 1
check "K1-R1 GLOBIGNORE 下 bootstrap 仍判定非空 → 2;目錄未被寫入;零 security 呼叫" \
    "$(cntF "$d/gi.out" 'RC=2')|$(cntF "$d/gi.out" 'REJECTED: context-not-empty')|$(ents "$d/gi")|$(gone "$d/security.log")" "1|1|notes.txt |gone"
mkdir -m 700 "$d/gi2"; valid_marker "$d/gi2"; printf 'x' > "$d/gi2/user-file.txt"
( cd "$d" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'GLOBIGNORE="*user-file.txt"; source "$2"; kc_cleanup "$1"; echo "RC=$?"' _ "$d/gi2" "$KCB" ) >"$d/gi2.out" 2>&1
check "K1-R1 GLOBIGNORE 下 cleanup 仍看見白名單外的項目 → 2;內容不變" \
    "$(cntF "$d/gi2.out" 'RC=2')|$(cntF "$d/gi2.out" 'CONTEXT_REJECTED: unexpected-entry')|$(ents "$d/gi2")" "1|1|.aipet-kc-context user-file.txt "
# (bash 不採用從環境匯入的 GLOBIGNORE,故在 bash -c 內設定;先在另一目錄證明它確實會遮掉 leaf.* 檔名。)
d="$(new_state)"; mkdir -p "$d/tmp" "$d/ctl"; : > "$d/ctl/leaf.0"
( cd "$ROOT" && env TMPDIR="$d/tmp" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
    bash -c 'GLOBIGNORE="*leaf*"; set -- "$1" "$2" "$3"; for f in "$3"/leaf.*; do [ -e "$f" ] || echo CALLER_GLOB_HIDDEN; done
        source "$1"; sign_app_bundle "$2" && verify_signature "$2"; echo "RC=$?"' _ "$BUILD" "$APP" "$d/ctl" ) >"$d/out" 2>&1
check "K1-R1 前提(非虛綠):GLOBIGNORE='*leaf*' 確實遮掉 leaf.0" "$(cntF "$d/out" CALLER_GLOB_HIDDEN)" 1
check "K1-R1 GLOBIGNORE 下 sign + verify 0,且抽出的憑證仍全部移除(TMPDIR 為空)" "$(cntF "$d/out" 'RC=0')|$(ents "$d/tmp")" "1|"
# readonly GLOBIGNORE(sol attempt-002 F-S1):呼叫端把 GLOBIGNORE 設為 readonly(unset 必失敗)—— 列舉在 k1ctx 內以 readdir
# 完成、adapter 不去 unset / 改寫呼叫端變數,所以結果與一般呼叫端完全相同,且 stderr 沒有 "readonly" 錯誤噪音;呼叫後呼叫端的
# GLOBIGNORE 原封不動。
d="$(new_state)"; mkdir -m 700 "$d/gi3"; printf 'user\n' > "$d/gi3/notes.txt"
( cd "$d" && env DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'GLOBIGNORE="*notes.txt"; readonly GLOBIGNORE; source "$2"; kc_bootstrap "$1"; echo "RC=$?"; echo "GI=$GLOBIGNORE"' _ "$d/gi3" "$KCB" ) >"$d/gi3.out" 2>&1
check "K1-R1 readonly GLOBIGNORE 下 bootstrap 仍判定非空 → 2;目錄未被寫入;零 security 呼叫;無 readonly 錯誤;呼叫端 GLOBIGNORE 不變" \
    "$(cntF "$d/gi3.out" 'RC=2')|$(cntF "$d/gi3.out" 'REJECTED: context-not-empty')|$(ents "$d/gi3")|$(gone "$d/security.log")|$(grep -ci readonly "$d/gi3.out")|$(cntF "$d/gi3.out" 'GI=*notes.txt')" "1|1|notes.txt |gone|0|1"
mkdir -m 700 "$d/gi4"; valid_marker "$d/gi4"; printf 'x' > "$d/gi4/user-file.txt"
( cd "$d" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'GLOBIGNORE="*user-file.txt"; readonly GLOBIGNORE; source "$2"; kc_cleanup "$1"; echo "RC=$?"' _ "$d/gi4" "$KCB" ) >"$d/gi4.out" 2>&1
check "K1-R1 readonly GLOBIGNORE 下 cleanup 仍看見白名單外的項目 → 2;內容不變;無 readonly 錯誤" \
    "$(cntF "$d/gi4.out" 'RC=2')|$(cntF "$d/gi4.out" 'CONTEXT_REJECTED: unexpected-entry')|$(ents "$d/gi4")|$(grep -ci readonly "$d/gi4.out")" "1|1|.aipet-kc-context user-file.txt |0"
# 配對 GREEN:GLOBIGNORE='*'(遮掉一切)且 readonly 的呼叫端,有效 context 照常 bootstrap / cleanup(非恆 RED)
ctx="$(new_ctx "$d")"
( cd "$d" && env DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'GLOBIGNORE="*"; readonly GLOBIGNORE; source "$2"; kc_bootstrap "$1"; b=$?; kc_cleanup "$1"; echo "RCS=$b/$?"' _ "$ctx" "$KCB" ) >"$d/gi5.out" 2>&1
check "K1-R1 GLOBIGNORE='*' readonly:bootstrap 0、cleanup 0、context 消失、無 readonly 錯誤" "$(cntF "$d/gi5.out" 'RCS=0/0')|$(gone "$ctx")|$(grep -ci readonly "$d/gi5.out")" "1|gone|0"

# ---- K1-R2 呼叫端 functrace + DEBUG trap:adapter 內部指令不再觸發它(只剩 bash 在進入函式前的那幾次,屬呼叫端儀器)----
# 呼叫端的 DEBUG handler 只記錄「函式內」的指令(FUNCNAME[1] = 正在執行的函式):adapter 內部若有任何指令觸發它,就會
# 出現 "DBG:<函式>:<指令>" 且指令不是那次呼叫本身。控制組 ctl 證明同一個 handler 確實會暴露一般函式的內部指令。
d="$(new_state)"; ctx="$(new_ctx "$d")"
( cd "$d" && env DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'source "$2"
        dbg() { if [ "${#FUNCNAME[@]}" -gt 1 ]; then echo "DBG:${FUNCNAME[1]}:$BASH_COMMAND"; fi; }
        ctl() { echo ctl-inside >/dev/null; }
        set -T; trap dbg DEBUG
        ctl; kc_bootstrap "$1"; r1=$?; kc_cleanup "$1"; r2=$?; kc_cleanup /nonexistent-k1-dbg; r3=$?
        trap - DEBUG; echo "RCS=$r1/$r2/$r3" >&2' _ "$ctx" "$KCB" ) >"$d/dbg.out" 2>"$d/dbg.err"
check "K1-R2 DEBUG trap 下 bootstrap / cleanup / not-found 的退出碼不變" "$(cntF "$d/dbg.err" 'RCS=0/0/3')" 1
check "K1-R2 前提(非虛綠):同一 handler 會暴露一般函式的內部指令(控制組 ctl)" "$(cntF "$d/dbg.out" 'DBG:ctl:echo ctl-inside')" 1
check "K1-R2 adapter 內部指令零 DEBUG 輸出(只剩 bash 在函式進入前、以呼叫本身為指令的那幾次)" \
    "$(grep -E '^DBG:(kc_|_kc_)' "$d/dbg.out" | grep -cvE '^DBG:(kc_bootstrap|kc_cleanup):(kc_bootstrap|kc_cleanup) ')" 0
check "K1-R2 DEBUG 輸出不含任何秘密" "$(cat "$d/dbg.out" "$d/dbg.err" | grep -cF -- "$SENT")" 0

# ---- K1-R3 「不存在」只在 errno 可證實時才回 3(ENOENT / ENOTDIR);查找被拒(EACCES)、symlink 迴圈(ELOOP)等無法判定 → 1
#      (CLEANUP_FAILED: context-inaccessible,零動作)—— 不是 3(會被當成冪等成功)也不是 2(owner F2 凍結分類)----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-R3 前置:bootstrap 0" $?
chmod 600 "$d/parent"
drive_kc "$d" kc_cleanup "$ctx"; check "K1-R3 上層不可搜尋(context 其實存在)→ 1(EACCES),不是 3" "$?" 1
check "K1-R3 訊息 CLEANUP_FAILED: context-inaccessible 且含 EACCES;未呼叫 delete-keychain" \
    "$(cntF "$d/kc.err" 'CLEANUP_FAILED: context-inaccessible')|$(cntF "$d/kc.err" 'EACCES')|$(cntE "$d/security.log" '^delete-keychain')" "1|1|0"
drive_kc "$d" kc_cleanup "$d/parent/no-such-ctx"; check "K1-R3 上層不可搜尋下的不存在項 → 1(EACCES:無法證實不存在)" "$?" 1
drive_kc "$d" kc_bootstrap "$ctx"; check "K1-R3 bootstrap 無法判定 context 是否存在 → 2(零副作用)" "$?" 2
check "K1-R3 bootstrap 訊息 REJECTED: context-inaccessible + EACCES" "$(cntF "$d/kc.err" 'REJECTED: context-inaccessible')|$(cntF "$d/kc.err" 'EACCES')" "1|1"
chmod 700 "$d/parent"
check "K1-R3 修復後 context 原封不動" "$(ents "$ctx")" "$OK_ENTRIES"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-R3 修復後 cleanup 0" $?
printf 'x\n' > "$d/plain-parent"
drive_kc "$d" kc_cleanup "$d/plain-parent/ctx"; check "K1-R3 上層是一般檔(ENOTDIR:路徑不可能存在)→ 3" "$?" 3
check "K1-R3 ENOTDIR 只回報 CONTEXT_NOT_FOUND(adapter 恰一行)" "$(grep -cxF "kc_cleanup: CONTEXT_NOT_FOUND: $d/plain-parent/ctx" "$d/kc.err")|$(grep -c '^kc_cleanup:' "$d/kc.err")" "1|1"
drive_kc "$d" kc_cleanup "$d/missing-a/missing-b/ctx"; check "K1-R3 多層上層都不存在(ENOENT)→ 3" "$?" 3
drive_kc "$d" kc_bootstrap "$d/missing-a/missing-b/ctx"; check "K1-R3 bootstrap 不存在(ENOENT)→ 2 context-missing" "$?" 2
check "K1-R3 bootstrap 訊息 context-missing + ENOENT" "$(cntF "$d/kc.err" 'REJECTED: context-missing')|$(cntF "$d/kc.err" 'ENOENT')" "1|1"
ln -s "$d/loopB" "$d/loopA"; ln -s "$d/loopA" "$d/loopB"
drive_kc "$d" kc_cleanup "$d/loopA/ctx"; check "K1-R3 symlink 迴圈上層(ELOOP)→ 1,不是 3" "$?" 1
check "K1-R3 ELOOP 訊息 context-inaccessible + ELOOP" "$(cntF "$d/kc.err" 'CLEANUP_FAILED: context-inaccessible')|$(cntF "$d/kc.err" 'ELOOP')" "1|1"
# F-S2 動態重現(sol attempt-002):既存 context 透過「目標不可搜尋」的 symlink 上層存取 → 1 而非 3;上層可搜尋時 symlink 上層仍允許(0)
d="$(new_state)"; mkdir -p "$d/locked/parent" "$d/open"; ln -s "$d/locked/parent" "$d/open/link"
ctx="$(mktemp -d "$d/locked/parent/ctx.XXXXXXXX")"; via="$d/open/link/${ctx##*/}"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-R3(F-S2) 前置:bootstrap 0(直接路徑)" $?
chmod 600 "$d/locked"
drive_kc "$d" kc_cleanup "$via"; check "K1-R3(F-S2) 既存 context 在「目標不可搜尋」的 symlink 上層之後 → 1(EACCES),不是 3" "$?" 1
check "K1-R3(F-S2) 訊息 context-inaccessible + EACCES;未呼叫 delete-keychain" \
    "$(cntF "$d/kc.err" 'CLEANUP_FAILED: context-inaccessible')|$(cntF "$d/kc.err" 'EACCES')|$(cntE "$d/security.log" '^delete-keychain')" "1|1|0"
chmod 700 "$d/locked"
check "K1-R3(F-S2) context 仍完整存在" "$(ents "$ctx")" "$OK_ENTRIES"
drive_kc "$d" kc_cleanup "$via"; green "K1-R3(F-S2) 上層可搜尋:經 symlink 上層的 cleanup 0(祖先 symlink 允許;最後一段非 symlink)" $?
check "K1-R3(F-S2) context 消失" "$(gone "$ctx")" gone

# ---- K1-R4 最後的 rmdir 失敗 → 1,marker 原樣寫回;修復後重試可完成 ----
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-R4 前置:bootstrap 0" $?
chmod 500 "$d/parent"
drive_kc "$d" kc_cleanup "$ctx"; check "K1-R4 上層不可寫 → rmdir 失敗 → 1" "$?" 1
check "K1-R4 訊息 rmdir;keychain 已刪;marker 已原樣寫回(0600)" \
    "$(cntF "$d/kc.err" 'CLEANUP_FAILED: rmdir')|$(gone "$ctx/signing.keychain-db")|$(cat "$ctx/.aipet-kc-context")|$(/usr/bin/stat -f %Mp%Lp "$ctx/.aipet-kc-context")" "1|gone|$MARKER_EXPECTED|0600"
chmod 700 "$d/parent"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-R4 修復後重試 cleanup 0(未變成 marker-missing → 2)" $?
check "K1-R4 重試後 context 消失" "$(gone "$ctx")" gone

# ---- K1-R4b context-init 面對被佔用的 marker 路徑(owner F3 / N5 Create):context 必須「完全為空」,所以任何預先放置的物件
#      (一般檔、symlink、FIFO、目錄、dangling)都在列舉階段被拒(context-not-empty、零寫入、不開啟、不阻塞);O_EXCL 原語本身對
#      每種佔用物件的即時失敗由原生單元測試(第 4 節)逐一證明 ----
d="$(new_state)"; c4="$(mktemp -d "$d/c4.XXXXXXXX")"
init4() { run_deadline 10 bash -c '"$1" context-init "$2" >/dev/null 2>&1' _ "$K1CTX" "$c4"; }
check "K1-R4b 空目錄 → context-init 0、marker 精確、0600、一般檔" \
    "$(init4)|$(cat "$c4/.aipet-kc-context")|$(/usr/bin/stat -f %Mp%Lp "$c4/.aipet-kc-context")|$([ -f "$c4/.aipet-kc-context" ] && [ ! -L "$c4/.aipet-kc-context" ] && echo regular)" "FINISHED:0|$MARKER_EXPECTED|0600|regular"
check "K1-R4b 既存 marker → context-init 2(非空)、內容不變" "$(init4)|$(cat "$c4/.aipet-kc-context")" "FINISHED:2|$MARKER_EXPECTED"
rm -f "$c4/.aipet-kc-context"; printf 'VICTIM\n' > "$d/victim4"; ln -s "$d/victim4" "$c4/.aipet-kc-context"
check "K1-R4b symlink → 一般檔:2、受害檔不變、symlink 仍是 symlink" "$(init4)|$(cat "$d/victim4")|$([ -L "$c4/.aipet-kc-context" ] && echo link)" "FINISHED:2|VICTIM|link"
rm -f "$c4/.aipet-kc-context"; /usr/bin/mkfifo "$d/fifo4"; ln -s "$d/fifo4" "$c4/.aipet-kc-context"
check "K1-R4b symlink → FIFO(無讀端):2、不阻塞" "$(init4)" "FINISHED:2"
rm -f "$c4/.aipet-kc-context"; /usr/bin/mkfifo "$c4/.aipet-kc-context"
check "K1-R4b marker 路徑本身是 FIFO:2、不阻塞" "$(init4)" "FINISHED:2"
rm -f "$c4/.aipet-kc-context"; mkdir "$c4/.aipet-kc-context"
check "K1-R4b marker 路徑是目錄:2" "$(init4)" "FINISHED:2"
rmdir "$c4/.aipet-kc-context"; ln -s "$d/nowhere4" "$c4/.aipet-kc-context"
check "K1-R4b dangling symlink:2、目標未被建立" "$(init4)|$(gone "$d/nowhere4")" "FINISHED:2|gone"
rm -f "$c4/.aipet-kc-context" "$d/fifo4"
chmod 755 "$c4"
check "K1-R4b 目錄權限不是 0700 → 2(context-mode),不建立" "$(init4)|$(gone "$c4/.aipet-kc-context")" "FINISHED:2|gone"
chmod 700 "$c4"

# ---- K1-R4c rmdir 失敗後的 marker 寫回 vs 同 uid 競爭者(owner F3 / N14):競爭者以忙迴圈等 marker 被 unlink 的瞬間,植入「指向
#      無讀端 FIFO 的 symlink」;寫回必須因 O_EXCL 立刻失敗(回報「無法寫回 marker」、rc 1、不阻塞),而不是跟隨 symlink 開啟 FIFO
#      卡死。原生工具把 unlink → rmdir → 寫回全放在同一個行程內(沒有 fork / 直譯器啟動),空窗只有微秒級,shell 競爭者通常趕不上
#      —— 所以這個動態重現是「若贏則驗證分支」的加分項(未贏印 NOTE、不計 FAIL);決定性的證明在原生單元測試:寫回用的就是
#      createMarker(token marker-restore),它對 symlink → FIFO / FIFO / 目錄 / 既存檔都立刻以 EEXIST 失敗且不阻塞(第 4 節)----
d="$(new_state)"; /usr/bin/mkfifo "$d/racefifo"; r4c_won=0; r4c_try=0
while [ "$r4c_try" -lt 5 ] && [ "$r4c_won" -eq 0 ]; do
    r4c_try=$((r4c_try + 1))
    ctx="$(new_ctx "$d")"; marker="$ctx/.aipet-kc-context"
    drive_kc "$d" kc_bootstrap "$ctx" || { bad "K1-R4c 前置 bootstrap 失敗(第 $r4c_try 次)"; break; }
    rm -f "$d/race.planted"; chmod 500 "$d/parent"
    ( i=0; while [ -e "$marker" ] || [ -L "$marker" ]; do i=$((i + 1)); [ "$i" -gt 4000000 ] && exit 1; done
      ln -s "$d/racefifo" "$marker" 2>/dev/null && : > "$d/race.planted" ) & r4c_racer=$!
    r4c_res="$(cleanup_deadline "$ctx" "$d/r4c.err" "$d")"
    kill "$r4c_racer" 2>/dev/null; wait "$r4c_racer" 2>/dev/null
    chmod 700 "$d/parent"
    if [ -e "$d/race.planted" ] && [ "$(cntF "$d/r4c.err" '無法寫回 marker')" = 1 ]; then
        r4c_won=1
        check "K1-R4c 競爭者贏(第 $r4c_try 次):cleanup 完成(未阻塞在 FIFO)且 rc=1" "$r4c_res" "FINISHED:1"
        check "K1-R4c 競爭者贏:到達 rmdir 失敗 → 寫回分支;keychain 已刪;植入的 symlink 原封不動(未被跟隨、未被覆寫)" \
            "$(cntF "$d/r4c.err" 'CLEANUP_FAILED: rmdir')|$(gone "$ctx/signing.keychain-db")|$([ -L "$marker" ] && echo link)" "1|gone|link"
        rm -f "$marker"; rmdir "$ctx" 2>/dev/null
    else
        printf 'NOTE: K1-R4c 第 %d 次:競爭者未趕上寫回(planted=%s res=%s)— 重試\n' "$r4c_try" "$([ -e "$d/race.planted" ] && echo yes || echo no)" "$r4c_res"
        rm -f "$marker" 2>/dev/null; valid_marker "$ctx" 2>/dev/null; drive_kc "$d" kc_cleanup "$ctx" >/dev/null 2>&1
    fi
done
if [ "$r4c_won" -eq 0 ]; then printf 'NOTE: K1-R4c 競爭者 5 次都未趕上(原生工具的 unlink → 寫回空窗為微秒級);寫回原語的即時失敗由原生單元測試決定性證明\n'; fi
rm -f "$d/racefifo"
check "K1-R4c 靜態:rmdir 失敗後的寫回只經 createMarker(token marker-restore;單元測試證明它對 symlink→FIFO / FIFO / 目錄 / 既存檔立刻失敗、不阻塞)" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'try createMarker(handle.fd, uid: uid, token: "marker-restore")')|$(cntF "$K1N/Tests/main.swift" 'token: "marker-restore"')" "1|1"

# ---- K1-R5 解碼 P12 的 I/O(k1ctx write-p12 / remove-p12):原子建立、不跟隨任何 symlink、綁定到已驗證的 context ----
d="$(new_state)"; c5="$(mktemp -d "$d/c5.XXXXXXXX")"
( env FAKE_DIR="$d" "$K1CTX" context-init "$c5" ) >/dev/null 2>&1; green "K1-R5 前置:context-init 0" $?
p12w() { printf '%s' "$1" | /usr/bin/base64 | env FAKE_DIR="$d" "$K1CTX" write-p12 "$c5"; }   # harness 自己的 base64 只用來做 fixture
printf 'VICTIM\n' > "$d/victim"; ln -s "$d/victim" "$c5/p12.tmp"
p12w "${SENT}-P12-BYTES" >"$d/w.out" 2>&1; check "K1-R5 p12.tmp 是指向一般檔的 symlink → write-p12 2(白名單型別檢查先擋)" "$?" 2
check "K1-R5 訊息 entry-type;受害檔未被覆寫;symlink 仍是 symlink" "$(cntF "$d/w.out" 'token=entry-type')|$(cat "$d/victim")|$([ -L "$c5/p12.tmp" ] && echo link)" "1|VICTIM|link"
rm -f "$c5/p12.tmp"; ln -s /dev/null "$c5/p12.tmp"
p12w "${SENT}-P12-BYTES" >"$d/w.out" 2>&1; check "K1-R5 p12.tmp 是指向非一般檔(/dev/null)的 symlink → 2" "$?" 2
rm -f "$c5/p12.tmp"; ln -s "$d/would-be-created" "$c5/p12.tmp"
p12w "${SENT}-P12-BYTES" >"$d/w.out" 2>&1; check "K1-R5 dangling symlink → 2" "$?" 2
check "K1-R5 dangling 目標未被建立" "$(gone "$d/would-be-created")" gone
rm -f "$c5/p12.tmp"
chmod 755 "$c5"; p12w "${SENT}-P12-BYTES" >"$d/w.out" 2>&1; check "K1-R5 目錄權限不是 0700 → 2" "$?" 2
chmod 700 "$c5"
printf '' | env FAKE_DIR="$d" "$K1CTX" write-p12 "$c5" >"$d/w.out" 2>&1; check "K1-R5 空輸入 → 2 且不留檔" "$?" 2
check "K1-R5 空輸入不留 p12.tmp;訊息 p12-decode" "$(gone "$c5/p12.tmp")|$(cntF "$d/w.out" 'token=p12-decode')" "gone|1"
p12w "P12-BYTES-OK" >"$d/w.out" 2>&1; green "K1-R5 正常 write-p12 → 0" $?
check "K1-R5 寫入內容正確、權限 0600、是一般檔;stdout 不含內容" "$(cat "$c5/p12.tmp")|$(/usr/bin/stat -f %Mp%Lp "$c5/p12.tmp")|$([ -f "$c5/p12.tmp" ] && [ ! -L "$c5/p12.tmp" ] && echo regular)|$(cntF "$d/w.out" 'P12-BYTES-OK')" "P12-BYTES-OK|0600|regular|0"
p12w "AGAIN" >"$d/w.out" 2>&1; check "K1-R5 p12.tmp 已存在 → 1(p12-path;O_EXCL,不覆寫)" "$?" 1
check "K1-R5 既存內容未被覆寫;訊息 p12-path" "$(cat "$c5/p12.tmp")|$(cntF "$d/w.out" 'token=p12-path')" "P12-BYTES-OK|1"
( env FAKE_DIR="$d" "$K1CTX" remove-p12 "$c5" ) >/dev/null 2>&1; green "K1-R5 remove-p12 → 0" $?
check "K1-R5 remove 後 p12.tmp 不存在" "$(gone "$c5/p12.tmp")" gone
ln -s "$d/victim" "$c5/p12.tmp"; ( env FAKE_DIR="$d" "$K1CTX" remove-p12 "$c5" ) >/dev/null 2>&1; green "K1-R5 remove-p12 對 symlink 只刪連結 → 0" $?
check "K1-R5 remove 不跟隨 symlink(受害檔仍在)" "$(cat "$d/victim")|$(gone "$c5/p12.tmp")" "VICTIM|gone"
rm -f "$c5/.aipet-kc-context"; rmdir "$c5"

# ---- K1-R6 身分必須「有效」且「可用於 code signing」(find-identity -v -p codesigning)----
d="$(new_state)"
( env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" security find-identity -p codesigning "$KC_EXPIRED" ) > "$d/ctl-exp.out" 2>&1
check "K1-R6 前提(非虛綠):不帶 -v 時已失效的預期身分確實列出(帶 CSSMERR 後綴)" "$(grep -cF "$DEV_SHA1 \"$DEVID\" (CSSMERR_TP_CERT_EXPIRED)" "$d/ctl-exp.out")" 1
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_EXPIRED"; red "K1-R6 已失效的預期身分 → validate 非零" $?
check "K1-R6 已失效:訊息 identity-absent" "$(cntF "$d/out" 'identity-absent')" 1
d="$(new_state)"
( env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" security find-identity -v "$KC_NOCS" ) > "$d/ctl-nocs.out" 2>&1
check "K1-R6 前提(非虛綠):不帶 -p codesigning 時不可簽名的身分確實列出" "$(grep -cF "$DEV_SHA1 \"$DEVID\"" "$d/ctl-nocs.out")" 1
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_NOCS"; red "K1-R6 不可用於 code signing 的身分 → validate 非零" $?
check "K1-R6 不可簽名:訊息 identity-absent" "$(cntF "$d/out" 'identity-absent')" 1

# ---- K1-R7 身分 ↔ 憑證以身分列的 SHA-1 連結到「正是這張」憑證記錄(owner F4 / F5 / F6):SHA-1 只是 derived join / codesign
#      selector(不是信任輸入、不落盤);信任比對是連結到的那筆記錄的 SHA-256;標籤("labl")不是連結依據;0 筆 / >1 筆
#      連結、記錄不完整 → 一律 fail-closed ----
# (a) F-G1 攻擊(grok attempt-002):無私鑰的 DEV_CERT 掛著身分標籤且 SHA-256 == 預期;有私鑰的是 OTHER_CERT(標籤改名)→ 失敗
d="$(new_state)"
( env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" security find-identity -v -p codesigning "$KC_SPLIT_ATTACK" ) > "$d/ctl-id.out" 2>&1
( env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" security find-certificate -a -Z "$KC_SPLIT_ATTACK" ) > "$d/ctl-cert.out" 2>&1
check "K1-R7 前提(非虛綠):身分列 = OTHER_CERT 的 SHA-1;標籤 = 身分的記錄 SHA-256 == 預期(攻擊狀態確實成立)" \
    "$(grep -cF "$OTHER_SHA1 \"$DEVID\"" "$d/ctl-id.out")|$(cntF "$d/ctl-cert.out" "SHA-256 hash: $DEV_SHA256_UPPER")|$(cntF "$d/ctl-cert.out" "\"labl\"<blob>=\"$DEVID\"")|$(cntF "$d/ctl-cert.out" '"labl"<blob>="renamed-old"')" "1|1|1|1"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_SPLIT_ATTACK"; red "K1-R7(a) F-G1 攻擊 → validate 非零" $?
check "K1-R7(a) 擋下的是 leaf-sha256-mismatch(連結到有私鑰的 OTHER_CERT,不是標籤相符的那張)" "$(cntF "$d/out" 'leaf-sha256-mismatch')|$(cntF "$d/out" "SHA-256($OTHER_SHA256)")" "1|1"
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_SPLIT_ATTACK" FAKE_SEARCH_LIST_DEFAULT="$KC_SPLIT_ATTACK"; red "K1-R7(a) F-G1 攻擊 → sign 非零(pre-sign 即擋)" $?
check "K1-R7(a) 沒有任何 codesign --sign" "$(cntF "$d/codesign.log" '--sign')" 0
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64="$(b64_of "$P12_SPLIT_ATTACK")"; check "K1-R7(a) bootstrap(F-G1 攻擊 P12)→ 1" "$?" 1
check "K1-R7(a) bootstrap 訊息 leaf-sha256-mismatch" "$(cntF "$d/kc.err" 'leaf-sha256-mismatch')" 1
drive_kc "$d" kc_cleanup "$ctx"; green "K1-R7(a) cleanup 0" $?
# (b) 標籤無關:有私鑰的 DEV_CERT 標籤改名;無私鑰的 OTHER_CERT 掛著身分標籤 → 通過,selector = DEV_CERT 的 SHA-1
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_SPLIT_GOOD"; green "K1-R7(b) 有私鑰的預期憑證標籤改名、他張掛身分標籤 → validate 0(標籤不是連結依據)" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_SPLIT_GOOD" FAKE_SEARCH_LIST_DEFAULT="$KC_SPLIT_GOOD"; green "K1-R7(b) → sign + verify 0" $?
check "K1-R7(b) 兩次 codesign 都以 DEV_CERT 的 SHA-1 為 selector" "$(cntF "$d/codesign.log" "--keychain $KC_SPLIT_GOOD --sign $DEV_SHA1 ")" 2
# (c) 同標籤兩張、有私鑰的是預期那張 → 通過(標籤重複不是失敗理由)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_DUPLABEL_GOOD"; green "K1-R7(c) 同標籤兩張、有私鑰的是預期那張 → validate 0" $?
# (d) 同標籤兩張、有私鑰的不是預期那張(預期 SHA-256 屬於無私鑰那張)→ 失敗 leaf-sha256-mismatch(不以標籤挑出無私鑰那張)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_DUPCERT"; red "K1-R7(d) 預期 SHA-256 屬於無私鑰的同標籤憑證 → validate 非零" $?
check "K1-R7(d) 訊息 leaf-sha256-mismatch" "$(cntF "$d/out" 'leaf-sha256-mismatch')" 1
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" DEVELOPER_ID_P12_BASE64="$(b64_of "$P12_DUPCERT")"; check "K1-R7(d) bootstrap(同標籤兩張、有私鑰的不是預期那張)→ 1" "$?" 1
check "K1-R7(d) bootstrap 訊息 leaf-sha256-mismatch" "$(cntF "$d/kc.err" 'leaf-sha256-mismatch')" 1
drive_kc "$d" kc_cleanup "$ctx"; green "K1-R7(d) cleanup 0" $?
# (e) 身分列的 SHA-1 對不到任何憑證記錄(0 筆;keychain 另有其他記錄)→ cert-join-none;完全沒有記錄時 find-certificate 本身非零 → 同樣 fail-closed
d="$(new_state)"
( env FAKE_DIR="$d" FAKE_SEC_OMIT_CERT_SHA1="$DEV_SHA1" PATH="$TMP/bin:$PATH" security find-certificate -a -Z "$KC_SIBLING" ) > "$d/ctl-omit.out" 2>&1
check "K1-R7(e) 前提(非虛綠):省略後 find-certificate 不含該 SHA-1 的記錄但仍有其他記錄(省略前有該記錄)" \
    "$(cntF "$d/ctl-omit.out" "SHA-1 hash: $DEV_SHA1")|$(cntF "$d/ctl-omit.out" 'SHA-1 hash: ')|$( (env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" security find-certificate -a -Z "$KC_SIBLING") 2>/dev/null | grep -cF "SHA-1 hash: $DEV_SHA1")" "0|1|1"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_SIBLING" FAKE_SEC_OMIT_CERT_SHA1="$DEV_SHA1"; red "K1-R7(e) 身分 SHA-1 對到 0 筆憑證記錄 → validate 非零" $?
check "K1-R7(e) 訊息 cert-join-none" "$(cntF "$d/out" 'cert-join-none')" 1
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SEC_OMIT_CERT_SHA1="$DEV_SHA1"; red "K1-R7(e) 對照:keychain 完全沒有憑證記錄 → find-certificate 非零 → validate 非零" $?
check "K1-R7(e) 對照訊息 FAILED: find-certificate" "$(cntF "$d/out" 'FAILED: find-certificate')" 1
# (f) 對到 >1 筆(同 SHA-1、不同 SHA-256;附加的那筆帶「預期」SHA-256)→ cert-join-ambiguous(不得取其一放行)
d="$(new_state)"
printf 'SHA-256 hash: %s\nSHA-1 hash: %s\nkeychain: "%s"\nversion: 512\nclass: 0x80001000 \nattributes:\n    "labl"<blob>="%s"\n' "$DEV_SHA256_UPPER" "$OTHER_SHA1" "$KC_OTHERSHA" "$DEVID" > "$d/dup.rec"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_OTHERSHA" FAKE_SEC_CERT_APPEND="$d/dup.rec"; red "K1-R7(f) 身分 SHA-1 對到 2 筆記錄(其一帶預期 SHA-256)→ validate 非零" $?
check "K1-R7(f) 訊息 cert-join-ambiguous" "$(cntF "$d/out" 'cert-join-ambiguous')" 1
# (g) 對照:對到恰一筆但 SHA-256 錯 → leaf-sha256-mismatch(非 ambiguous;K1-16 同)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_OTHERSHA"; red "K1-R7(g) 對照:恰一筆、SHA-256 錯 → validate 非零" $?
check "K1-R7(g) 訊息 leaf-sha256-mismatch(非 ambiguous)" "$(cntF "$d/out" 'leaf-sha256-mismatch')|$(cntF "$d/out" 'cert-join-ambiguous')" "1|0"
# (h) owner F7 parser:記錄 N 完整,N+1 缺 SHA-256(只有 SHA-1 = 身分 SHA-1 + keychain)→ 不得繼承 N 的 SHA-256;省略身分真正的
#     記錄,讓「繼承」成為唯一能放行的途徑 → 必須 cert-record-incomplete
d="$(new_state)"
printf 'SHA-256 hash: %s\nSHA-1 hash: %s\nkeychain: "%s"\nversion: 512\nclass: 0x80001000 \nattributes:\n    "labl"<blob>="other"\nSHA-1 hash: %s\nkeychain: "%s"\nversion: 512\nattributes:\n    "labl"<blob>="%s"\n' \
    "$DEV_SHA256_UPPER" "$DEV_SHA1" "$KC_OTHERSHA" "$OTHER_SHA1" "$KC_OTHERSHA" "$DEVID" > "$d/inherit.rec"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_KEYCHAIN="$KC_OTHERSHA" FAKE_SEC_OMIT_CERT_SHA1="$OTHER_SHA1" FAKE_SEC_CERT_APPEND="$d/inherit.rec"; red "K1-R7(h) N+1 缺 SHA-256 的記錄不得繼承 N 的 SHA-256 → validate 非零" $?
check "K1-R7(h) 訊息 cert-record-incomplete(而非放行)" "$(cntF "$d/out" 'cert-record-incomplete')" 1
# (i) N+1 缺 SHA-1(有 SHA-256 + keychain)→ cert-record-incomplete
d="$(new_state)"; printf 'SHA-256 hash: %s\nkeychain: "%s"\nversion: 512\nattributes:\n    "labl"<blob>="x"\n' "$OTHER_SHA256_UPPER" "$KC_DEV" > "$d/nosha1.rec"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SEC_CERT_APPEND="$d/nosha1.rec"; red "K1-R7(i) 缺 SHA-1 的記錄 → validate 非零" $?
check "K1-R7(i) 訊息 cert-record-incomplete" "$(cntF "$d/out" 'cert-record-incomplete')" 1
# (j) 結尾未提交(缺 keychain 列)、(k) 記錄之外的 keychain 列、(l) SHA-1 形狀不符 → 皆 cert-record-incomplete
d="$(new_state)"; printf 'SHA-256 hash: %s\nSHA-1 hash: %s\n' "$OTHER_SHA256_UPPER" "$OTHER_SHA1" > "$d/trail.rec"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SEC_CERT_APPEND="$d/trail.rec"; red "K1-R7(j) 結尾未提交的記錄 → validate 非零" $?
check "K1-R7(j) 訊息 cert-record-incomplete" "$(cntF "$d/out" 'cert-record-incomplete')" 1
d="$(new_state)"; printf 'keychain: "%s"\n' "$KC_DEV" > "$d/strayKc.rec"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SEC_CERT_APPEND="$d/strayKc.rec"; red "K1-R7(k) 記錄之外的 keychain 列 → validate 非零" $?
check "K1-R7(k) 訊息 cert-record-incomplete" "$(cntF "$d/out" 'cert-record-incomplete')" 1
d="$(new_state)"; printf 'SHA-256 hash: %s\nSHA-1 hash: ZZZZ\nkeychain: "%s"\n' "$OTHER_SHA256_UPPER" "$KC_DEV" > "$d/badsha1.rec"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SEC_CERT_APPEND="$d/badsha1.rec"; red "K1-R7(l) SHA-1 形狀不符的記錄 → validate 非零" $?
check "K1-R7(l) 訊息 cert-record-incomplete" "$(cntF "$d/out" 'cert-record-incomplete')" 1
# (m) 大小寫正規化:省略真正的記錄,附加「小寫 SHA-1」的同一張憑證 → 仍連結 → 通過(非恆 RED;連結比對不分大小寫)
d="$(new_state)"
printf 'SHA-256 hash: %s\nSHA-1 hash: %s\nkeychain: "%s"\nversion: 512\nattributes:\n    "labl"<blob>="%s"\n' "$DEV_SHA256_UPPER" "$(printf '%s' "$DEV_SHA1" | tr 'ABCDEF' 'abcdef')" "$KC_DEV" "$DEVID" > "$d/lower.rec"
drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SEC_OMIT_CERT_SHA1="$DEV_SHA1" FAKE_SEC_CERT_APPEND="$d/lower.rec"; green "K1-R7(m) 小寫 SHA-1 的記錄仍連結(正規化)→ validate 0" $?
# 靜態:連結鍵是身分列 SHA-1、信任比對是 SHA-256;標籤不參與;0 筆 / >1 筆各有 fail-closed 分支
check "K1-R7 靜態:以身分列 SHA-1 連結憑證記錄(join),再以 SHA-256 比對預期值" \
    "$(code_lines "$KCB" | grep -cF 'if [ "$cur1" = "$sel" ]; then njoin=$((njoin + 1)); got="$cur256"; fi')|$(code_lines "$KCB" | grep -cF 'if [ "$got" != "$want" ]; then')" "1|1"
check "K1-R7 靜態:標籤(labl)不再出現在程式碼(不是連結依據)" "$(code_lines "$KCB" | grep -c '"labl"')" 0
check "K1-R7 靜態:連結到的記錄數須恰為 1(0 筆與 >1 筆各有 fail-closed 分支)" "$(code_lines "$KCB" | grep -cF 'if [ "$njoin" -eq 0 ]; then')|$(code_lines "$KCB" | grep -cF 'if [ "$njoin" -gt 1 ]; then')" "1|1"

# ---- K1-R8 列舉失敗 fail-closed(owner F1 / N6):以 ACL "deny list" 讓目錄 mode 仍為 0700、可 cd、可 stat,但 open(O_RDONLY) /
#      readdir 失敗(macOS chmod +a)。bootstrap → 2(零副作用);有效 context 的 cleanup → 1(零動作);移除 ACL 後 → 0 ----
d="$(new_state)"; mkdir -m 700 "$d/aclctx"
if chmod +a "$(id -un) deny list" "$d/aclctx" 2>/dev/null && ! ls -A "$d/aclctx" >/dev/null 2>&1; then
    check "K1-R8 前提(非虛綠):ACL 後 mode 仍 0700、cd 可、ls 不可" "$(/usr/bin/stat -f %Mp%Lp "$d/aclctx")|$( (cd "$d/aclctx") 2>/dev/null && echo cd-ok)" "0700|cd-ok"
    drive_kc "$d" kc_bootstrap "$d/aclctx"; check "K1-R8 bootstrap 無法列舉 → 2(fail-closed,無副作用)" "$?" 2
    check "K1-R8 bootstrap 訊息 context-inaccessible(EACCES);零 security 呼叫" "$(cntF "$d/kc.err" 'REJECTED: context-inaccessible')|$(cntF "$d/kc.err" 'EACCES')|$(gone "$d/security.log")" "1|1|gone"
    chmod -N "$d/aclctx"
    check "K1-R8 bootstrap 被拒時目錄未被寫入(無 marker)" "$(ents "$d/aclctx")" ""
    ctx="$(new_ctx "$d")"; drive_kc "$d" kc_bootstrap "$ctx"; green "K1-R8 前置:bootstrap 0" $?
    chmod +a "$(id -un) deny list" "$ctx"
    drive_kc "$d" kc_cleanup "$ctx"; check "K1-R8 cleanup 無法列舉 → 1(作業失敗,零動作),不是 2 也不是 0" "$?" 1
    check "K1-R8 cleanup 訊息 CLEANUP_FAILED: context-inaccessible;未呼叫 delete-keychain" "$(cntF "$d/kc.err" 'CLEANUP_FAILED: context-inaccessible')|$(cntE "$d/security.log" '^delete-keychain')" "1|0"
    chmod -N "$ctx"
    check "K1-R8 零動作:marker 與 keychain 仍在" "$(ents "$ctx")" "$OK_ENTRIES"
    drive_kc "$d" kc_cleanup "$ctx"; green "K1-R8 移除 ACL 後 cleanup 0" $?
    check "K1-R8 context 消失" "$(gone "$ctx")" gone
else
    chmod -N "$d/aclctx" 2>/dev/null
    printf 'SKIP: 本環境的 ACL deny-list 無法阻止目錄列舉(或 chmod +a 不可用)— 跳過 K1-R8 列舉失敗案\n'
fi

# ---- K1-N1 F-N1 回歸(owner N14):marker 在「較早的 metadata 觀察」與原生讀取之間被置換 —— 原生讀取只以「這次開啟到的物件」
#      判定(O_NOFOLLOW|O_NONBLOCK + fstat 同一 fd),所以置換只能得到 2(拒絕)、零動作、不阻塞;不可能變成 symlink 解析、FIFO
#      阻塞或讀到不相關的檔。每個變體都先由 harness 以 stat 觀察到「一般檔 marker」(= 較早的觀察),再置換,再在期限內跑 cleanup ----
d="$(new_state)"; /usr/bin/mkfifo "$d/n1fifo"; printf 'aipet-kc-context v1\nuid=%s\n' "$(id -u)" > "$d/n1good"; chmod 600 "$d/n1good"
n1() { # $1=名稱 $2=植入指令(以 $marker 為目標) $3=預期 token
    local ctx marker res del0
    ctx="$(new_ctx "$d")"; marker="$ctx/.aipet-kc-context"
    drive_kc "$d" kc_bootstrap "$ctx" || { bad "K1-N1 $1 前置 bootstrap 失敗"; return; }
    check "K1-N1 $1:較早的觀察看到一般檔 marker(非虛測)" "$(/usr/bin/stat -f %HT "$marker")" "Regular File"
    rm -f "$marker"; eval "$2"
    del0="$(cntE "$d/security.log" '^delete-keychain')"
    : > "$d/n1.err"; res="$(cleanup_deadline "$ctx" "$d/n1.err" "$d")"
    check "K1-N1 $1:cleanup 在期限內完成(未阻塞)且 rc=2(拒絕)" "$res" "FINISHED:2"
    check "K1-N1 $1:訊息 $3;keychain 原封不動;未呼叫 delete-keychain(計數不變);植入物未被跟隨 / 覆寫" \
        "$(cntF "$d/n1.err" "CONTEXT_REJECTED: $3")|$(gone "$ctx/signing.keychain-db")|$(cntE "$d/security.log" '^delete-keychain')|$([ -e "$marker" ] || [ -L "$marker" ] && echo planted)" "1|present|$del0|planted"
    rm -rf "$marker"; valid_marker "$ctx"; drive_kc "$d" kc_cleanup "$ctx" >/dev/null 2>&1
}
n1 "換成 FIFO(無寫端)" '/usr/bin/mkfifo "$marker"' marker-type
n1 "換成 symlink → FIFO(無寫端)" 'ln -s "$d/n1fifo" "$marker"' marker-type
n1 "換成 symlink → 內容正確的不相關檔" 'ln -s "$d/n1good" "$marker"' marker-type
n1 "換成目錄" 'mkdir "$marker"' marker-type
n1 "換成 0644 的一般檔(內容正確)" 'cp "$d/n1good" "$marker"; chmod 644 "$marker"' marker-invalid
n1 "換成同長度錯內容(v2)" 'printf "aipet-kc-context v2\nuid=%s\n" "$(id -u)" > "$marker"; chmod 600 "$marker"' marker-invalid
check "K1-N1 植入的 symlink 目標(FIFO / 不相關檔)原封不動" "$([ -p "$d/n1fifo" ] && echo fifo)|$(cat "$d/n1good")" "fifo|$MARKER_EXPECTED"
rm -f "$d/n1fifo" "$d/n1good"
check "K1-N1 靜態:檔案讀取的 openat 一律帶 O_NOFOLLOW 與 O_NONBLOCK(marker 讀取 + 掃描檔讀取 = 2 處),且 marker open 之後對同一 fd 做 fstat 再讀取" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'openat(dirfd, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'if fstat(fd, &st) != 0 { throw K1Error(.operational, "marker-read"')" "2|1"
check "K1-N1 靜態:adapter 沒有任何以 shell 讀取 / 檢視 context 內部或 keychain 路徑的寫法(< 重導向、[ -e/-f/-L/-d \"\$ctx|marker|p12|kc\" ]、stat、cat、ls、find、rm、mkdir、chmod)" \
    "$(code_lines "$KCB" | grep -cE '<[[:space:]]*"?\$')|$(code_lines "$KCB" | grep -cE '\[ (! )?-[efdLprs] "\$(ctx|marker|p12|kc)')|$(code_lines "$KCB" | grep -cE '(^|[[:space:];|&(])(/usr/bin/)?(stat|cat|ls|find|grep -r|rm|rmdir|mkdir|chmod)[[:space:]]')" "0|0|0"

# ---- K1-N2 F-N2 回歸(owner N15):秘密衛生掃描是原生、fail-closed 的 —— 不可走訪的子樹底下藏著 sentinel 時結果必須是
#      INCOMPLETE_SCAN(exit 1),不是 CLEAN;FIFO 不阻塞;symlink 依凍結政策不跟隨;所有路徑都被走訪或被明確回報 ----
d="$(new_state)"; T2="$d/tree"; mkdir -p "$T2/ok" "$T2/locked/deep"
printf 'clean\n' > "$T2/ok/a.txt"; printf 'also clean\n' > "$T2/ok/.hidden"; printf 'xx %s yy\n' "$SENT" > "$T2/locked/deep/leak.txt"
scan2() { printf '%s\n' "$SENT" | env FAKE_DIR="$d" "$K1CTX" scan-secrets "$@"; }
scan2 "$T2" > "$d/scan.out" 2>&1; check "K1-N2 可讀樹 + 深層 sentinel → SECRET_FOUND(2)" "$?" 2
check "K1-N2 MATCH 指向 leak.txt;summary 計數完整(files=3 dirs=4 errors=0)" "$(grep -cxF "MATCH $T2/locked/deep/leak.txt" "$d/scan.out")|$(grep -cE '^summary files=3 dirs=4 symlinks=0 special=0 excluded=0 errors=0 matches=1 status=SECRET_FOUND$' "$d/scan.out")" "1|1"
chmod 000 "$T2/locked"
scan2 "$T2" > "$d/scan.out" 2>&1; check "K1-N2 不可走訪的子樹 + 其下 sentinel → INCOMPLETE_SCAN(1),不是 CLEAN" "$?" 1
check "K1-N2 ERROR 行指名 locked(EACCES);status=INCOMPLETE_SCAN;matches=0" "$(grep -cxF "ERROR EACCES opendir $T2/locked" "$d/scan.out")|$(grep -cE '^summary .* errors=1 matches=0 status=INCOMPLETE_SCAN$' "$d/scan.out")" "1|1"
chmod 700 "$T2/locked"
# 與舊 K1-S8 的 count-based 寫法對照(非虛綠):同一棵樹、同樣鎖住,grep -rl 的管線會把 traversal error 吞成「0 個命中」
chmod 000 "$T2/locked"
old_count="$(grep -rlF -D skip -- "$SENT" "$T2" 2>/dev/null | wc -l | tr -d ' ')"
chmod 700 "$T2/locked"
check "K1-N2 對照(舊 oracle 的缺陷確實存在):grep -rl 在鎖住的子樹下回報 0 個命中(= 會誤判 CLEAN)" "$old_count" 0
chmod 000 "$T2/locked/deep/leak.txt"
scan2 "$T2" > "$d/scan.out" 2>&1; check "K1-N2 不可讀的檔 → INCOMPLETE_SCAN(unreadable item = FAIL)" "$?" 1
check "K1-N2 ERROR 行指名 leak.txt(EACCES open)" "$(grep -cxF "ERROR EACCES open $T2/locked/deep/leak.txt" "$d/scan.out")" 1
chmod 600 "$T2/locked/deep/leak.txt"
if chmod +a "$(id -un) deny list" "$T2/locked" 2>/dev/null && ! ls -A "$T2/locked" >/dev/null 2>&1; then
    scan2 "$T2" > "$d/scan.out" 2>&1; check "K1-N2 ACL deny-list 的子樹(mode 仍 0700)→ INCOMPLETE_SCAN" "$?" 1
    chmod -N "$T2/locked"
else
    chmod -N "$T2/locked" 2>/dev/null; printf 'SKIP: ACL deny-list 不可用 — 跳過 K1-N2 ACL 子樹案\n'
fi
scan2 --exclude "$T2/locked" "$T2" > "$d/scan.out" 2>&1; check "K1-N2 明確排除子樹 → CLEAN(0)" "$?" 0
check "K1-N2 排除:excluded=1、該子樹未被走訪(dirs=2 files=2)" "$(grep -cE '^summary files=2 dirs=2 symlinks=0 special=0 excluded=1 errors=0 matches=0 status=CLEAN$' "$d/scan.out")" 1
rm -f "$T2/locked/deep/leak.txt"
/usr/bin/mkfifo "$T2/fifo"
n2res="$(run_deadline 10 bash -c 'printf "%s\n" "$1" | "$2" scan-secrets "$3" > "$4" 2>&1' _ "$SENT" "$K1CTX" "$T2" "$d/scan.out")"
check "K1-N2 FIFO(無寫端)不阻塞掃描、完成且 CLEAN" "$n2res" "FINISHED:0"
check "K1-N2 FIFO 計為 special=1、files 不含它" "$(grep -cE '^summary files=2 dirs=4 symlinks=0 special=1 excluded=0 errors=0 matches=0 status=CLEAN$' "$d/scan.out")" 1
rm -f "$T2/fifo"
printf '%s\n' "$SENT" > "$d/outside-secret"; ln -s "$d/outside-secret" "$T2/lnk"
scan2 "$T2" > "$d/scan.out" 2>&1; check "K1-N2 symlink → 外部含 sentinel 的檔:不跟隨(凍結政策)→ CLEAN" "$?" 0
check "K1-N2 symlink 計為 symlinks=1" "$(grep -cE '^summary files=2 dirs=4 symlinks=1 special=0 excluded=0 errors=0 matches=0 status=CLEAN$' "$d/scan.out")" 1
rm -f "$T2/lnk" "$d/outside-secret"
scan2 "$T2/missing" > "$d/scan.out" 2>&1; check "K1-N2 不存在的根 → INCOMPLETE_SCAN(error),絕不 CLEAN" "$?" 1
printf '' | env FAKE_DIR="$d" "$K1CTX" scan-secrets "$T2" > "$d/scan.out" 2>&1; check "K1-N2 沒有 sentinel → 2(拒絕,不是 CLEAN)" "$?" 2
printf '%s\n' "$SENT" | env FAKE_DIR="$d" "$K1CTX" scan-secrets "relative/root" > "$d/scan.out" 2>&1; check "K1-N2 相對根路徑 → 2" "$?" 2
# 所有路徑被走訪:summary 的 files / dirs 與 find 的計數一致(find 只是 harness 的對照計數,不是 oracle)
scan2 "$T2" > "$d/scan.out" 2>&1
check "K1-N2 完整性:summary files/dirs == find 的 -type f / -type d 計數" \
    "$(sed -n 's/^summary files=\([0-9]*\) dirs=\([0-9]*\).*/\1|\2/p' "$d/scan.out")" "$(find "$T2" -type f | wc -l | tr -d ' ')|$(find "$T2" -type d | wc -l | tr -d ' ')"
check "K1-N2 靜態:掃描器以 errors 計數決定狀態,且 opendir / readdir / stat / open / read / 深度 / 根目錄失敗都記為 ERROR(≥ 9 處,不吞)" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'if errors > 0 { return "INCOMPLETE_SCAN" }')|$([ "$(swift_code_lines "$K1N/K1Native.swift" | grep -c 'sum.errors += 1')" -ge 9 ] && echo ok)" "1|ok"

# ---- K1-N3 權限不依賴繼承的 umask(sol D4 / grok NIT2):k1ctx 在 umask 0200 / 0777 下建立的 marker 仍恰 0600(fchmod + fstat 複驗),
#      下一次 context-validate 通過;adapter 在呼叫端 umask 0277 下 bootstrap / cleanup 照常 ----
d="$(new_state)"; c3="$(mktemp -d "$d/c3.XXXXXXXX")"
( umask 0200; env FAKE_DIR="$d" "$K1CTX" context-init "$c3" ) >/dev/null 2>&1; green "K1-N3 umask 0200 下 context-init 0" $?
check "K1-N3 umask 0200 下 marker 仍為 0600(不是 0400)" "$(/usr/bin/stat -f %Mp%Lp "$c3/.aipet-kc-context")" 0600
( env FAKE_DIR="$d" "$K1CTX" context-validate "$c3" ) >/dev/null 2>&1; green "K1-N3 之後的 context-validate 0(不是 marker-invalid)" $?
rm -f "$c3/.aipet-kc-context"
( umask 0777; env FAKE_DIR="$d" "$K1CTX" context-init "$c3" ) >/dev/null 2>&1; green "K1-N3 umask 0777 下 context-init 0" $?
check "K1-N3 umask 0777 下 marker 仍為 0600" "$(/usr/bin/stat -f %Mp%Lp "$c3/.aipet-kc-context")" 0600
( umask 0777; printf 'AAAA' | env FAKE_DIR="$d" "$K1CTX" write-p12 "$c3" ) >/dev/null 2>&1; green "K1-N3 umask 0777 下 write-p12 0" $?
check "K1-N3 umask 0777 下 p12.tmp 仍為 0600" "$(/usr/bin/stat -f %Mp%Lp "$c3/p12.tmp")" 0600
( env FAKE_DIR="$d" "$K1CTX" remove-p12 "$c3" ) >/dev/null 2>&1; rm -f "$c3/.aipet-kc-context"; rmdir "$c3"
ctx="$(new_ctx "$d")"
( cd "$d" && env TMPDIR="$d/kctmp" DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'umask 0277; source "$2"; kc_bootstrap "$1"; b=$?; kc_cleanup "$1"; echo "RCS=$b/$?"' _ "$ctx" "$KCB" ) >"$d/um.out" 2>&1
check "K1-N3 呼叫端 umask 0277:bootstrap 0、cleanup 0、context 消失、解碼 P12 曾為 0600" "$(cntF "$d/um.out" 'RCS=0/0')|$(gone "$ctx")|$(cat "$d/import.seen")" "1|gone|$ctx/p12.tmp${TABC}0600"

# ---- K1-N4 秘密不進任何子行程的環境(sol D2):fake security 記錄其環境中出現的秘密變數「名稱」→ 整個 bootstrap / cleanup /
#      preflight 期間都不得出現;呼叫端把秘密設為 readonly(無法 unset)→ bootstrap 2 / cleanup 1,零副作用 ----
d="$(new_state)"
( env FAKE_DIR="$d" DEVELOPER_ID_P12_BASE64=positive-control-not-a-secret PATH="$TMP/bin:$PATH" security find-identity -v -p codesigning "$KC_DEV" ) >/dev/null 2>&1
check "K1-N4 positive control(非虛綠):fake security 確實會記錄環境中的秘密變數名稱" "$(cat "$d/env.seen" 2>/dev/null)" "DEVELOPER_ID_P12_BASE64"
d="$(new_state)"; ctx="$(new_ctx "$d")"
( cd "$d" && env TMPDIR="$d/kctmp" DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'source "$2"; kc_bootstrap "$1"; b=$?; kc_cleanup "$1"; c=$?; echo "RCS=$b/$c"; echo "STILL=${DEVELOPER_ID_P12_BASE64:+set}${SIGNING_KEYCHAIN_PASSWORD:+set}"' _ "$ctx" "$KCB" ) >"$d/n4.out" 2>&1
check "K1-N4 export 秘密的呼叫端:bootstrap 0、cleanup 0;所有 security 子行程(≥ 7 次)的環境都沒有秘密變數;呼叫端自己的變數不受影響" \
    "$(cntF "$d/n4.out" 'RCS=0/0')|$(gone "$d/env.seen")|$([ "$(cntE "$d/security.log" '^(create-keychain|import|delete-keychain)')" -ge 3 ] && echo ok)|$(cntF "$d/n4.out" 'STILL=setset')" "1|gone|ok|1"
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" DEVELOPER_ID_P12_BASE64="leaked-if-seen" SIGNING_KEYCHAIN_PASSWORD="leaked-if-seen"; green "K1-N4 build-app validate(preflight)在 export 秘密的環境下 0" $?
check "K1-N4 preflight 路徑的 security 子行程環境也沒有秘密變數" "$(gone "$d/env.seen")|$(cntE "$d/security.log" '^find-')" "gone|2"
d="$(new_state)"; ctx="$(new_ctx "$d")"
( cd "$d" && env TMPDIR="$d/kctmp" DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'readonly DEVELOPER_ID_P12_BASE64; source "$2"; kc_bootstrap "$1"; echo "RC=$?"' _ "$ctx" "$KCB" ) >"$d/ro.out" 2>&1
check "K1-N4 呼叫端把秘密設為 readonly(無法從子行程環境移除)→ bootstrap 2 secret-env、context 未被寫入、零 security 呼叫" \
    "$(cntF "$d/ro.out" 'RC=2')|$(cntF "$d/ro.out" 'REJECTED: secret-env')|$(ents "$ctx")|$(gone "$d/security.log")" "1|1||gone"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-N4 前置:正常 bootstrap 0" $?
( cd "$d" && env SIGNING_KEYCHAIN_PASSWORD="$KCPW" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'readonly SIGNING_KEYCHAIN_PASSWORD; source "$2"; kc_cleanup "$1"; echo "RC=$?"' _ "$ctx" "$KCB" ) >"$d/ro2.out" 2>&1
check "K1-N4 cleanup 遇到 readonly 秘密 → 1 secret-env、零動作(context 原封不動、無 delete-keychain)" \
    "$(cntF "$d/ro2.out" 'RC=1')|$(cntF "$d/ro2.out" 'CLEANUP_FAILED: secret-env')|$(ents "$ctx")|$(cntE "$d/security.log" '^delete-keychain')" "1|1|$OK_ENTRIES|0"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-N4 收尾 cleanup 0" $?

# ---- K1-N4b 呼叫端 set -a(allexport)+ 預先 export 的別名名稱(sol attempt-002 C-F1;owner R1–R3):作用域先關 allexport、別名去
#      export、正式名稱 unset;以「值的 SHA-256」稽核整個 bootstrap / cleanup 期間「每個」子行程(security、k1ctx、sed、tr)的「每個」
#      環境變數 —— 三個秘密值以任何名稱都不得出現;bootstrap / cleanup 照常成功;呼叫端的 allexport 狀態、秘密變數、別名與其 export
#      屬性在呼叫後完全不變 ----
# 三個秘密值的 SHA-256(雜湊不是秘密;BSD awk 的 -v 不接受含換行的值,故經檔案傳入)。
SECRET_HASHES="$TMP/secret-hashes.txt"
for v in "$P12_GOOD_B64" "$P12PW" "$KCPW"; do printf '%s' "$v" | /usr/bin/shasum -a 256 | cut -c1-64; done > "$SECRET_HASHES"
check "K1-N4b 前提:三個秘密值的 SHA-256 已備妥(3 行 64 hex)" "$(grep -cE '^[0-9a-f]{64}$' "$SECRET_HASHES")" 3
audit_hits() { awk -F'\t' 'NR==FNR{if ($0!="") h[$0]=1; next} ($3 in h){print $1" "$2}' "$2" "$1/env.audit" 2>/dev/null; }
audit_invocations() { awk -F'\t' '$2=="@invocation"{n[$1]++} END{printf "security=%d k1ctx=%d sed=%d tr=%d\n", n["security"], n["k1ctx"], n["sed"], n["tr"]}' "$1/env.audit" 2>/dev/null; }
# positive control(非虛綠):一個「沒有 K1 作用域」的 set -a shell 把秘密放進別名 p12pw 與正式名稱 → security / tr / sed / k1ctx 的稽核都以值命中
d="$(new_state)"
( cd "$d" && env FAKE_ENV_AUDIT=1 FAKE_DIR="$d" PATH="$TMP/auditbin:$TMP/bin:$PATH" bash -c 'set -a; p12pw="$1"; SIGNING_KEYCHAIN_PASSWORD="$2"
    security find-identity -v -p codesigning "$3" >/dev/null 2>&1; printf x | tr x y >/dev/null; printf x | sed -n p >/dev/null; "$4" context-validate /nonexistent-k1-audit >/dev/null 2>&1' \
    _ "$P12PW" "$KCPW" "$KC_DEV" "$TMP/auditbin/k1ctx-audit" )
check "K1-N4b positive control:稽核以「值」命中 set -a 下的別名 p12pw 與正式名稱(security / tr / sed / k1ctx 四種子行程都命中)" \
    "$(audit_hits "$d" "$SECRET_HASHES" | sort -u | tr '\n' ' ')" "k1ctx SIGNING_KEYCHAIN_PASSWORD k1ctx p12pw security SIGNING_KEYCHAIN_PASSWORD security p12pw sed SIGNING_KEYCHAIN_PASSWORD sed p12pw tr SIGNING_KEYCHAIN_PASSWORD tr p12pw "
check "K1-N4b positive control:名稱 oracle(env.seen)也命中別名與正式名稱" "$(sort -u "$d/env.seen" | tr '\n' ' ')" "SIGNING_KEYCHAIN_PASSWORD p12pw "
d="$(new_state)"; ctx="$(new_ctx "$d")"
( cd "$d" && env TMPDIR="$d/kctmp" DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_ENV_AUDIT=1 K1CTX_BIN="$TMP/auditbin/k1ctx-audit" FAKE_DIR="$d" PATH="$TMP/auditbin:$TMP/bin:$PATH" \
    bash -c 'set -a; p12b64=caller-alias; kcpw=caller-alias; export p12pw; source "$2"; a0=$-
        kc_bootstrap "$1"; b=$?; kc_cleanup "$1"; c=$?; a1=$-
        echo "RCS=$b/$c"; echo "ALLEXPORT=$([[ $a0 == *a* ]] && echo on || echo off)/$([[ $a1 == *a* ]] && echo on || echo off)"
        echo "STILL=${DEVELOPER_ID_P12_BASE64:+set}${DEVELOPER_ID_P12_PASSWORD:+set}${SIGNING_KEYCHAIN_PASSWORD:+set}"
        echo "ALIAS=$p12b64/$kcpw/$(declare -p p12b64 kcpw p12pw 2>/dev/null | grep -c "^declare -x ")"' _ "$ctx" "$KCB" ) >"$d/n4b.out" 2>&1
# (declare -p 不列出「已 export 但未設值」的 p12pw,故 export 屬性計數為 2:p12b64 與 kcpw。)
check "K1-N4b set -a 呼叫端:bootstrap 0、cleanup 0;呼叫端 allexport 前後皆 on;呼叫端的秘密變數、別名值與別名 export 屬性原封不動" \
    "$(cntF "$d/n4b.out" 'RCS=0/0')|$(cntF "$d/n4b.out" 'ALLEXPORT=on/on')|$(cntF "$d/n4b.out" 'STILL=setsetset')|$(cntF "$d/n4b.out" 'ALIAS=caller-alias/caller-alias/2')" "1|1|1|1"
check "K1-N4b 稽核涵蓋每一種子行程(非虛綠):security ≥ 8、k1ctx ≥ 7、sed ≥ 2、tr ≥ 2 次呼叫" \
    "$(audit_invocations "$d" | awk '{s=$1; k=$2; e=$3; t=$4; sub(/.*=/,"",s); sub(/.*=/,"",k); sub(/.*=/,"",e); sub(/.*=/,"",t); print (s+0>=8 && k+0>=7 && e+0>=2 && t+0>=2) ? "ok" : $0}')" ok
check "K1-N4b 任何子行程的任何環境變數都不含三個秘密值(SHA-256 比對 = 0 命中);正式名稱與別名名稱也都不出現;env.seen 不存在" \
    "$(audit_hits "$d" "$SECRET_HASHES" | wc -l | tr -d ' ')|$(cut -f2 "$d/env.audit" | grep -cxE 'DEVELOPER_ID_P12_BASE64|DEVELOPER_ID_P12_PASSWORD|SIGNING_KEYCHAIN_PASSWORD|p12b64|p12pw|kcpw')|$(gone "$d/env.seen")" "0|0|gone"
check "K1-N4b context 消失、解碼 P12 曾為 0600(整個流程真的跑完)" "$(gone "$ctx")|$(cat "$d/import.seen")" "gone|$ctx/p12.tmp${TABC}0600"
# SHELLOPTS=allexport 從環境帶入(另一種讓 subshell 以 allexport 啟動的途徑)→ 同樣被作用域關掉
d="$(new_state)"; ctx="$(new_ctx "$d")"
( cd "$d" && env SHELLOPTS=allexport TMPDIR="$d/kctmp" DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_ENV_AUDIT=1 K1CTX_BIN="$TMP/auditbin/k1ctx-audit" FAKE_DIR="$d" PATH="$TMP/auditbin:$TMP/bin:$PATH" \
    bash -c 'echo "A0=$([[ $- == *a* ]] && echo on || echo off)"; source "$2"; kc_bootstrap "$1"; b=$?; kc_cleanup "$1"; echo "RCS=$b/$?"' _ "$ctx" "$KCB" ) >"$d/n4b2.out" 2>&1
check "K1-N4b SHELLOPTS=allexport 呼叫端(前提:allexport 確實已開):bootstrap 0、cleanup 0、稽核零命中" \
    "$(cntF "$d/n4b2.out" 'A0=on')|$(cntF "$d/n4b2.out" 'RCS=0/0')|$(audit_hits "$d" "$SECRET_HASHES" | wc -l | tr -d ' ')" "1|1|0"
# 呼叫端把別名設為 readonly(secret 複製不可能)→ bootstrap 2 secret-env、零副作用;cleanup 不需要別名 → 照常
d="$(new_state)"; ctx="$(new_ctx "$d")"
( cd "$d" && env TMPDIR="$d/kctmp" DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'p12pw=caller; readonly p12pw; source "$2"; kc_bootstrap "$1"; echo "RC=$?"' _ "$ctx" "$KCB" ) >"$d/n4b3.out" 2>&1
check "K1-N4b 呼叫端 readonly 別名 → bootstrap 2 secret-env、context 未被寫入、零 security 呼叫" \
    "$(cntF "$d/n4b3.out" 'RC=2')|$(cntF "$d/n4b3.out" 'REJECTED: secret-env')|$(ents "$ctx")|$(gone "$d/security.log")" "1|1||gone"

# ---- K1-N4c 公開的 kc_normalize_sha256(build-app.sh verify_signature 直接呼叫)(sol attempt-002 C-F2;owner R4):它自己就是秘密
#      作用域(先 scrub),且正規化純 builtin —— 在 export 秘密 + set -a 的呼叫端下,稽核 shim 看不到任何子行程;K6 契約逐向量不變 ----
d="$(new_state)"
( cd "$d" && env DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" FAKE_ENV_AUDIT=1 FAKE_DIR="$d" PATH="$TMP/auditbin:$TMP/bin:$PATH" \
    bash -c 'set -a; source "$1"; kc_normalize_sha256 "$2"; echo "RC=$?"; echo "A=$([[ $- == *a* ]] && echo on || echo off)"' _ "$KCB" "$DEV_SHA256_UPPER" ) >"$d/n4c.out" 2>&1
check "K1-N4c export 秘密 + set -a 的呼叫端:大寫 → 小寫、rc 0、呼叫端 allexport 不變" "$(cntF "$d/n4c.out" "$DEV_SHA256")|$(cntF "$d/n4c.out" 'RC=0')|$(cntF "$d/n4c.out" 'A=on')" "1|1|1"
check "K1-N4c 正規化不產生任何子行程(稽核 shim 零記錄;前提:同一 PATH 下的 tr 確實會被稽核 — 見 positive control)" "$(gone "$d/env.audit")" gone
( cd "$d" && env FAKE_ENV_AUDIT=1 FAKE_DIR="$d" PATH="$TMP/auditbin:$TMP/bin:$PATH" bash -c 'printf x | tr x y >/dev/null' )
check "K1-N4c positive control:同一 PATH 下直接呼叫 tr 會留下稽核記錄" "$(cntF "$d/env.audit" "tr${TABC}@invocation")" 1
# K6 契約(直接呼叫):10 個壞向量拒絕且 stdout 為空;大寫 / 混合大小寫 / 小寫 → 小寫;輸出恰 64 小寫 hex + 換行
i=0
while [ "$i" -lt "${#SHA_BAD_VALUES[@]}" ]; do
    ( bash -c 'source "$1"; kc_normalize_sha256 "$2"' _ "$KCB" "${SHA_BAD_VALUES[$i]}" ) >"$d/nz.out" 2>&1; red "K1-N4c 直接契約:拒絕 ${SHA_BAD_LABELS[$i]}" $?
    check "K1-N4c 拒絕時 stdout 為空:${SHA_BAD_LABELS[$i]}" "$(wc -c < "$d/nz.out" | tr -d ' ')" 0
    i=$((i + 1))
done
for nz_case in "大寫|$DEV_SHA256_UPPER" "混合大小寫|${DEV_SHA256_UPPER:0:32}${DEV_SHA256:32}" "小寫|$DEV_SHA256"; do
    nz_name="${nz_case%%|*}"; nz_val="${nz_case#*|}"
    check "K1-N4c 直接契約:$nz_name → 小寫 64 hex(+ 換行)" "$(bash -c 'source "$1"; kc_normalize_sha256 "$2"' _ "$KCB" "$nz_val" | od -An -c | tr -s ' \n' ' ' | tail -c 4 | tr -d ' ')|$(bash -c 'source "$1"; kc_normalize_sha256 "$2"' _ "$KCB" "$nz_val")" "\\n|$DEV_SHA256"
done
check "K1-N4c 靜態:kc_normalize_sha256 本體沒有任何外部工具(tr / sed / awk / cut / grep / base64 / openssl / perl / python)、沒有管線進外部工具,且先 _kc_scrub_secrets" \
    "$(awk '/^kc_normalize_sha256\(\) \(/{f=1} f{print} f&&/^\)/{exit}' "$KCB" | code_lines /dev/stdin | grep -cE '(^|[[:space:];|&(])(/usr/bin/)?(tr|sed|awk|cut|grep|base64|openssl|perl|python3?|shasum|xargs)([[:space:]]|$)')|$(awk '/^kc_normalize_sha256\(\) \(/{f=1} f{print} f&&/^\)/{exit}' "$KCB" | grep -cF '_kc_scrub_secrets ||')" "0|1"

# ---- K1-N5 掃描器的根 / 排除路徑必須是絕對正規路徑(sol D1):非正規拼法的根配上同前綴的排除 → 2 scan-args(絕非 CLEAN);
#      正規拼法下確實找到 sentinel;根在排除子樹內 → excluded ----
d="$(new_state)"; T5="$d/tree"; mkdir -p "$T5/excluded" "$T5/intended"; printf '%s\n' "$SENT" > "$T5/intended/leak"
printf '%s\n' "$SENT" | env FAKE_DIR="$d" "$K1CTX" scan-secrets --exclude "$T5/excluded" "$T5/excluded/../intended" > "$d/n5.out" 2>&1; check "K1-N5 sol D1 情境(根含 '..')→ 2 scan-args,不是 CLEAN" "$?" 2
check "K1-N5 訊息 token=scan-args、無 summary(未掃描)" "$(cntF "$d/n5.out" 'token=scan-args')|$(cntF "$d/n5.out" 'summary ')" "1|0"
printf '%s\n' "$SENT" | env FAKE_DIR="$d" "$K1CTX" scan-secrets --exclude "$T5/excluded/" "$T5/intended" > "$d/n5.out" 2>&1; check "K1-N5 排除路徑結尾 '/' → 2 scan-args" "$?" 2
printf '%s\n' "$SENT" | env FAKE_DIR="$d" "$K1CTX" scan-secrets --exclude "$T5/excluded" "$T5/intended" > "$d/n5.out" 2>&1; check "K1-N5 正規拼法:同一棵樹確實 SECRET_FOUND(2)" "$?" 2
check "K1-N5 正規拼法:MATCH leak、status=SECRET_FOUND" "$(grep -cxF "MATCH $T5/intended/leak" "$d/n5.out")|$(grep -cE 'status=SECRET_FOUND$' "$d/n5.out")" "1|1"
mkdir -p "$T5/excluded/sub"; printf '%s\n' "$SENT" > "$T5/excluded/sub/leak"
printf '%s\n' "$SENT" | env FAKE_DIR="$d" "$K1CTX" scan-secrets --exclude "$T5/excluded" "$T5/excluded/sub" > "$d/n5.out" 2>&1; check "K1-N5 根在排除子樹內 → CLEAN(0)、excluded=1、未開啟" "$?" 0
check "K1-N5 根在排除子樹內:summary dirs=0 excluded=1" "$(grep -cE '^summary files=0 dirs=0 symlinks=0 special=0 excluded=1 errors=0 matches=0 status=CLEAN$' "$d/n5.out")" 1
printf '%s\n' "$SENT" | env FAKE_DIR="$d" "$K1CTX" scan-secrets --exclude "$T5/intend" "$T5/intended" > "$d/n5.out" 2>&1; check "K1-N5 排除只在路徑成分邊界比對('/intend' 不排除 '/intended')→ SECRET_FOUND(2)" "$?" 2
rm -rf "$T5"   # 含 sentinel 的 fixture 樹,用完即移除(K1-S8 的全 harness 掃描只允許 $FIX / $CTL 內有 sentinel)

# ---- K1-S1 source 安全(K12)與敵意呼叫端選項 ----
d="$(new_state)"
( cd "$d" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c '
    b=""; bv=""; a=""; av=""; c=""; rc=0
    set -euo pipefail; set -o noclobber; shopt -s nullglob failglob nocasematch; umask 027
    trap "echo caller-err-trap >&2" ERR
    snap() { set -o; shopt; umask; trap -p; }
    b="$(snap)"; bv="$(compgen -v | LC_ALL=C sort)"
    source "$1"
    a="$(snap)"; av="$(compgen -v | LC_ALL=C sort)"
    [ "$b" = "$a" ] && echo SOURCE_STATE_UNCHANGED
    [ "$bv" = "$av" ] && echo SOURCE_NO_NEW_VARS
    kc_cleanup "/nonexistent-k1-ctx" 2>/dev/null || rc=$?
    echo "CLEANUP_RC=$rc"
    c="$(snap)"; [ "$b" = "$c" ] && echo CALL_STATE_UNCHANGED
    echo DONE
' _ "$KCB" ) > "$d/src.out" 2>&1
check "K1-S1 source 不改呼叫端的 set / shopt / umask / trap" "$(cntF "$d/src.out" SOURCE_STATE_UNCHANGED)" 1
check "K1-S1 source 不定義任何變數" "$(cntF "$d/src.out" SOURCE_NO_NEW_VARS)" 1
check "K1-S1 呼叫後呼叫端狀態仍不變" "$(cntF "$d/src.out" CALL_STATE_UNCHANGED)" 1
check "K1-S1 呼叫端 set -e 下退出碼契約不變(3)" "$(cntF "$d/src.out" CLEANUP_RC=3)" 1
check "K1-S1 正常走完(非提早中止)" "$(cntF "$d/src.out" DONE)" 1
d="$(new_state)"; ctx="$(new_ctx "$d")"
( cd "$d" && env TMPDIR="$d/kctmp" DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" \
    DEVELOPER_ID_IDENTITY="$DEVID" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c '
    brc=0; crc=0
    set -euo pipefail; set -E; trap "echo CALLER_ERR_TRAP_FIRED >&2" ERR
    shopt -s failglob nullglob nocasematch dotglob; IFS=:; umask 000
    source "$1"
    set -x
    kc_bootstrap "$2" || brc=$?
    kc_cleanup "$2" || crc=$?
    set +x
    echo "BOOT_RC=$brc CLEAN_RC=$crc" >&2
' _ "$KCB" "$ctx" ) > "$d/x.out" 2> "$d/x.err"
check "K1-S1 敵意呼叫端(set -euo pipefail / -E + ERR trap / failglob / nullglob / nocasematch / IFS / umask 000 / set -x)→ bootstrap 0、cleanup 0" "$(cntF "$d/x.err" 'BOOT_RC=0 CLEAN_RC=0')" 1
check "K1-S1 呼叫端的 ERR trap 從未在 adapter 內觸發" "$(cntF "$d/x.err" CALLER_ERR_TRAP_FIRED)" 0
check "K1-S1 xtrace 確實開著(非虛綠:有 '+ kc_bootstrap' 追蹤行)" "$(cntF "$d/x.err" '+ kc_bootstrap')" 1
check "K1-S1 xtrace 不含任何秘密(sentinel)、不含 base64 P12" "$(cntF "$d/x.err" "$SENT")|$(cntF "$d/x.err" "$P12_GOOD_B64")" "0|0"
check "K1-S1 呼叫端 umask 000 不影響 k1ctx 的檔案權限(解碼 P12 仍為 0600)" "$(cat "$d/import.seen")" "$ctx/p12.tmp${TABC}0600"
check "K1-S1 cleanup 後 context 消失" "$(gone "$ctx")" gone
# 呼叫端 set -e 且以「普通命令」呼叫(非 if / || / && 語境 —— 那些語境 bash 本身就會停用 errexit,測不到 adapter 的隔離):
# errexit 會被帶進 adapter 的 subshell;adapter 必須自己 set +e,否則中途某個預期會非零的命令會讓它以錯誤的退出碼提早結束。
d="$(new_state)"; ctx="$(new_ctx "$d")"
plain_e() { # $1=函式 $2=context ;呼叫端 set -euo pipefail + 普通命令呼叫
    ( cd "$d" && env DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" \
        DEVELOPER_ID_IDENTITY="$DEVID" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'set -euo pipefail; source "$1"; "$2" "$3"' _ "$KCB" "$1" "$2" ) >/dev/null 2>&1
}
plain_e kc_bootstrap "$ctx"; check "K1-S1 呼叫端 set -e(普通命令)→ bootstrap 0" "$?" 0
plain_e kc_cleanup "$ctx"; check "K1-S1 呼叫端 set -e(普通命令)→ cleanup 0(未被 errexit 提早中止)" "$?" 0
check "K1-S1 呼叫端 set -e:cleanup 確實完成(context 消失)" "$(gone "$ctx")" gone
plain_e kc_cleanup "$ctx"; check "K1-S1 呼叫端 set -e:不存在 → 3" "$?" 3
mkdir -m 700 "$d/plainarb"; printf 'x' > "$d/plainarb/f"
plain_e kc_cleanup "$d/plainarb"; check "K1-S1 呼叫端 set -e:任意目錄 → 2(非 errexit 造成的 1)" "$?" 2
# 工具缺失 / 無效的 K1CTX_BIN:bootstrap → 2(零副作用)、cleanup → 1(零動作);沒有任何 shell fallback 去自行處理 context
d="$(new_state)"; ctx="$(new_ctx "$d")"
for tool_case in "空|" "相對路徑|k1ctx" "不存在|$TMP/no-such-k1ctx" "是目錄|$TMP/bin" "symlink|$TMP/k1ctx-link"; do
    tc_name="${tool_case%%|*}"; tc_val="${tool_case#*|}"
    [ "$tc_name" = symlink ] && ln -sf "$K1CTX" "$TMP/k1ctx-link"
    drive_kc "$d" kc_bootstrap "$ctx" K1CTX_BIN="$tc_val"; check "K1-S1 K1CTX_BIN $tc_name → bootstrap 2" "$?" 2
    check "K1-S1 K1CTX_BIN $tc_name:訊息 tool-missing;context 未被寫入;零 security 呼叫" "$(cntF "$d/kc.err" 'REJECTED: tool-missing')|$(ents "$ctx")|$(gone "$d/security.log")" "1||gone"
done
rm -f "$TMP/k1ctx-link"
drive_kc "$d" kc_bootstrap "$ctx"; green "K1-S1 前置:有效工具 bootstrap 0" $?
drive_kc "$d" kc_cleanup "$ctx" K1CTX_BIN=""; check "K1-S1 cleanup 無 K1CTX_BIN → 1(作業失敗,零動作;不以 shell 自行清理)" "$?" 1
check "K1-S1 cleanup tool-missing:context 原封不動、零 delete-keychain" "$(cntF "$d/kc.err" 'CLEANUP_FAILED: tool-missing')|$(ents "$ctx")|$(cntE "$d/security.log" '^delete-keychain')" "1|$OK_ENTRIES|0"
drive_kc "$d" kc_cleanup "$ctx"; green "K1-S1 收尾:cleanup 0" $?

# ---- K1-S2 直接執行(source-guard 分派)----
d="$(new_state)"; ctx="$(new_ctx "$d")"
( cd "$d" && env DEVELOPER_ID_P12_BASE64="$P12_GOOD_B64" DEVELOPER_ID_P12_PASSWORD="$P12PW" SIGNING_KEYCHAIN_PASSWORD="$KCPW" DEVELOPER_ID_IDENTITY="$DEVID" \
    FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash "$KCB" bootstrap "$ctx" ) >"$d/kc.out" 2>"$d/kc.err"; green "K1-S2 直接執行 bootstrap 0" $?
( cd "$d" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash "$KCB" cleanup "$ctx" ) >/dev/null 2>&1; green "K1-S2 直接執行 cleanup 0" $?
( cd "$d" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash "$KCB" cleanup "$ctx" ) >/dev/null 2>&1; check "K1-S2 直接執行 cleanup(已不存在)→ 3" "$?" 3
( cd "$d" && bash "$KCB" ) >/dev/null 2>&1; check "K1-S2 無參數 → 2(usage)" "$?" 2
( cd "$d" && bash "$KCB" bootstrap "$ctx" extra ) >/dev/null 2>&1; check "K1-S2 多餘參數 → 2" "$?" 2
( cd "$d" && bash "$KCB" frobnicate "$ctx" ) >/dev/null 2>&1; check "K1-S2 未知子命令 → 2" "$?" 2
( cd "$d" && "$K1CTX" ) >/dev/null 2>&1; check "K1-S2 k1ctx 無參數 → 2(usage)" "$?" 2
( cd "$d" && "$K1CTX" frobnicate "$ctx" ) >/dev/null 2>&1; check "K1-S2 k1ctx 未知子命令 → 2" "$?" 2
( cd "$d" && "$K1CTX" context-validate "$ctx" extra ) >/dev/null 2>&1; check "K1-S2 k1ctx 多餘參數 → 2" "$?" 2

# ---- K1-S3 植入的 symlink 不會被跟隨覆寫(K4)----
d="$(new_state)"; ctx="$(new_ctx "$d")"; printf 'VICTIM-ORIGINAL\n' > "$d/victim.txt"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_SEC_FAIL=plant-p12-symlink FAKE_PLANT_TARGET="$d/victim.txt"; check "K1-S3 p12.tmp 被植入 symlink → 1" "$?" 1
check "K1-S3 訊息 entry-type(k1ctx 在寫入前的白名單型別檢查);受害檔不變;不曾 import" "$(cntF "$d/kc.err" 'FAILED: entry-type')|$(cat "$d/victim.txt")|$(cntE "$d/security.log" '^import')" "1|VICTIM-ORIGINAL|0"
drive_kc "$d" kc_cleanup "$ctx"; check "K1-S3 被竄改的 context(含 symlink)→ cleanup 2(不跟隨)" "$?" 2
check "K1-S3 cleanup 訊息 entry-type;受害檔不變" "$(cntF "$d/kc.err" 'CONTEXT_REJECTED: entry-type')|$(cat "$d/victim.txt")" "1|VICTIM-ORIGINAL"
rm -f "$ctx/p12.tmp"; drive_kc "$d" kc_cleanup "$ctx"; green "K1-S3 移除植入物後 cleanup 0" $?
d="$(new_state)"; ctx="$(new_ctx "$d")"
drive_kc "$d" kc_bootstrap "$ctx" FAKE_SEC_FAIL=plant-p12-symlink FAKE_PLANT_TARGET="$d/would-be-created"; check "K1-S3 dangling symlink → 1" "$?" 1
check "K1-S3 dangling 目標未被建立" "$(gone "$d/would-be-created")" gone
rm -f "$ctx/p12.tmp"; drive_kc "$d" kc_cleanup "$ctx"; green "K1-S3 dangling 收尾 cleanup 0" $?

# ---- K1-S4 adhoc 行為不變(不讀 K1 輸入、不呼叫 security、不帶 --keychain)----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=adhoc DEVELOPER_ID_KEYCHAIN="/nonexistent/x" EXPECTED_DEVELOPER_ID_CERT_SHA256=garbage; green "K1-S4 adhoc 忽略 K1 輸入 → 0" $?
check "K1-S4 adhoc 零 security 呼叫;codesign 恰兩次 ad-hoc、無 --keychain" "$(gone "$d/security.log")|$(cntF "$d/codesign.log" '--force --sign - ')|$(cntF "$d/codesign.log" '--keychain')" "gone|2|0"
d="$(new_state)"; drive_validate "$d" SIGN_MODE=adhoc DEVELOPER_ID_KEYCHAIN="" EXPECTED_DEVELOPER_ID_CERT_SHA256=""; green "K1-S4 adhoc validate 不要求 K1 輸入 → 0" $?

# ---- K1-S5 Team 推導兩份實作一致(build-app.sh _expected_team_id ↔ adapter _kc_team_of)----
for tid in "$DEVID" "$EVID" "$NOTEAM" "$SHORTID" "$APPLEDEV" "Developer ID Application: A (B) (TEAM123456)" \
    "Developer ID Application: X (TEAM123456)  " "Developer ID Application: X (TEAM-12345)" "Developer ID Application: X (TEAM123456) Old"; do
    t_build="$(DEVELOPER_ID_IDENTITY="$tid" bash -c 'source "$1"; _expected_team_id' _ "$BUILD" 2>/dev/null)"
    t_kc="$(bash -c 'source "$1"; _kc_team_of "$2"' _ "$KCB" "$tid" 2>/dev/null)"
    check "K1-S5 Team 推導一致:'$tid'" "$t_kc" "$t_build"
done

# ---- K1-S6 靜態:K2 / K4 / K10 / K13 邊界與 shell / native 責任分割(只看非註解程式碼)----
check "K1-S6 adapter 無任何 search-list / default / login keychain 子命令(K2)" "$(code_lines "$KCB" | grep -cE 'list-keychains|default-keychain|login-keychain')" 0
check "K1-S6 build-app.sh 無任何 search-list / default / login keychain 子命令(K2)" "$(code_lines "$BUILD" | grep -cE 'list-keychains|default-keychain|login-keychain')" 0
check "K1-S6 adapter 無 set -x / xtrace(K4)" "$(code_lines "$KCB" | grep -cE 'set -[A-Za-z]*x|xtrace')" 0
check "K1-S6 adapter 無 here-doc / here-string(不在 context 外產生暫存檔)" "$(code_lines "$KCB" | grep -cF '<<')" 0
check "K1-S6 adapter 無任何 rm / rmdir / 遞迴刪除(K10:刪除只在 k1ctx 與 Apple delete-keychain)" "$(code_lines "$KCB" | grep -cE '(^|[[:space:];|&(])(/bin/)?rm(dir)?[[:space:]]')" 0
check "K1-S6 adapter 的 trap 全是「清除」呼叫端帶入 subshell 的 DEBUG / ERR / RETURN(每個公開函式一次;K13:不安裝任何 trap)" \
    "$(code_lines "$KCB" | grep -cE '(^|[{;[:space:]])trap[[:space:]]')|$(code_lines "$KCB" | grep -cxF '    { trap - DEBUG ERR RETURN; set +x +v +T +E; } >/dev/null 2>&1')" "4|4"
check "K1-S6 adapter 不處理 EXIT / INT / TERM / HUP(K13)" "$(code_lines "$KCB" | grep -cwE 'EXIT|INT|TERM|HUP')" 0
check "K1-S6 adapter 頂層沒有 set / shopt / umask(K12)" "$(grep -cE '^(set|shopt|umask)[[:space:]]' "$KCB")" 0
check "K1-S6 adapter 無任何 shell glob 檔名展開(不含 \"\$var\"/*、/.[!.]*、/..?* 列舉樣式)" "$(code_lines "$KCB" | grep -cE '"\$[A-Za-z_0-9]+"/(\*|\.\[!\.\]\*|\.\.\?\*)')" 0
check "K1-S6 adapter 不碰 GLOBIGNORE(不 unset / 不改寫 / 不倚賴)" "$(code_lines "$KCB" | grep -c GLOBIGNORE)" 0
check "K1-S6 adapter 無任何「建立檔案」的 shell 重導向到變數路徑(marker / P12 一律經 k1ctx)" "$(code_lines "$KCB" | grep -cE '(^|[^0-9&])>[[:space:]]*"?\$')" 0
check "K1-S6 adapter 無 noclobber 設定" "$(code_lines "$KCB" | grep -cE 'set -C|noclobber')" 0
check "K1-S6 adapter 不落盤 SHA-1(F4:無 identity.sha1)" "$(grep -c 'identity\.sha1' "$KCB")" 0
check "K1-S6 adapter 不用 base64 / perl / python 等外部工具處理秘密(P12 只經 builtin printf → k1ctx)" "$(code_lines "$KCB" | grep -cE '(^|[[:space:];|&(])(/usr/bin/)?(base64|perl|python3?|openssl)[[:space:]]')" 0
check "K1-S6 build-app.sh 不自行處理 keychain 生命週期(無 create-keychain / delete-keychain / import)" "$(code_lines "$BUILD" | grep -cE 'create-keychain|delete-keychain|security import')" 0
# 原生工具的靜態不變式(N4 / N5 / N6 / N8 / N9)
check "K1-S6 k1ctx 只 import Darwin(無 Foundation、無任何其他模組)" "$(grep -hE '^import ' "$K1N/K1Native.swift" "$K1N/main.swift" | LC_ALL=C sort -u | tr '\n' ' ')" "import Darwin "
check "K1-S6 k1ctx 不呼叫 system / popen / exec(不產生子行程;不讀環境變數作為安全依據)" "$(swift_code_lines "$K1N/K1Native.swift" "$K1N/main.swift" | grep -cE '\b(system|popen|execv[pe]?|posix_spawn|getenv)\(')" 0
check "K1-S6 k1ctx context / 掃描根目錄以 O_DIRECTORY|O_NOFOLLOW 開啟(2 處),每個 open 之後都 fstat 同一 fd(context、marker、掃描檔、建立後複驗、keychain 路徑 = 5 處)" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'if fstat(fd, &st) != 0 {')" "2|5"
check "K1-S6 k1ctx marker / P12 建立一律 O_CREAT|O_EXCL|O_NOFOLLOW(2 處:marker、p12.tmp),且建立後 fchmod 0600 + fstat 複驗(ensureMode0600 ×2;sol D4)" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'if let why = ensureMode0600(fd) {')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'if fchmod(fd, 0o600) != 0 {')" "2|2|1"
check "K1-S6 adapter 在每個公開函式(bootstrap / cleanup / identity preflight / normalize_sha256)進入子行程前都移除三個秘密變數(sol D2)" \
    "$(code_lines "$KCB" | grep -cE '^[[:space:]]*_kc_scrub_secrets \|\|')|$(code_lines "$KCB" | grep -cF 'unset DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD SIGNING_KEYCHAIN_PASSWORD')" "4|1"
check "K1-S6 adapter 的秘密作用域(sol attempt-002 C-F1):_kc_isolate 以 builtin 關 allexport(+a);別名去 export(export -n p12b64 p12pw kcpw);allexport 複驗;bootstrap 在複製秘密之前先 _kc_unexport_aliases" \
    "$(code_lines "$KCB" | grep -cF 'set +e +u +f +E +T +a')|$(code_lines "$KCB" | grep -cF 'export -n p12b64 p12pw kcpw')|$(code_lines "$KCB" | grep -cF 'case "$-" in *a*) return 1 ;; esac')|$(code_lines "$KCB" | grep -n -E '_kc_unexport_aliases \|\||local p12b64=' | awk -F: 'NR==1{a=$1} NR==2{b=$1} END{print (a<b) ? "before" : "ORDER?"}')" "1|1|1|before"
check "K1-S6 k1ctx 路徑語法契約第一個判定就是 NUL 拒絕(context-nul;sol attempt-002 C-F3),且 removeMarkerAndContext 先驗 path" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -n -E 'if path.contains\(0\) \{ throw K1Error\(.rejected, "context-nul"|if path.isEmpty \{ throw K1Error\(.rejected, "context-empty"' | awk -F: 'NR==1{a=$1} NR==2{b=$1} END{print (a && b && a<b) ? "nul-first" : "ORDER?"}')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'public func removeMarkerAndContext(_ handle: ContextHandle, path: [UInt8], uid: uid_t) throws {')|$(swift_code_lines "$K1N/K1Native.swift" | grep -A1 -F 'public func removeMarkerAndContext(_ handle: ContextHandle, path: [UInt8], uid: uid_t) throws {' | grep -cF 'try checkContextPathSyntax(path)')" "nul-first|1|1"
check "K1-S6 k1ctx 白名單型別判定用 fstatat(AT_SYMLINK_NOFOLLOW);rmdir 用 unlinkat(AT_REMOVEDIR) 且先比對 dev:inode" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'fstatat(dirfd, $0, &st, AT_SYMLINK_NOFOLLOW)')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'unlinkat(parent, $0, AT_REMOVEDIR)')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'st.st_dev != handle.st.st_dev || st.st_ino != handle.st.st_ino')" "3|1|1"
check "K1-S6 k1ctx 列舉用 fdopendir(dup(fd)) + readdir,且 readdir 前 errno = 0(錯誤不吞)" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'fdopendir(dupfd)')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'errno = 0')" "1|1"
check "K1-S6 k1ctx 沒有 stat(path) 作為安全依據(lstat 只出現在 open 失敗的分類中)" "$(swift_code_lines "$K1N/K1Native.swift" | grep -cE '[^fl]stat\(\$0' )" 0
check "K1-S6 k1ctx 掃描不跟隨 symlink(目錄 openat O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK、檔案 openat O_NOFOLLOW|O_NONBLOCK;S_IFLNK 只計數)" \
    "$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'openat(dirfd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)')|$(swift_code_lines "$K1N/K1Native.swift" | grep -cF 'sum.symlinks += 1')" "1|1"
check "K1-S6 build.sh 只用 swiftc、不下載任何東西(無 curl / git / swift package)" "$(code_lines "$K1N/build.sh" | grep -cE 'curl|wget|git |swift package|brew ')" 0

# ---- K1-S7 彙總:全套件所有案例的 fake security 都沒有任何全域 search-list / default keychain 呼叫或 violation ----
CTL="$TMP/control"; mkdir -p "$CTL"
( env FAKE_DIR="$CTL" PATH="$TMP/bin:$PATH" security list-keychains -d user -s "$KC_DEV" ) >/dev/null 2>&1
check "K1-S7 positive control:fake 會把 list-keychains -s 記成 global-write violation(掃描能命中)" "$(cntF "$CTL/violations.log" 'global-write list-keychains')" 1
nlogs="$(ls "$TMP"/s.*/security.log 2>/dev/null | wc -l | tr -d ' ')"
check "K1-S7 掃描的 security.log ≥ 60 份(非空掃描)" "$([ "$nlogs" -ge 60 ] && echo ok || echo "only $nlogs")" ok
check "K1-S7 所有案例零 list-keychains / default-keychain / login-keychain 呼叫" "$(cat "$TMP"/s.*/security.log | grep -cE '^(list-keychains|default-keychain|login-keychain)( |$)')" 0
check "K1-S7 所有案例零 violation(全域讀寫、落到 default keychain、import -A、相對路徑)" "$(cat /dev/null "$TMP"/s.*/violations.log 2>/dev/null | wc -l | tr -d ' ')" 0

# ---- K1-S8 秘密衛生:以 k1ctx scan-secrets(原生、fail-closed)掃整個 harness —— sentinel / base64 P12 不出現在任何輸出、log、
#      殘留檔(verbatim;fixture 原檔與 positive control 以 --exclude 明確排除)。任何走訪錯誤都是 INCOMPLETE_SCAN,不是 CLEAN ----
printf '%s\n' "$P12_GOOD_B64" > "$CTL/b64-positive-control"
printf '%s\n%s\n' "$SENT" "$P12_GOOD_B64" > "$CTL/sentinels.txt"   # control 目錄本身被排除,不影響主掃描
# positive controls(掃描器會命中):fixture 內確實含 sentinel;control 檔含 base64
env FAKE_DIR="$CTL" "$K1CTX" scan-secrets "$FIX" < "$CTL/sentinels.txt" > "$CTL/scan-fix.out" 2>&1; check "K1-S8 positive control:fixture 目錄 → SECRET_FOUND(2)" "$?" 2
env FAKE_DIR="$CTL" "$K1CTX" scan-secrets "$CTL" < "$CTL/sentinels.txt" > "$CTL/scan-ctl.out" 2>&1; check "K1-S8 positive control:control 目錄(含 base64)→ SECRET_FOUND(2)" "$?" 2
check "K1-S8 positive control 命中 b64-positive-control" "$(grep -cxF "MATCH $CTL/b64-positive-control" "$CTL/scan-ctl.out")" 1
# NE 案刻意建立的 0000 權限 fixture 仍在:掃描必須 fail-closed(INCOMPLETE_SCAN),而不是靜默略過它當 CLEAN
if [ ! -r "$NEFX/unreadable.p8" ]; then
    env FAKE_DIR="$CTL" "$K1CTX" scan-secrets --exclude "$FIX" --exclude "$CTL" "$TMP" < "$CTL/sentinels.txt" > "$CTL/scan-incomplete.out" 2>&1
    check "K1-S8 有不可讀的檔時 → INCOMPLETE_SCAN(1),不是 CLEAN(F-N2 在 harness 層的證明)" "$?" 1
    check "K1-S8 ERROR 行指名 unreadable.p8" "$(grep -cxF "ERROR EACCES open $NEFX/unreadable.p8" "$CTL/scan-incomplete.out")" 1
    chmod u+r "$NEFX/unreadable.p8"
else
    printf 'SKIP: 0000 權限檔對目前使用者仍可讀(可能為 root)— 跳過 K1-S8 INCOMPLETE 證明\n'
fi
env FAKE_DIR="$CTL" "$K1CTX" scan-secrets --exclude "$FIX" --exclude "$CTL" "$TMP" < "$CTL/sentinels.txt" > "$CTL/scan-main.out" 2>&1; check "K1-S8 主掃描:sentinel / base64 P12 在 fixture 與 control 以外零出現、零走訪錯誤 → CLEAN(0)" "$?" 0
check "K1-S8 主掃描 status=CLEAN、errors=0、matches=0" "$(grep -cE '^summary .* errors=0 matches=0 status=CLEAN$' "$CTL/scan-main.out")" 1
grep -E '^(MATCH|ERROR) ' "$CTL/scan-main.out" | sed 's/^/K1-S8 diagnostic: /' | head -20
nfiles="$(sed -n 's/^summary files=\([0-9]*\).*/\1/p' "$CTL/scan-main.out")"
check "K1-S8 掃描檔案數 ≥ 300(非空掃描)" "$([ "${nfiles:-0}" -ge 300 ] && echo ok || echo "only $nfiles")" ok
# (find 以 -exec printf 計數,不以換行計數:K1-03 留有檔名含換行的 fixture。)
check "K1-S8 完整性:掃描的一般檔數 == find 的計數(所有意圖內的檔都被讀過)" "$nfiles" "$(find "$TMP" -type f ! -path "$FIX/*" ! -path "$CTL/*" -exec printf x \; | wc -c | tr -d ' ')"
check "K1-S8 沒有任何解碼 P12 殘留(p12.tmp 一般檔)" "$(find "$TMP" -type f -name p12.tmp ! -path "$FIX/*" | wc -l | tr -d ' ')" 0

# ---- scope:K1-NATIVE 不接線 release workflow(PR-C2)----
check "scope: release-app.yml 尚無 keychain-bootstrap / kc_bootstrap / k1ctx / k1-native(PR-C2)" "$(grep -cE 'keychain-bootstrap|kc_bootstrap|kc_cleanup|k1ctx|k1-native' "$WF")" 0
check "scope: release-app.yml 尚無 DEVELOPER_ID_KEYCHAIN / EXPECTED_DEVELOPER_ID_CERT_SHA256(PR-C2)" "$(grep -cE 'DEVELOPER_ID_KEYCHAIN|EXPECTED_DEVELOPER_ID_CERT_SHA256' "$WF")" 0
check "scope: swift-tests.yml push paths 含 Scripts/k1-native/**" "$(grep -cF "'Scripts/k1-native/**'" "$ROOT/.github/workflows/swift-tests.yml")" 1
# ---------------------------------------------------------------- summary
total=$((pass + fail))
if [ "$fail" -eq 0 ] && [ "$total" -gt 0 ]; then
    printf 'signing-pipeline tests: PASS (%d checks)\n' "$total"
    exit 0
fi
printf 'signing-pipeline tests: FAIL (%d of %d checks failed)\n' "$fail" "$total"
exit 1
