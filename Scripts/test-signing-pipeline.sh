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
# 執行:/bin/bash Scripts/test-signing-pipeline.sh   (exit 0 = 全數通過)
set -uo pipefail
export LC_ALL=C

# F8:清除任何繼承的同名工具「函式」與 BASH_ENV,確保子行程一律解析到 PATH-prepend 的 fake shim,而非被 exported
# function / BASH_ENV 劫持到真實 gh/codesign/… —— 否則綠色閘門內模擬的 `gh release create` 可能變成真實發佈。
unset -f gh codesign security xcrun spctl 2>/dev/null || true
unset BASH_ENV 2>/dev/null || true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/Scripts/build-app.sh"
NOTARIZE="$ROOT/Scripts/notarize-app.sh"
RV="$ROOT/Scripts/release-version.sh"
WF="$ROOT/.github/workflows/release-app.yml"
TMP="$(mktemp -d)"
# F7:mktemp 失敗時 TMP 會為空,後續 "$TMP/bin/…" 會塌成 "/bin/…" —— 在可寫環境可能覆寫真實系統工具。先 fail-fast。
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FATAL: mktemp -d 失敗,拒絕執行(避免 shim 寫到 /bin)"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
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
# fake codesign。argv → $FAKE_DIR/codesign.log。模式:--sign(簽)/ --verify / -dvvv(顯示)/ -d --entitlements -(傾印)。
# 旗標:FAKE_SIGN_FAIL=1 簽失敗;FAKE_VERIFY_FAIL=1 verify 失敗;FAKE_RB_NEEDS_SIGNING=1 資源 bundle 未簽前 verify 報
# 其專屬錯誤(A2);FAKE_TEAM_ID / FAKE_AUTHORITY / FAKE_RUNTIME_FLAG(0=無 runtime)控制 -dvvv;FAKE_AIPET_TEAM /
# FAKE_AIPET_RUNTIME 針對巢狀 aipet 覆寫(測 verify 是否對每個 executable 項都查);FAKE_ENTITLEMENTS(sandbox|cs|空)
# 控制 entitlements 傾印(FAKE_AIPET_ENTITLEMENTS 覆寫巢狀 aipet,「設為空字串」= 明確乾淨、不繼承外層)。
# F1:FAKE_TIMESTAMP_FLAG / FAKE_AIPET_TIMESTAMP(0=無安全時間戳)控制 -dvvv 是否印 'Timestamp='(預設忠實依實際所簽
# 的 --timestamp);用來模擬「命令列看似正常但結果簽章無安全時間戳」(如 --timestamp=none / 時間戳遺失)。
D="$FAKE_DIR"
printf '%s\n' "$*" >> "$D/codesign.log"
is_sign=0; is_verify=0; is_dumpent=0; is_display=0
for a in "$@"; do
    case "$a" in
        --sign) is_sign=1 ;;
        --verify) is_verify=1 ;;
        --entitlements) is_dumpent=1 ;;
        -dvvv) is_display=1 ;;
    esac
done
item="${@: -1}"
if [ "$is_sign" = 1 ]; then
    [ "${FAKE_SIGN_FAIL:-0}" = 1 ] && { echo "codesign: unable to build chain to self-signed root for signer" >&2; exit 1; }
    # 記錄此項目「實際以什麼簽」:--sign 的身分值、是否帶 --options runtime、是否帶 --timestamp。供 -dvvv「忠實」回報
    # (Authority 依所簽身分、runtime flag 依實際 --options runtime)。這把整類「fake 回報與實際 --sign args 脫鉤」的
    # oracle 漏洞一次關閉:把簽改成 --sign - / 漏 --options runtime 都會被 verify 抓到。
    signid=""; prev=""; rt=0; ts=0
    for a in "$@"; do
        [ "$prev" = "--sign" ] && signid="$a"
        [ "$prev" = "--options" ] && [ "$a" = runtime ] && rt=1
        [ "$a" = "--timestamp" ] && ts=1
        prev="$a"
    done
    printf '%s\t%s\t%s\t%s\n' "$item" "$signid" "$rt" "$ts" >> "$D/signed.map"
    case "$item" in *AIPetUsage_UsageCore.bundle) : > "$D/rb_signed" ;; esac
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
    # 從 signed.map 取此項目最後一次簽的記錄(signid / runtime / timestamp)。未簽或簽成 '-' → Signature=adhoc
    # (grok nit:無記錄視同未簽 adhoc,避免未簽項被回報成 Developer ID)。
    IFS='|' read -r rsignid rrt rts <<< "$(awk -F'\t' -v it="$item" '$1==it{s=$2;r=$3;t=$4} END{print s"|"r"|"t}' "$D/signed.map" 2>/dev/null)"
    if [ -z "$rsignid" ] || [ "$rsignid" = "-" ]; then
        printf 'Signature=adhoc\n' >&2
        exit 0
    fi
    # Authority 預設 = 「實際所簽身分」(忠實);FAKE_AUTHORITY 覆寫以模擬換成同團隊的另一張憑證。
    auth="${FAKE_AUTHORITY:-$rsignid}"
    # Team:FAKE 覆寫 > 從所簽身分名稱的 (TEAMID) 擷取 > 預設。
    team="$(printf '%s\n' "$rsignid" | sed -n 's/.*(\([A-Za-z0-9]\{1,\}\))[[:space:]]*$/\1/p')"
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
# fake security。find-identity:FAKE_IDENTITY_PRESENT=1 印出「編號身分列」含 FAKE_IDENTITY_STRING(預設可解析);
# =0 只印摘要行 "0 valid identities found"(用來證明 validate 不該被摘要行子字串矇過)。
D="$FAKE_DIR"
printf '%s\n' "$*" >> "$D/security.log"
case "${1:-}" in
    find-identity)
        if [ "${FAKE_IDENTITY_PRESENT:-1}" = 1 ]; then
            printf '  1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "%s"\n' "${FAKE_IDENTITY_STRING:-Developer ID Application: AI Pet Usage Test (TEAM123456)}"
            if [ "${FAKE_IDENTITY_DUP:-0}" = 1 ]; then
                # 兩個同名(續期)憑證,不同 hash → 歧義(sol#1 uniqueness)
                printf '  2) 99998888777766665555444433332222111100FF "%s"\n' "${FAKE_IDENTITY_STRING:-Developer ID Application: AI Pet Usage Test (TEAM123456)}"
                printf '     2 valid identities found\n'
            else
                printf '     1 valid identities found\n'
            fi
        else
            printf '     0 valid identities found\n'
        fi
        # FAKE_SECURITY_FAIL=1:印出匹配列「後」仍以非零退出(模擬某 keychain 損壞)→ validate 須以退出碼 fail-closed。
        [ "${FAKE_SECURITY_FAIL:-0}" = 1 ] && exit 1
        ;;
    *) : ;;
esac
exit 0
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
# (env 的 assignment 覆寫繼承的環境值)。
drive_validate() {
    local d="$1"; shift
    ( cd "$ROOT" && env "$@" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
        bash -c 'source "$1"; validate_signing_env' _ "$BUILD" ) >"$d/out" 2>&1
}
# 驅動 build-app.sh 的 sign_app_bundle(+ developer-id 時 verify_signature)。$1=state $2=bundle ; $3… = VAR=val。
drive_sign() {
    local d="$1" bundle="$2"; shift 2
    ( cd "$ROOT" && env "$@" FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
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

# ================================================================ build-app.sh 簽名路徑(case 1–7, 15, 16)

# ---- case 1:缺失 / 不可解析的 Developer ID 身分 → 在 Swift build 前 fail-closed,不產出 bundle ----
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY=""; red "case1 RED: developer-id 無身分 → validate 非零" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=0; red "case1 RED: 身分不可解析 → validate 非零" $?
# M1 回歸:零身分時 summary 行含 'valid'/'found' 子字串,不得矇過 validate(錨定到編號身分列)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="valid" FAKE_IDENTITY_PRESENT=0; red "case1 RED(M1): 'valid' 撞 summary 行仍須 fail-closed" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="found" FAKE_IDENTITY_PRESENT=0; red "case1 RED(M1): 'found' 撞 summary 行仍須 fail-closed" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=1; green "case1 GREEN: 身分存在且可解析 → validate 0" $?
# V2:security 印出匹配列「後」卻以非零退出(某 keychain 損壞)→ validate 須以退出碼 fail-closed。關鍵:必須在
# 「set -e 被停用」的語境測(main 以 `validate_signing_env || return 1` 呼叫,bash 於此停用函式內 errexit)——
# 直接呼叫時 set -e 會自己擋掉失敗的 command substitution,反而遮蔽了這個漏洞。故以 `if validate; then echo OK` 驗。
d="$(new_state)"
( cd "$ROOT" && env SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=1 FAKE_SECURITY_FAIL=1 FAKE_DIR="$d" PATH="$TMP/bin:$PATH" \
    bash -c 'source "$1"; if validate_signing_env; then echo VALIDATE_OK; fi' _ "$BUILD" ) >"$d/out" 2>&1
check "case1 RED(V2): security 非零退出(set -e 停用語境)→ validate fail-closed,不印 VALIDATE_OK" "$(grep -c VALIDATE_OK "$d/out")" 0
# V3:裸 hash 形式身分 → preflight 拒絕(只接受完整 'Name (TEAMID)',與 verify 的 Team ID 推導保持一致)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="ABCDEF0123456789ABCDEF0123456789ABCDEF01" FAKE_IDENTITY_PRESENT=1; red "case1 RED(V3): 裸 hash 身分 → preflight 拒絕(須完整名稱)" $?
# sol#1 類別:非 'Developer ID Application:' 類別(如 Apple Development,雖通過 -p codesigning 但不可公證發行)→ preflight 拒絕
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="Apple Development: X (TEAM123456)" FAKE_IDENTITY_STRING="Apple Development: X (TEAM123456)" FAKE_IDENTITY_PRESENT=1; red "case1 RED(sol#1 class): 非 Developer ID Application 類別 → preflight 拒絕" $?
# sol#1 唯一性:兩個同名(續期)憑證 → 歧義(codesign 可能選錯)→ preflight 拒絕
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=1 FAKE_IDENTITY_DUP=1; red "case1 RED(sol#1 uniq): 同名重複憑證(歧義)→ preflight 拒絕" $?
# grok N2:身分缺可解析的 (TEAMID) → preflight(非等 verify)就拒絕,省一次無謂建置
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="Developer ID Application: No Team Here" FAKE_IDENTITY_STRING="Developer ID Application: No Team Here" FAKE_IDENTITY_PRESENT=1; red "case1 RED(grok N2): 身分缺 (TEAMID) → preflight 拒絕(非等到 verify)" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=adhoc; green "case1 GREEN: adhoc 不需身分 → validate 0" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=bogus; red "case1 RED: 未知 SIGN_MODE 被拒" $?

# ---- case 2:無效簽名身分(codesign --sign 失敗)→ RED ----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_SIGN_FAIL=1; red "case2 RED: codesign --sign 失敗 → 非零" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID"; green "case2 GREEN: 簽名成功 → 0" $?

# ---- case 3:錯誤 Team ID(verify 的 TeamIdentifier 斷言)→ RED ----
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_TEAM_ID=WRONG99999; red "case3 RED: TeamIdentifier 不符 → verify 非零" $?
# M2b:僅「巢狀 aipet」team 錯(外層正確)也須被抓到(verify 對每個 executable 項都查)
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_AIPET_TEAM=WRONG99999; red "case3 RED(M2b): 僅 aipet team 錯 → verify 非零" $?
# M2a:身分無 (TEAMID) 可推導 → verify fail-closed(不靜默跳過 team 斷言)
NOTEAM='Developer ID Application: No Team Here'
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$NOTEAM" FAKE_IDENTITY_STRING="$NOTEAM"; red "case3 RED(M2a): 身分無 (TEAMID) → verify fail-closed" $?
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
( cd "$ROOT" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" bash -c 'codesign --force --timestamp --sign "$1" "$2/Contents/MacOS/aipet"; codesign --force --timestamp --sign "$1" "$2"' _ "$DEVID" "$APP" ) >/dev/null 2>&1
( cd "$ROOT" && env FAKE_DIR="$d" PATH="$TMP/bin:$PATH" DEVELOPER_ID_IDENTITY="$DEVID" bash -c 'source "$1"; verify_signature "$2"' _ "$BUILD" "$APP" ) >/dev/null 2>&1
red "V5 RED: 漏 --options runtime 的簽 → fake -dvvv 無 runtime → verify 非零" $?

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
        FAKE_DIR="$MDIR" SWIFTPM_MARKER="$SWIFTPM_MARKER" FAKE_IDENTITY_STRING="$2" PATH="$TMP/bin:$PATH" \
        bash "$MROOT/Scripts/build-app.sh" ) > "$MDIR/main.out" 2>&1
}
# 「不」wipe dist 的變體(保留先前成功產物,用來鎖 V4 的「失敗重建不毀舊產物」與原子換置);$3… = 額外 env
# (前綴於 env;亦可覆寫 PATH 以注入 fake mv)。
drive_main_keep() {
    local sm="$1" id="$2"; shift 2
    rm -rf "$MROOT/.build"; rm -f "$SWIFTPM_MARKER"; : > "$MDIR/codesign.log"
    ( env SIGN_MODE="$sm" DEVELOPER_ID_IDENTITY="$id" VERSION=0.0.0 BUILD_CHANNEL=source RELEASE_TAG="" \
        FAKE_DIR="$MDIR" SWIFTPM_MARKER="$SWIFTPM_MARKER" FAKE_IDENTITY_STRING="$id" PATH="$TMP/bin:$PATH" "$@" \
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
        FAKE_DIR="$MDIR" SWIFTPM_MARKER="$SWIFTPM_MARKER" FAKE_IDENTITY_STRING="$DEVID" PATH="$TMP/bin:$PATH" "$@" \
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
    FAKE_DIR="$MDIR" SWIFTPM_MARKER="$SWIFTPM_MARKER" FAKE_IDENTITY_STRING="$DEVID" FAKE_MV_FAIL_STAGING=1 PATH="$MVBIN:$TMP/bin:$PATH" \
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
for p in build-app.sh notarize-app.sh test-signing-pipeline.sh; do
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
EVID='Developer ID Application: Evil Co (EVILTEAM02)'   # 自我一致但「別團隊」的身分(derived=EVILTEAM02)
# TI-1 mandatory:developer-id 缺 EXPECTED_TEAM_ID → validate RED(簽名前)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=1 EXPECTED_TEAM_ID=""; red "TI-1 RED: developer-id 缺 EXPECTED_TEAM_ID → validate 非零(簽名前)" $?
# TI-2 shape:非 10 碼 / 含非英數 → validate RED
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=1 EXPECTED_TEAM_ID=SHORT; red "TI-2 RED: EXPECTED_TEAM_ID 非 10 碼 → validate 非零" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=1 EXPECTED_TEAM_ID='TEAM!23456'; red "TI-2 RED: EXPECTED_TEAM_ID 含非英數 → validate 非零" $?
# 上兩案的 EXPECTED 也 ≠ 衍生值,故即使形狀閘被移除仍會被一致性比對擋下(遮蔽)。此案讓身分衍生 == EXPECTED == 非 10 碼
# (ABC12),只有 10 碼形狀閘能擋 —— 移除長度檢查即 RED 轉綠。
SHORTID='Developer ID Application: Short Co (ABC12)'
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$SHORTID" FAKE_IDENTITY_STRING="$SHORTID" FAKE_IDENTITY_PRESENT=1 EXPECTED_TEAM_ID=ABC12; red "TI-2 RED: 自我一致但非 10 碼的 Team(衍生=EXPECTED=ABC12)→ validate 非零(形狀閘獨立把關)" $?
# TI-3 differential:=T1(=身分衍生)→ proceed;=T2(≠衍生)→ 簽名前 fail-closed
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=1 EXPECTED_TEAM_ID=TEAM123456; green "TI-3 GREEN: EXPECTED_TEAM_ID=T1 → validate 0(可進行)" $?
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$DEVID" FAKE_IDENTITY_PRESENT=1 EXPECTED_TEAM_ID=WRONG99999; red "TI-3 RED: EXPECTED_TEAM_ID=T2 → 簽名前 fail-closed" $?
# TI-4 self-consistency bypass(check #5):別團隊的自我一致身分 + EXPECTED=T1 → RED(validate 與 verify 兩層)
d="$(new_state)"; drive_validate "$d" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$EVID" FAKE_IDENTITY_STRING="$EVID" FAKE_IDENTITY_PRESENT=1 EXPECTED_TEAM_ID=TEAM123456; red "TI-4a RED: 別團隊自我一致身分 + EXPECTED=T1 → validate 非零" $?
d="$(new_state)"; drive_sign "$d" "$APP" SIGN_MODE=developer-id DEVELOPER_ID_IDENTITY="$EVID" FAKE_IDENTITY_STRING="$EVID" EXPECTED_TEAM_ID=TEAM123456; red "TI-4b RED: verify 以 EXPECTED 比對實際簽出 team(EVILTEAM02≠T1)→ 非零" $?
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

# ---------------------------------------------------------------- summary
total=$((pass + fail))
if [ "$fail" -eq 0 ] && [ "$total" -gt 0 ]; then
    printf 'signing-pipeline tests: PASS (%d checks)\n' "$total"
    exit 0
fi
printf 'signing-pipeline tests: FAIL (%d of %d checks failed)\n' "$fail" "$total"
exit 1
