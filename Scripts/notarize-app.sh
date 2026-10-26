#!/bin/bash
# notarize-app.sh — 公證 → 檢查狀態 → staple → 驗票 的有序編排(NOTARIZATION-PIPELINE 的 steps 6–12)。
#
# ⚠️ PR-B:本腳本為「新增但未接線」。沒有任何 workflow 呼叫它;它只定義函式讓 Scripts/test-signing-pipeline.sh 能以
#    fake 工具(xcrun/stapler/notarytool/spctl)離線驗證「編排會 fail-closed」。它不處理任何真實憑證、不聯繫 Apple、
#    不發佈任何東西(本檔內「沒有」gh / publish 呼叫)。把這段邏輯接進 release workflow、提供真實憑證、以及真正的
#    publish gate,都是 PR-C 的事(在另行核准的 fail-closed 遷移契約下)。
#
# 憑證介面(PR-C2 由 release workflow 以 $RUNNER_TEMP 下的檔案提供;PR-B/C1A harness 用 fake):
#   NOTARY_KEY_PATH   App Store Connect API key(.p8)的「檔案路徑」(SECRET 檔;永不以 inline 值傳遞)
#   NOTARY_KEY_ID     Key ID(非機密信任設定)
#   NOTARY_ISSUER_ID  Issuer ID(非機密信任設定)
# ⚠️ 未來 live 憑證「必須」是「Team」App Store Connect API key —— Apple 明載 Individual key「不可」用於 notarytool
#    (notaryTool requires a team-scoped key)。本腳本不建立、不描述、不內嵌任何真實 key;key 由 PR-C2 以 secret 提供。
# 秘密衛生(CI-CREDENTIAL-SECURITY):不得 set -x;不得 echo/cat 任何憑證;notarytool log 與 A4 驗證紀錄皆非秘密,可印。
set -euo pipefail

NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"

# Gate 5(PR-C1A):公證環境 fail-closed preflight。三個必要值任一缺失,或 NOTARY_KEY_PATH 不是「存在、一般檔、非空、
# 可讀」的 key 檔,即在「提交(xcrun notarytool submit)之前」非零退出 —— 避免以殘缺憑證打到 Apple(真實環境)或讓 fake
# 提交被誤認成功(測試環境)。目錄、空檔(例如空 secret 被寫成空 .p8)、不可讀檔都不是 key material(F-C)。只檢查檔案
# 形態,不解析 / 不驗證 .p8 內容(那是 Apple 端的事)。永不印任何值或路徑。
# 顯式 `|| return`(不倚賴 set -e):本函式可能在 `if …` 等停用 errexit 的語境被呼叫。
require_notary_env() {
    local missing=0
    [ -n "$NOTARY_KEY_PATH" ]  || { echo "notarize: 缺 NOTARY_KEY_PATH(ASC API key .p8 檔路徑)" >&2; missing=1; }
    [ -n "$NOTARY_KEY_ID" ]    || { echo "notarize: 缺 NOTARY_KEY_ID" >&2; missing=1; }
    [ -n "$NOTARY_ISSUER_ID" ] || { echo "notarize: 缺 NOTARY_ISSUER_ID" >&2; missing=1; }
    [ "$missing" -eq 0 ] || return 1
    if [ ! -f "$NOTARY_KEY_PATH" ] || [ ! -s "$NOTARY_KEY_PATH" ] || [ ! -r "$NOTARY_KEY_PATH" ]; then
        echo "notarize: NOTARY_KEY_PATH 須指向存在、一般檔、非空且可讀的 key 檔(不存在 / 目錄 / 空檔 / 不可讀 皆拒絕)" >&2
        return 1
    fi
    return 0
}

# step 7:提交公證並等待終態。印出 notarytool 的 JSON(供 check_status 解析);submit/auth 失敗即非零。
# key 以「檔案路徑」傳遞(不是 inline 值),且不出現在 process listing 的可見位置以外。提交前先跑 require_notary_env。
notarize_submit_wait() {
    local submit_zip="$1"
    require_notary_env || return 1
    xcrun notarytool submit "$submit_zip" \
        --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
        --wait --output-format json
}

# step 8:檢查終態。Accepted → 0;Invalid/Rejected → 擷取並印出 notarytool log、回傳非零(不 staple、不發佈);
# 其餘(In Progress / 逾時 / 無法解析)→ 非零 —— 永不假設成功。輸入 = submit 的 JSON。
check_status() {
    local json="$1" status id
    status="$(printf '%s' "$json" | jq -r '.status // empty' 2>/dev/null || true)"
    id="$(printf '%s' "$json" | jq -r '.id // empty' 2>/dev/null || true)"
    case "$status" in
        Accepted)
            if [ -z "$id" ]; then
                echo "notarize: 公證回報 Accepted 但缺 submission id(回應異常)— 視為失敗" >&2
                return 1
            fi
            return 0
            ;;
        Invalid | Rejected)
            echo "notarize: 公證遭拒(status=$status);擷取 notarytool log:" >&2
            if [ -n "$id" ]; then
                xcrun notarytool log "$id" \
                    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2 || true
            fi
            return 1
            ;;
        *)
            echo "notarize: 非 Accepted 終態(status='${status:-<none/unparseable>}')—— 永不假設成功" >&2
            return 1
            ;;
    esac
}

# step 9:staple 票據到 .app(ZIP 無法被 staple;票據要騎在被分發的 bundle 內以供離線 Gatekeeper 接受)。
staple() {
    local app="$1"
    xcrun stapler staple "$app"
}

# step 10:驗證已 staple 的票據。stapler validate 必須成功,且 spctl 必須 accepted 且 source=Notarized。
# 任一失敗即非零(發佈前的最後一道)。
validate_ticket() {
    local app="$1" out
    xcrun stapler validate "$app" || { echo "notarize: stapler validate 失敗" >&2; return 1; }
    # spctl 的「退出狀態」才是權威的接受訊號(0=accepted)。不可丟棄它改靠 'accepted' 子字串:'accepted' 會誤匹配
    # 'not accepted',且被拒時 spctl 可能把含 'accepted' 子字串的 app 路徑回顯進輸出。先要求 exit 0,再錨定核對
    # source=Notarized。
    if ! out="$(spctl -a -vvv -t exec "$app" 2>&1)"; then
        echo "notarize: spctl 拒絕(非零退出)" >&2; printf '%s\n' "$out" >&2; return 1
    fi
    # 「精確」核對 source 行必須「恰為」source=Notarized Developer ID(整行相符,僅容許無意義的尾端空白)。不可用
    # 前綴比對(^source=Notarized):那會放行 'source=NotarizedFake' 等任意以 Notarized 開頭的字串。也不可用未錨定
    # 子字串:一個路徑恰含 'source=Notarized' 的 app 在實際 source 為 'Developer ID'(非 Notarized)時會被回顯的
    # 路徑矇過。spctl 把 'source=Notarized Developer ID' 印成獨立一行,故錨定整行、容忍尾端空白即可。
    grep -qE '^source=Notarized Developer ID[[:space:]]*$' <<<"$out" \
        || { echo "notarize: spctl source 非 'Notarized Developer ID'(exact)" >&2; printf '%s\n' "$out" >&2; return 1; }
    return 0
}

# A3 硬性 publish gate(純述詞,無副作用、不呼叫 gh)。發佈的充要條件:MODE==release ∧ SIGN_MODE==developer-id ∧
# 公證 Accepted ∧ staple validated ∧ spctl accepted。任一不符即非零 —— 呼叫端(PR-C 的 release workflow)據此
# 在 gh release create「之前」擋下,使得就算 set -euo pipefail 的 step-abort 失效也無法在 adhoc / 未確認公證下發佈。
# 本函式刻意不執行任何發佈動作:PR-B 的 surface 內沒有 publish 路徑。
assert_publish_allowed() {
    local mode="$1" sign_mode="$2" notary_status="$3" staple_result="$4" spctl_result="$5"
    [ "$mode" = release ]            || { echo "publish-gate: MODE != release($mode)" >&2; return 1; }
    [ "$sign_mode" = developer-id ]  || { echo "publish-gate: SIGN_MODE != developer-id($sign_mode)" >&2; return 1; }
    [ "$notary_status" = Accepted ]  || { echo "publish-gate: 公證狀態 != Accepted($notary_status)" >&2; return 1; }
    [ "$staple_result" = validated ] || { echo "publish-gate: staple 未 validated($staple_result)" >&2; return 1; }
    [ "$spctl_result" = accepted ]   || { echo "publish-gate: spctl 未 accepted($spctl_result)" >&2; return 1; }
    return 0
}

# A4 驗證紀錄(FROZEN = rebuild + independent verification,option (ii))。連結:tag、commit、workflow run、最終
# ZIP sha256、公證 submission id + 狀態。全為非秘密,可印可存。「不」宣稱與任何 rehearsal 產物的跨回合 byte-equality。
emit_verification_record() {
    local tag="$1" commit="$2" run="$3" zip_sha256="$4" submission_id="$5" notary_status="$6"
    cat <<EOF
A4-VERIFICATION-RECORD
  tag=$tag
  commit=$commit
  run=$run
  final_zip_sha256=$zip_sha256
  notary_submission_id=$submission_id
  notary_status=$notary_status
  audited_identity=source commit + Developer-ID authority + Team ID + notarization Accepted + staple validated + this run's own ZIP sha256
  cross_run_byte_equality=NOT CLAIMED (A4=(ii) rebuild-verification; the tag run rebuilds, it does not promote a rehearsal artifact)
EOF
}

# 完整編排(steps 7–10),fail-closed。PR-C 由 release workflow 呼叫;PR-B 不接線。本函式「不」發佈、不呼叫 gh、
# 不 emit 紀錄(紀錄由呼叫端在確認 Accepted+validated 後以 emit_verification_record 產生)。
main() {
    local app="$1" submit_zip="$2" json
    # 每步顯式 `|| return` —— 不倚賴 set -e:當呼叫端以 `if main …; then`(或 &&/!/||)呼叫時,bash 會停用本
    # 函式內的 errexit,只靠 set -e 會在 Invalid 公證後仍繼續 staple/驗票並回報成功(fail-open)。顯式 return
    # 使 fail-closed 與呼叫語境無關。
    json="$(notarize_submit_wait "$submit_zip")" || { echo "notarize: 提交/等待失敗" >&2; return 1; }
    check_status "$json" || return 1
    staple "$app" || return 1
    validate_ticket "$app" || return 1
    echo "notarize-app: $app 已公證 + staple + 驗票通過(未發佈——發佈由 release workflow 在 publish gate 後進行)"
}

# source-guard:被 `source` 時只定義函式(harness 用);直接執行時跑完整編排(PR-C 用)。
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi
