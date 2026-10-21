#!/bin/bash
# 產出可雙擊執行的 macOS app bundle:dist/AI Pet Usage.app
# (LSUIElement 選單列常駐;預設 ad-hoc 簽名讓通知與 TCC 行為正常)
#
# 簽名模式 SIGN_MODE(新的顯式軸,與 BUILD_CHANNEL / 版號不變式正交):
#   adhoc(預設)   本機 / source 建置;行為與歷來完全相同(STRICT_SIGN=1 仍受支援)。不觸發任何信任發行意涵。
#   developer-id   公開發行用:Developer ID + Hardened Runtime + secure timestamp,fail-closed。需 DEVELOPER_ID_IDENTITY;
#                  身分缺失/不可解析即在 Swift build 前非零退出、不產出 bundle、永不回退 ad-hoc。本腳本只「簽」——
#                  不公證、不 staple、不發佈(那是 release workflow 與 notarize-app.sh 的事)。
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

# ----------------------------------------------------------------------------------------------------------------
# 簽名區塊抽成函式,讓 Scripts/test-signing-pipeline.sh 能以 fake 工具(codesign/security…)離線驅動(與
# test-release-version.sh 以 fake gh 驅動的手法相同)。本檔以 source-guard 包住 main:被 `source` 時只定義函式、
# 不執行建置(harness 用);被直接執行時照常跑完整建置。
# ----------------------------------------------------------------------------------------------------------------

# developer-id 模式:驗證簽名身分存在且可被 codesign 解析;缺失/不可解析即 fail-closed(呼叫端須在 Swift build
# 前呼叫,見 main)。adhoc 模式:no-op(本機 ad-hoc 不需任何身分)。未知模式:拒絕。
validate_signing_env() {
    case "$SIGN_MODE" in
        adhoc) return 0 ;;
        developer-id)
            if [ -z "$DEVELOPER_ID_IDENTITY" ]; then
                echo "build-app: SIGN_MODE=developer-id 需要 DEVELOPER_ID_IDENTITY(未設定)— 中止,不產出 bundle" >&2
                return 1
            fi
            # 身分必須「精確」等於 find-identity 某一「編號身分列」(  N) <40-hex> "NAME")引號內的完整 NAME。
            # 刻意只接受完整名稱形式、不接受裸 hash:verify 需從 "Name (TEAMID)" 推導預期 Team ID,若接受 hash 會造成
            # preflight 通過但 verify 必敗的不一致(release workflow 本就用完整名稱)。子字串比對會 fail-open
            # ('valid'/'found' 撞摘要行、'1)' 撞行首),故逐列、以參數展開精確比對 NAME,不經 grep -q 管線
            # (避免 pipefail + SIGPIPE 在大型 keychain 誤拒)。並「顯式檢查 security 退出碼」:在 `|| ` 語境 set -e
            # 會被停用,security 部分失敗(如某 keychain 損壞)卻印出一列匹配時不可誤判通過 → fail-closed。
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
            local _idout _rc _line _name _matches=0
            _idout="$(security find-identity -v -p codesigning 2>/dev/null)"; _rc=$?
            if [ "$_rc" -ne 0 ]; then
                echo "build-app: security find-identity 失敗(exit $_rc)— fail-closed,不產出 bundle" >&2
                return 1
            fi
            while IFS= read -r _line || [ -n "$_line" ]; do
                case "$_line" in
                    *[0-9]\)\ [0-9A-Fa-f][0-9A-Fa-f]*\ \"*\") ;;   # 「  N) <hex-hash> "NAME"」;摘要行不匹配
                    *) continue ;;
                esac
                _name="${_line#*\"}"; _name="${_name%\"*}"   # 首尾雙引號之間 = 完整身分名稱
                [ "$DEVELOPER_ID_IDENTITY" = "$_name" ] && _matches=$((_matches + 1))
            done <<EOF
$_idout
EOF
            # 須「恰好一個」相符:零個=不可解析;多個(如續期的同名憑證)=歧義,codesign 可能選到非預期的憑證 → fail-closed。
            if [ "$_matches" -eq 0 ]; then
                echo "build-app: Developer ID 身分不可解析(須精確等於某身分的完整名稱 'Name (TEAMID)'):'$DEVELOPER_ID_IDENTITY'" >&2
                return 1
            fi
            if [ "$_matches" -gt 1 ]; then
                echo "build-app: Developer ID 身分有 $_matches 個同名相符(歧義,codesign 可能選錯)— fail-closed:'$DEVELOPER_ID_IDENTITY'" >&2
                return 1
            fi
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

# 以 Developer ID 簽單一項目:Hardened Runtime(--options runtime)+ secure timestamp(--timestamp)。
# A1:預設「不帶」--entitlements —— 本 app 非 sandbox、行為調查無任何 Hardened Runtime 例外;僅在 ENTITLEMENTS
# 經實證必要時才對需要的項目加上。永不用 --deep 簽(--deep 會掩蓋漏簽的巢狀項;--deep 只在 verify 時用)。
_sign_item_developer_id() {
    local item="$1"
    if [ -n "$ENTITLEMENTS" ]; then
        codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID_IDENTITY" "$item"
    else
        codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_IDENTITY" "$item"
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
            _sign_item_developer_id "$app/Contents/MacOS/aipet" || return 1
            _sign_item_developer_id "$app" || return 1
            local verr
            if ! verr="$(codesign --verify --deep --strict "$app" 2>&1)"; then
                if grep -qF 'AIPetUsage_UsageCore.bundle' <<<"$verr"; then
                    # A2:資源 bundle 需要自己的簽名 —— 簽它(inside-out 最先),重簽外層(重新密封),複驗。
                    _sign_item_developer_id "$app/Contents/Resources/AIPetUsage_UsageCore.bundle" || return 1
                    _sign_item_developer_id "$app" || return 1
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

# developer-id 最終權威驗證(fail-closed):封印完整性 + 對「每個 executable-code 項」(aipet + 外層)斷言
# Developer ID 權威 + Team ID + Hardened Runtime flag,再斷言無 app-sandbox / 無 cs.* 例外(A1;對已簽二進位
# dump,非對 committed 檔)。spctl 不在此驗(它是 post-staple 檢查,此時尚未公證,spctl 會正確地拒絕)。
# 每個檢查皆顯式 return(不倚賴 set -e)。
verify_signature() {
    local app="$1"
    # 1) 封印完整性(遞迴);也是 A2 的仲裁者。
    codesign --verify --deep --strict "$app" || { echo "verify: --verify --deep --strict 失敗" >&2; return 1; }
    # 2) 預期 Team ID 必須可從身分推導(developer-id 的 canonical 形式 "Name (TEAMID)")。推不出(例如給 SHA-1
    #    hash 形式的身分選擇器)→ fail-closed:否則 team 斷言會被靜默跳過,錯誤團隊的簽章可能矇混過關。
    local want_team
    want_team="$(_expected_team_id)"
    if [ -z "$want_team" ]; then
        echo "verify: 無法從 DEVELOPER_ID_IDENTITY 推導預期 Team ID — 請用完整 'Name (TEAMID)' 形式" >&2
        return 1
    fi
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
        grep -Eq 'flags=.*runtime' <<<"$dv" \
            || { echo "verify: $item 缺 Hardened Runtime(runtime)flag" >&2; return 1; }
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
