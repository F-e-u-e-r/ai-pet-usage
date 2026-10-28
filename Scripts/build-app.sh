#!/bin/bash
# 產出可雙擊執行的 macOS app bundle:dist/AI Pet Usage.app
# (LSUIElement 選單列常駐;預設 ad-hoc 簽名讓通知與 TCC 行為正常)
#
# 簽名模式 SIGN_MODE(新的顯式軸,與 BUILD_CHANNEL / 版號不變式正交):
#   adhoc(預設)   本機 / source 建置;行為與歷來完全相同(STRICT_SIGN=1 仍受支援)。不觸發任何信任發行意涵。
#   developer-id   公開發行用:Developer ID + Hardened Runtime + secure timestamp,fail-closed。需 DEVELOPER_ID_IDENTITY、
#                  EXPECTED_TEAM_ID、DEVELOPER_ID_KEYCHAIN(顯式簽名 keychain;無隱式 fallback)與
#                  EXPECTED_DEVELOPER_ID_CERT_SHA256(K1);身分缺失/不可解析即在 Swift build 前非零退出、不產出 bundle、
#                  永不回退 ad-hoc。本腳本只「簽」—— 不公證、不 staple、不發佈(那是 release workflow 與 notarize-app.sh
#                  的事);臨時 keychain 的建立 / 清理在 Scripts/keychain-bootstrap.sh(PR-C2 才接線)。
# 設計依據:PR-B 契約 + SIGNING-ARCHITECTURE。A1:預設不帶 --entitlements(本 app 非 sandbox、目前行為調查無任何
# Hardened Runtime 例外),僅在 ENTITLEMENTS 經實證必要時才帶。A2:資源 bundle 是否需自己的簽名由 --verify 仲裁。
#
# fail-closed 不倚賴 `set -e`:每個關鍵步驟都顯式 `|| return`。原因:本檔以 source-guard 設計成可被 `source`,當
# 函式於 `if f; then`、`f && …`、`! f` 等語境被呼叫時 bash 會停用該函式內的 errexit —— 只靠 set -e 會在那些語境
# 悄悄「繼續執行」而非失敗。顯式 return 使 fail-closed 與呼叫語境無關。
set -euo pipefail

# 以 BASH_SOURCE 計算 ROOT(非 $0),使本檔被 `source`(harness 驅動簽名函式)時路徑仍正確;直接執行時
# BASH_SOURCE[0]==$0,結果與歷來一致。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/AI Pet Usage.app"
BUNDLE_ID="dev.aipetusage.app"
# 版號由環境注入(release workflow 以 canonical tag 驅動,如 tag v0.1.0-beta.1 → VERSION=0.1.0 +
# RELEASE_TAG=v0.1.0-beta.1)。CFBundleShortVersionString / CFBundleVersion **必須是數字**(Apple 契約),
# 故本機預設數字 0.0.0;「是否正式版」由 AIPetUsageBuildChannel 標記(source/dev 版不觸發更新提示,見
# UpdateChecker);完整發行身分只放在 release build 的 AIPetUsageReleaseTag。規範:docs/release/VERSIONING.md。
VERSION="${VERSION:-0.0.0}"
BUILD_CHANNEL="${BUILD_CHANNEL:-source}"
RELEASE_TAG="${RELEASE_TAG:-}"

# 簽名軸(見檔頭)。預設 adhoc = 歷來行為;developer-id 為 opt-in,需顯式環境變數。
SIGN_MODE="${SIGN_MODE:-adhoc}"
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-}"
ENTITLEMENTS="${ENTITLEMENTS:-}"
# EXPECTED_TEAM_ID(Gate 1 / PR-C1A):developer-id 模式的「獨立」信任 Team ID 輸入。刻意「不」只從 DEVELOPER_ID_IDENTITY
# 衍生 —— 衍生值(_expected_team_id)只能證明身分字串「自我一致」,擋不住「攻擊者換上另一個自我一致的身分(自己的
# Team)」這類循環信任。故 verify 以此獨立值為信任根,比對實際簽出的 TeamIdentifier;衍生值降為一致性交叉檢查。
# 非機密信任設定(可記錄);形狀 = 10 碼英數(Apple Team ID)。
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
# DEVELOPER_ID_KEYCHAIN(K5):developer-id 模式「必填」的顯式簽名 keychain 檔(絕對正規路徑、一般檔、非 symlink —— 物件形狀由
# kc_identity_preflight 經 k1ctx check-keychain-path 判定,shell 不做 metadata 檢視;developer-id 模式因此也需要 K1CTX_BIN
# 指向以 Scripts/k1-native/build.sh 建置的 k1ctx)。沒有任何
# 隱式 fallback —— 身分 preflight 與每個 Developer-ID codesign 都只在這個檔裡找簽名身分,絕不退回 user 的 keychain
# search list / default keychain。可以是 K1 臨時 keychain(Scripts/keychain-bootstrap.sh 的 <context>/signing.keychain-db),
# 或本機非發行用途時「顯式」指定的 login / file keychain;未來 PR-C2 的信任發行必須是「本次 run」的 K1 臨時 keychain
# (由 PR-C2 接線保證,本腳本無從證明)。注意 man codesign(SIGNING IDENTITIES):簽名身分所在的 keychain 也必須在 user 的
# keychain search list 上 —— K1 臨時 keychain 由 Apple create-keychain 的副作用加入(LIVE-REHEARSAL 驗證);本腳本不改
# search list。
DEVELOPER_ID_KEYCHAIN="${DEVELOPER_ID_KEYCHAIN:-}"
# EXPECTED_DEVELOPER_ID_CERT_SHA256(K6):developer-id 模式「必填」的獨立 leaf 憑證 SHA-256 信任輸入(非機密)。形狀 =
# 恰 64 個十六進位字元,比較前正規化為小寫(kc_normalize_sha256);前綴、冒號、空白、截短值、SHA-1 一律拒絕。它只「釘選」
# 預期的 leaf 憑證,不取代憑證鏈 / 信任驗證(--verify --deep --strict、公證、Gatekeeper)。
EXPECTED_DEVELOPER_ID_CERT_SHA256="${EXPECTED_DEVELOPER_ID_CERT_SHA256:-}"

# ----------------------------------------------------------------------------------------------------------------
# 簽名區塊抽成函式,讓 Scripts/test-signing-pipeline.sh 能以 fake 工具(codesign/security…)離線驅動(與
# test-release-version.sh 以 fake gh 驅動的手法相同)。本檔以 source-guard 包住 main:被 `source` 時只定義函式、
# 不執行建置(harness 用);被直接執行時照常跑完整建置。
# ----------------------------------------------------------------------------------------------------------------

# developer-id 模式:驗證簽名身分存在於「顯式」DEVELOPER_ID_KEYCHAIN 且符合 K7 綁定;缺失/不可解析/不符即 fail-closed
# (呼叫端須在 Swift build 前呼叫,見 main)。adhoc 模式:no-op(本機 ad-hoc 不需任何身分)。未知模式:拒絕。
validate_signing_env() {
    case "$SIGN_MODE" in
        adhoc) return 0 ;;
        developer-id)
            if [ -z "$DEVELOPER_ID_IDENTITY" ]; then
                echo "build-app: SIGN_MODE=developer-id 需要 DEVELOPER_ID_IDENTITY(未設定)— 中止,不產出 bundle" >&2
                return 1
            fi
            # 身分必須是完整名稱 'Developer ID Application: Name (TEAMID)'(不接受裸 hash):verify 需從中推導預期
            # Team ID,若接受 hash 會造成 preflight 通過但 verify 必敗的不一致(release workflow 本就用完整名稱)。
            # find-identity 編號身分列(  N) <40-hex> "NAME")的「精確」名稱比對(非子字串:'valid'/'found' 不會撞摘要行、
            # '1)' 不會撞行首)、恰好一個、顯式檢查 security 退出碼(部分失敗卻印出匹配列時不可誤判通過)—— 這些規則現由
            # kc_identity_preflight(Scripts/keychain-bootstrap.sh,與 kc_bootstrap 共用同一實作)只對顯式 keychain 執行,
            # 見下方 K7。
            # 類別:信任發行「只」接受 'Developer ID Application: …' 憑證 —— Apple Development / Mac Developer 等雖也通過
            # -p codesigning,但不可公證/發行;若不檢查,verify 會拿同一個(錯類別的)字串比對自己而放行。
            case "$DEVELOPER_ID_IDENTITY" in
                "Developer ID Application: "*) ;;
                *) echo "build-app: DEVELOPER_ID_IDENTITY 必須是 'Developer ID Application: …' 類別(不接受其他簽章類別):'$DEVELOPER_ID_IDENTITY'" >&2; return 1 ;;
            esac
            # 身分須含可解析的 (TEAMID)(canonical 'Name (TEAMID)' 形式);否則 verify 推不出預期 Team ID。在 build
            # 「前」就檢查(而非等 verify 才失敗),省一次無謂建置;與 verify 的 Team ID 斷言保持一致。
            if [ -z "$(_expected_team_id)" ]; then
                echo "build-app: DEVELOPER_ID_IDENTITY 缺可解析的 (TEAMID)(須為 'Name (TEAMID)' 形式):'$DEVELOPER_ID_IDENTITY'" >&2
                return 1
            fi
            # Gate 1:EXPECTED_TEAM_ID 為「獨立」信任輸入(developer-id 模式 mandatory)。須為 10 碼英數的 Team-ID 形狀,
            # 且必須與身分衍生的 Team 一致 —— 這是 pre-sign 一致性閘:攻擊者即便換上「另一個自我一致」的身分(其 (TEAMID)
            # 與憑證相符),只要該 Team 不等於獨立設定的 EXPECTED_TEAM_ID,就在 Swift build / 簽名 / 公證 / 發佈「之前」被擋。
            if [ -z "$EXPECTED_TEAM_ID" ]; then
                echo "build-app: SIGN_MODE=developer-id 需要 EXPECTED_TEAM_ID(獨立信任 Team ID,未設定)— 中止,不產出 bundle" >&2
                return 1
            fi
            case "$EXPECTED_TEAM_ID" in
                *[!A-Za-z0-9]*) echo "build-app: EXPECTED_TEAM_ID 形狀不符(須全為英數):'$EXPECTED_TEAM_ID'" >&2; return 1 ;;
            esac
            if [ "${#EXPECTED_TEAM_ID}" -ne 10 ]; then
                echo "build-app: EXPECTED_TEAM_ID 須為 10 碼(Apple Team ID 形狀):'$EXPECTED_TEAM_ID'" >&2
                return 1
            fi
            local _derived_team
            _derived_team="$(_expected_team_id)"
            if [ "$_derived_team" != "$EXPECTED_TEAM_ID" ]; then
                echo "build-app: 身分衍生的 Team($_derived_team)≠ EXPECTED_TEAM_ID($EXPECTED_TEAM_ID)— fail-closed(不接受自我一致但非預期團隊的身分)" >&2
                return 1
            fi
            # K5:顯式簽名 keychain 為必填。developer-id 模式「沒有」隱式 keychain fallback:未給就在 Swift build 前
            # fail-closed,絕不退回 user 的 keychain search list / default keychain 去找身分。
            if [ -z "$DEVELOPER_ID_KEYCHAIN" ]; then
                echo "build-app: SIGN_MODE=developer-id 需要 DEVELOPER_ID_KEYCHAIN(顯式簽名 keychain,未設定;無隱式 fallback)— 中止,不產出 bundle" >&2
                return 1
            fi
            # K6:獨立 leaf 憑證 SHA-256 為必填(形狀由 kc_normalize_sha256 判定)。
            if [ -z "$EXPECTED_DEVELOPER_ID_CERT_SHA256" ]; then
                echo "build-app: SIGN_MODE=developer-id 需要 EXPECTED_DEVELOPER_ID_CERT_SHA256(獨立 leaf 憑證 SHA-256,未設定)— 中止,不產出 bundle" >&2
                return 1
            fi
            # K7:身分 preflight「只」查 DEVELOPER_ID_KEYCHAIN(精確身分恰一個、Team == EXPECTED_TEAM_ID、leaf SHA-256 ==
            # EXPECTED_DEVELOPER_ID_CERT_SHA256、對應私鑰存在)。login / default keychain 有相符身分也不能讓它通過。
            # derived selector 在此丟棄(簽名前 sign_app_bundle 會再驗一次並取用)。
            _devid_identity_preflight >/dev/null || return 1
            return 0
            ;;
        *)
            echo "build-app: 未知 SIGN_MODE='$SIGN_MODE'(須為 adhoc 或 developer-id)" >&2
            return 1
            ;;
    esac
}

# 從 "Developer ID Application: Name (TEAMID)" 取出 TEAMID(用於 verify 的 TeamIdentifier 斷言)。取不到則空。
_expected_team_id() {
    printf '%s\n' "$DEVELOPER_ID_IDENTITY" | sed -n 's/.*(\([A-Za-z0-9]\{1,\}\))[[:space:]]*$/\1/p'
}

# K7 身分 preflight —— 單一實作在 Scripts/keychain-bootstrap.sh 的 kc_identity_preflight(kc_bootstrap 用同一份 = 同一
# 套規則),只對顯式 DEVELOPER_ID_KEYCHAIN 查詢:(1) 存在 Developer ID Application 身分、(2) 恰一個且精確等於所請求
# 身分、(3) Team == 獨立 EXPECTED_TEAM_ID、(4) leaf 憑證 SHA-256 == 獨立 EXPECTED_DEVELOPER_ID_CERT_SHA256、(5) 對應
# 私鑰存在。成功時 stdout 只輸出 derived selector(該憑證的 SHA-1)。只在 developer-id 路徑載入 helper(adhoc 不依賴它);
# 每次都重新 source(只重新定義函式),不沿用環境中可能已存在的同名函式。
_devid_identity_preflight() {
    # shellcheck source=keychain-bootstrap.sh
    . "$ROOT/Scripts/keychain-bootstrap.sh" || { echo "build-app: 無法載入 Scripts/keychain-bootstrap.sh — fail-closed" >&2; return 1; }
    kc_identity_preflight "$DEVELOPER_ID_KEYCHAIN" "$DEVELOPER_ID_IDENTITY" "$EXPECTED_TEAM_ID" "$EXPECTED_DEVELOPER_ID_CERT_SHA256"
}

# 以 Developer ID 簽單一項目:Hardened Runtime(--options runtime)+ secure timestamp(--timestamp)。
# A1:預設「不帶」--entitlements —— 本 app 非 sandbox、行為調查無任何 Hardened Runtime 例外;僅在 ENTITLEMENTS
# 經實證必要時才對需要的項目加上。永不用 --deep 簽(--deep 會掩蓋漏簽的巢狀項;--deep 只在 verify 時用)。
# K8:每個 Developer-ID codesign 都帶顯式 --keychain "$DEVELOPER_ID_KEYCHAIN"(只在該檔找簽名身分);缺 keychain 或
# selector 不是 40 個十六進位字元 → 拒絕執行。不存在「省略 --keychain、退回 keychain search list」的 Developer-ID 簽名
# 路徑 —— 日後新增的任何 Developer-ID 簽名項目都必須經過本函式。$2 = kc_identity_preflight 的 derived selector
# (DERIVED SELECTOR — NOT TRUSTED INPUT;只當 codesign 的執行選擇器)。
_sign_item_developer_id() {
    local item="$1" sel="${2:-}"
    if [ -z "$DEVELOPER_ID_KEYCHAIN" ]; then
        echo "build-app: Developer-ID codesign 需要顯式 DEVELOPER_ID_KEYCHAIN — 拒絕簽名(不退回 keychain search list):$item" >&2
        return 1
    fi
    case "$sel" in
        '' | *[!0123456789ABCDEF]*) echo "build-app: Developer-ID codesign 的 selector 須為 40 個大寫十六進位字元(kc_identity_preflight 輸出)— 拒絕簽名:$item" >&2; return 1 ;;
    esac
    if [ "${#sel}" -ne 40 ]; then
        echo "build-app: Developer-ID codesign 的 selector 須為 40 個十六進位字元 — 拒絕簽名:$item" >&2
        return 1
    fi
    if [ -n "$ENTITLEMENTS" ]; then
        codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --keychain "$DEVELOPER_ID_KEYCHAIN" --sign "$sel" "$item"
    else
        codesign --force --options runtime --timestamp --keychain "$DEVELOPER_ID_KEYCHAIN" --sign "$sel" "$item"
    fi
}

# 簽整個 bundle。adhoc = 與歷來逐字相同(STRICT_SIGN 決定嚴格與否);developer-id = inside-out、fail-closed。
# 未知模式 → 拒絕(不靜默回退 ad-hoc:source-guard 暴露的函式 API 也須 fail-closed,不只靠 main 先呼叫 validate)。
sign_app_bundle() {
    local app="$1"
    case "$SIGN_MODE" in
        developer-id)
            # inside-out:先簽巢狀 executable code(aipet),再簽外層 app(外層密封含已簽的 helper)。主執行檔
            # AIPetUsage 隨外層一起被簽。資源 bundle(AIPetUsage_UsageCore.bundle,無 Mach-O 可執行碼)預設「不」
            # 另簽;僅當 --verify --deep --strict 指出它需要自己的簽名時(A2)才簽它(inside-out 最先),再重簽外層
            # 並複驗。是否需簽由 verify 仲裁,不因副檔名是 .bundle 就假設要簽。永不用 --deep 簽。
            # K7/K8:簽名「前」立即在顯式 keychain 重新執行身分 preflight(validate 在 Swift build 前驗過一次;此處再驗,
            # 避免 build 期間 keychain 變動),並取得 derived selector —— 通過全部受信任檢查的那張憑證的 SHA-1,只當
            # codesign 的執行選擇器(40 hex = 憑證 SHA-1、不看名稱,也不經 identity preference 的間接;名稱選擇是子字串
            # 比對)。信任綁定仍是 Team 與 SHA-256,簽後再由 verify_signature 對成品複驗。
            local sel
            sel="$(_devid_identity_preflight)" || return 1
            _sign_item_developer_id "$app/Contents/MacOS/aipet" "$sel" || return 1
            _sign_item_developer_id "$app" "$sel" || return 1
            local verr
            if ! verr="$(codesign --verify --deep --strict "$app" 2>&1)"; then
                if grep -qF 'AIPetUsage_UsageCore.bundle' <<<"$verr"; then
                    # A2:資源 bundle 需要自己的簽名 —— 簽它(inside-out 最先),重簽外層(重新密封),複驗。
                    _sign_item_developer_id "$app/Contents/Resources/AIPetUsage_UsageCore.bundle" "$sel" || return 1
                    _sign_item_developer_id "$app" "$sel" || return 1
                    codesign --verify --deep --strict "$app" || return 1
                else
                    printf '%s\n' "$verr" >&2
                    return 1
                fi
            fi
            return 0
            ;;
        adhoc)
            # adhoc —— 與歷來逐字相同(原 build-app.sh 的簽名區塊),僅把隱式 set -e 失敗改為顯式 `|| return`,
            # 行為等價(嚴格路徑失敗即非零退出;非嚴格路徑 best-effort 吞掉失敗)。
            # 先簽巢狀的 aipet,再簽外層 app(外層密封含已簽的 helper)。
            # STRICT_SIGN=1(release workflow):簽章失敗即 fail 並 --verify --strict 驗證 —
            # CI 產出未簽 bundle 下載後是「已損壞」,比 quarantine 更難排;不用 --deep 簽(會掩蓋漏簽)。
            if [[ "${STRICT_SIGN:-0}" == "1" ]]; then
                codesign --force --sign - "$app/Contents/MacOS/aipet" || return 1
                codesign --force --sign - "$app" || return 1
                codesign --verify --deep --strict "$app" || return 1
            else
                codesign --force --sign - "$app/Contents/MacOS/aipet" 2>/dev/null || true
                codesign --force --sign - "$app" 2>/dev/null || true
            fi
            return 0
            ;;
        *)
            echo "sign_app_bundle: 未知 SIGN_MODE='$SIGN_MODE'(須為 adhoc 或 developer-id)" >&2
            return 1
            ;;
    esac
}

# K9:成品的 leaf 憑證 SHA-256 綁定。以 `codesign -d --extract-certificates=<前綴>` 取出簽章內嵌的憑證鏈(man codesign:
# 檔名 = 前綴 + 0..n-1,0 = leaf(簽名)憑證,DER),計算 leaf 的 SHA-256 與 $2(已正規化的預期值)比較。抽取一律寫進
# 本函式自己以 mktemp -d 建立、位於 TMPDIR 的暫存區(顯式絕對前綴;絕不用 codesign 預設的「目前目錄 codesign0..N」),
# 並在每條返回路徑上移除抽出的檔與暫存區 —— repo / workspace 不留任何憑證產物。--extract-certificates 是「可選值」選項,
# 必須用 '=' 形式(man codesign:'--name value' 對可選值選項不會如預期運作)。SHA-256 只「釘選」預期 leaf,不取代憑證鏈
# 驗證。$1 = 已簽項目。
_leaf_sha256_matches() {
    local item="$1" want="$2" work got rc=1
    work="$(mktemp -d "${TMPDIR:-/tmp}/aipet-leafcert.XXXXXXXX")" || { echo "verify: 無法建立憑證抽取暫存區" >&2; return 1; }
    if [ -z "$work" ] || [ ! -d "$work" ]; then echo "verify: 憑證抽取暫存區無效" >&2; return 1; fi
    if codesign -d --extract-certificates="$work/leaf." "$item" >/dev/null 2>&1 \
        && [ -f "$work/leaf.0" ] && [ ! -L "$work/leaf.0" ]; then
        if got="$(shasum -a 256 "$work/leaf.0")"; then
            got="${got%% *}"
            [ -n "$want" ] && [ "$got" = "$want" ] && rc=0
        fi
    fi
    # 逐一刪除 codesign 寫出的 leaf.0 … leaf.(n-1)(不用 glob:呼叫端的 GLOBIGNORE / nullglob 等不得讓刪除漏掉憑證檔)。
    local i=0
    while [ -e "$work/leaf.$i" ] || [ -L "$work/leaf.$i" ]; do
        rm -f "$work/leaf.$i"
        i=$((i + 1))
    done
    if ! rmdir "$work"; then
        echo "verify: 無法移除憑證抽取暫存區:$work" >&2
        rc=1
    fi
    return "$rc"
}

# developer-id 最終權威驗證(fail-closed):封印完整性 + 對「每個 executable-code 項」(aipet + 外層)斷言
# Developer ID 權威 + Team ID + leaf 憑證 SHA-256(K9)+ Hardened Runtime flag + 安全時間戳,再斷言無 app-sandbox / 無 cs.*
# 例外(A1;對已簽二進位 dump,非對 committed 檔)。spctl 不在此驗(它是 post-staple 檢查,此時尚未公證,spctl 會正確地
# 拒絕)。每個檢查皆顯式 return(不倚賴 set -e)。
verify_signature() {
    local app="$1"
    # 1) 封印完整性(遞迴);也是 A2 的仲裁者。
    codesign --verify --deep --strict "$app" || { echo "verify: --verify --deep --strict 失敗" >&2; return 1; }
    # 2) Team ID 信任根(Gate 1):以「獨立」的 EXPECTED_TEAM_ID 為權威,比對實際簽出的 TeamIdentifier。身分衍生的
    #    Team(_expected_team_id)降為一致性交叉檢查 —— 單靠衍生值只證明身分「自我一致」,擋不住「換上另一個自我一致
    #    身分」。三者皆須成立,否則 fail-closed:(a) EXPECTED_TEAM_ID 必填;(b) 身分可推導出 Team;(c) 衍生 Team 與
    #    EXPECTED_TEAM_ID 一致。最終(步驟 3)以 EXPECTED_TEAM_ID 比對已簽二進位實際回報的 TeamIdentifier。
    local want_team derived_team
    if [ -z "$EXPECTED_TEAM_ID" ]; then
        echo "verify: developer-id 需要 EXPECTED_TEAM_ID(獨立信任 Team ID)— 缺則 fail-closed" >&2
        return 1
    fi
    derived_team="$(_expected_team_id)"
    if [ -z "$derived_team" ]; then
        echo "verify: 無法從 DEVELOPER_ID_IDENTITY 推導 Team ID — 請用完整 'Name (TEAMID)' 形式" >&2
        return 1
    fi
    if [ "$derived_team" != "$EXPECTED_TEAM_ID" ]; then
        echo "verify: 身分衍生的 Team($derived_team)≠ EXPECTED_TEAM_ID($EXPECTED_TEAM_ID)— fail-closed" >&2
        return 1
    fi
    # 信任根 = 獨立的 EXPECTED_TEAM_ID(非身分衍生值)。移除此獨立比對 → 自我一致的錯誤團隊簽章會矇過(見 team-id 鑑別性測試)。
    want_team="$EXPECTED_TEAM_ID"
    # K9 信任根 = 獨立的 EXPECTED_DEVELOPER_ID_CERT_SHA256(必填;K6 形狀,正規化為小寫)。
    local want_sha
    if [ -z "$EXPECTED_DEVELOPER_ID_CERT_SHA256" ]; then
        echo "verify: developer-id 需要 EXPECTED_DEVELOPER_ID_CERT_SHA256(獨立 leaf 憑證 SHA-256)— 缺則 fail-closed" >&2
        return 1
    fi
    # shellcheck source=keychain-bootstrap.sh
    . "$ROOT/Scripts/keychain-bootstrap.sh" || { echo "verify: 無法載入 Scripts/keychain-bootstrap.sh — fail-closed" >&2; return 1; }
    want_sha="$(kc_normalize_sha256 "$EXPECTED_DEVELOPER_ID_CERT_SHA256")" \
        || { echo "verify: EXPECTED_DEVELOPER_ID_CERT_SHA256 須恰為 64 個十六進位字元 — fail-closed" >&2; return 1; }
    # 3) 對「每個 executable-code 項」(aipet + 外層)斷言:leaf Authority「精確」等於所請求的身分名稱(非只
    #    'Developer ID Application' 前綴 —— 否則同團隊的另一張 Developer ID 憑證也會通過)、TeamIdentifier 相符、
    #    Hardened Runtime flag 存在。以 herestring 餵 grep(非 printf | grep -q 管線)避免 pipefail + SIGPIPE 誤拒。
    local item dv
    for item in "$app/Contents/MacOS/aipet" "$app"; do
        dv="$(codesign -dvvv "$item" 2>&1)" || { echo "verify: codesign -dvvv 失敗:$item" >&2; return 1; }
        grep -qxF "Authority=$DEVELOPER_ID_IDENTITY" <<<"$dv" \
            || { echo "verify: $item 的 leaf Authority 不等於所請求身分:$DEVELOPER_ID_IDENTITY" >&2; return 1; }
        grep -qxF "TeamIdentifier=$want_team" <<<"$dv" \
            || { echo "verify: $item TeamIdentifier 不符預期($want_team)" >&2; return 1; }
        # K9:成品簽章內嵌的 leaf 憑證 SHA-256 == 獨立 EXPECTED_DEVELOPER_ID_CERT_SHA256(移除此比對 → 名稱 / Team 相符但
        # 不是預期那張憑證的簽章會矇過;見 SHA-256 綁定鑑別性測試)。
        _leaf_sha256_matches "$item" "$want_sha" \
            || { echo "verify: $item 的 leaf 憑證 SHA-256 ≠ EXPECTED_DEVELOPER_ID_CERT_SHA256($want_sha)" >&2; return 1; }
        grep -Eq 'flags=.*runtime' <<<"$dv" \
            || { echo "verify: $item 缺 Hardened Runtime(runtime)flag" >&2; return 1; }
        # F1:斷言「安全時間戳」確實存在於結果簽章的 metadata。codesign -dvvv 對帶 TSA 安全時間戳的簽章印出獨立的
        #     'Timestamp=' 行;無安全時間戳(如以 --timestamp=none 簽、或時間戳遺失)時只印 'Signed Time='(簽章者
        #     本機時鐘,非安全)。只檢查命令列曾帶 --timestamp 並不足夠(F1 契約:驗「結果簽章」真的含安全時間戳,
        #     非只驗旗標)。錨定行首 ^Timestamp= 以免被 'Signed Time=' 矇過。本函式只在 developer-id 模式被呼叫,故
        #     此檢查不加諸既有 ad-hoc 開發模式。
        grep -q '^Timestamp=' <<<"$dv" \
            || { echo "verify: $item 缺安全時間戳(codesign -dvvv 無 'Timestamp=' 行;--timestamp=none 或 TSA 時間戳遺失)" >&2; return 1; }
    done
    # 4) 無 app-sandbox、無 cs.* 例外(A1)。entitlements dump 失敗 → fail-closed(不吞,否則錯誤會變成「看似乾淨」)。
    local ent
    for item in "$app" "$app/Contents/MacOS/aipet"; do
        ent="$(codesign -d --entitlements - "$item" 2>/dev/null)" \
            || { echo "verify: entitlements dump 失敗:$item" >&2; return 1; }
        if grep -qF 'com.apple.security.app-sandbox' <<<"$ent"; then
            echo "verify: $item 不應帶 com.apple.security.app-sandbox" >&2; return 1
        fi
        if grep -Eq 'com\.apple\.security\.cs\.' <<<"$ent"; then
            echo "verify: $item 不應帶 cs.* Hardened Runtime 例外" >&2; return 1
        fi
    done
    return 0
}

# 組裝 bundle 到 <dest>:清空、mkdir、cp 三個產物、寫 Info.plist、PkgInfo。任一步失敗即非零(每步顯式 return,
# 含 `rm -rf` —— 不倚賴 set -e,因在 `if main` 等語境 set -e 會被停用)。本函式只組裝,不簽、不清理(清理由呼叫端
# 依模式決定:developer-id 用 staging + 失敗清 staging;adhoc 維持歷來「直接組裝於最終路徑」行為)。
_assemble_bundle() {
    local dest="$1"
    rm -rf "$dest" || return 1
    mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources" || return 1
    cp "$ROOT/.build/release/AIPetUsage" "$dest/Contents/MacOS/AIPetUsage" || return 1
    # aipet CLI 也隨附:排程匯出的 LaunchAgent 以絕對路徑呼叫它(見 ScheduledReportManager)。
    cp "$ROOT/.build/release/aipet" "$dest/Contents/MacOS/aipet" || return 1
    # SwiftPM 資源(價目表 JSON)放標準的 Contents/Resources(codesign / 公證合法結構)。
    # UsageCore 的 PricingRegistry.resourceBundle() 以 Bundle.main.resourceURL 穩健定位——
    # app 主程式與獨立執行的 aipet(launchd 排程)都解析到此,不依賴會在資源遺失時 fatalError 的
    # Bundle.module,也不需在 .app 根放非標準檔。
    cp -R "$ROOT/.build/release/AIPetUsage_UsageCore.bundle" "$dest/Contents/Resources/" || return 1
    VERSION="$VERSION" BUILD_CHANNEL="$BUILD_CHANNEL" RELEASE_TAG="$RELEASE_TAG" BUNDLE_ID="$BUNDLE_ID" \
        "$ROOT/Scripts/write-info-plist.sh" "$dest/Contents/Info.plist" || return 1
    printf 'APPL????' > "$dest/Contents/PkgInfo" || return 1
}

main() {
    # 先驗證版本不變式再進入(較慢的)Swift 建置;write-info-plist.sh 寫檔前會再驗證一次。
    VERSION="$VERSION" BUILD_CHANNEL="$BUILD_CHANNEL" RELEASE_TAG="$RELEASE_TAG" \
        "$ROOT/Scripts/release-version.sh" --check-build-env || return 1
    # developer-id 身分亦在 Swift build 前驗證(fail-closed:缺身分就不浪費一次建置,也不會產出未簽/半簽 bundle)。
    validate_signing_env || return 1

    "$ROOT/Scripts/swiftpm.sh" build -c release --product AIPetUsage || return 1
    "$ROOT/Scripts/swiftpm.sh" build -c release --product aipet || return 1

    if [ "$SIGN_MODE" = developer-id ]; then
        # 交易式:組裝→簽→驗 全在 staging 路徑;任一失敗即清 staging(最終 dist 路徑「絕不」留下半簽/錯簽/半組裝
        # 的產物,也不會因失敗而破壞先前成功的產物);三者皆通過才原子換到最終路徑。
        local work="$ROOT/dist/.staging-AIPetUsage.app"
        local prev="$ROOT/dist/.prev-AIPetUsage.app"
        _assemble_bundle "$work"  || { rm -rf "$work"; return 1; }
        sign_app_bundle "$work"   || { rm -rf "$work"; return 1; }
        verify_signature "$work"  || { rm -rf "$work"; return 1; }
        # 交易式換置(崩潰安全的 .prev-dance,round-4 三家族 reviewer 共識):絕不同時失去新舊兩者,且能從「上一輪在
        # 交出半途被中斷」的崩潰視窗復原。任何失敗分支都「保留」已驗證 staging($work),不在 $APP 已移走後刪它。
        # (1) 崩潰復原:若 APP 缺、prev 在(=上一輪把舊產物移到旁邊後被中斷),先還原 prev→APP。
        if [ ! -e "$APP" ] && [ -e "$prev" ]; then
            mv "$prev" "$APP" || { echo "build-app: 無法還原先前產物($prev→$APP);保留 staging=$work" >&2; return 1; }
        fi
        # (2) 清理殘留 prev(此時 APP 已是最後的好產物或本不存在);清不掉就中止,以免下一步 mv 巢狀。
        rm -rf "$prev" || { echo "build-app: 無法清理殘留 $prev(避免 mv 巢狀);保留 staging=$work" >&2; return 1; }
        # (3) 既有產物(若有)移到 prev;失敗則保留舊的與已驗證 staging。
        if [ -e "$APP" ]; then
            mv "$APP" "$prev" || { echo "build-app: 無法將既有產物移到 $prev;保留 staging=$work(未破壞既有產物)" >&2; return 1; }
        fi
        # (4) 已驗證 staging → 最終路徑;成功刪 prev,失敗則還原舊的、保留 staging。
        if mv "$work" "$APP"; then
            rm -rf "$prev" 2>/dev/null || echo "build-app: 警告:清理殘留 $prev 失敗(發行已成功,屬無害殘留;下一輪 step(2) 會重試)" >&2
        else
            if [ -e "$prev" ]; then
                mv "$prev" "$APP" || echo "build-app: 警告:還原先前產物($prev→$APP)亦失敗;$prev 與 staging=$work 均保留供人工復原" >&2
            fi
            echo "build-app: 無法將已驗證 staging 推進到最終路徑;保留已驗證 staging=$work(未同時失去新舊)" >&2
            return 1
        fi
    else
        # adhoc —— 與歷來相同:直接組裝於最終路徑;組裝失敗即非零退出(不特別清理,與原 set -e 行為一致)。
        _assemble_bundle "$APP" || return 1
        sign_app_bundle "$APP"  || return 1
    fi

    echo "Built: $APP"
    echo "Run:   open \"$APP\""
}

# source-guard:被 `source` 時只定義函式(harness 用);直接執行時跑完整建置。
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi
