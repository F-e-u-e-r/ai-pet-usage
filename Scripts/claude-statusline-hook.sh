#!/bin/bash
# AI Pet Usage 的 Claude Code statusline hook(原創實作)。
#
# Claude Code 每次刷新狀態列會把官方 JSON payload 餵進 statusline 指令的 stdin,
# 其中含 `rate_limits`(5 小時 / 週窗口的官方 used_percentage 與 resets_at)。
# 本腳本把「凍結白名單」落地到 AI Pet Usage 的資料夾供 adapter 讀取官方限額,
# 任何層級的其他欄位(session id / transcript path / cwd / 未來新欄位)一律丟棄。
# 本腳本不發送任何網路請求。
#
# 落地檔形狀(凍結 schema;巢狀欄位亦為白名單):
#   {"schema_version":1,"captured_at":"<UTC ISO8601>",
#    "model":{"id":<str|null>,"display_name":<str|null>} 或 null,
#    "rate_limits":{"five_hour":{"used_percentage":<num>[,"resets_at":<num>]},
#                   "seven_day":{...}}}
# 只在至少一個窗口「可用」(used_percentage 為有限數值;bool/NaN/Inf 不算)時才寫檔;
# payload 缺 rate_limits 或全窗不可用時**保留上一份好檔**(新鮮度由 app 依 mtime 判定)。
#
# 兩種模式:
#   獨立模式:本腳本自己就是 statusline —— 落地後印一行「🐾 …」狀態文字。
#     ~/.claude/settings.json:
#       "statusLine": {"type":"command","command":"/bin/bash <repo>/Scripts/claude-statusline-hook.sh"}
#   包裹模式(--wrap):你已有自訂 statusline 時用,**你的腳本與畫面完全不變**——
#     本腳本先盡力落地,再把「原始 stdin」原封不動餵給你的指令,
#     其 stdout / stderr / 退出碼原樣透傳(目標不存在 → 127、不可執行 → 126)。
#       "statusLine": {"type":"command","command":"/bin/bash <repo>/Scripts/claude-statusline-hook.sh --wrap /path/to/your-statusline"}
#     目標需具執行權限;純 shell 腳本可寫 --wrap /bin/bash -- /path/to/script.sh,
#     其餘參數放在 -- 之後逐一傳遞(不接受整串複合 shell 指令)。
#
# 失敗語義:telemetry(解析/寫檔/目錄/直譯器)一律 fail-soft —— 絕不阻擋被包裹的
# 指令、不污染其 stdout/stderr;「設定錯誤」(未知參數、--wrap 缺值、遞迴自包)
# 則 fail-loud:usage 印到 stderr、狀態列印出可見錯誤行、exit 2。
#
# 環境變數:AIPET_DATA_DIR(落地目錄,預設 ~/Library/Application Support/AIPetUsage)、
#   AIPET_STATUSLINE_PYTHON(解析直譯器,預設 /usr/bin/python3)。
# (若已有其他工具在保存同一 payload 至 ~/.claude/usage-status.json,毋需本腳本。)
#
# 強固性:內部工具一律用 macOS 絕對路徑(不受呼叫環境的 PATH 影響,也不改動下游
# 看到的 PATH);python 以 -I 隔離模式執行(cwd 的同名模組與 PYTHONPATH 都不得
# 介入 —— hook 的工作目錄是使用者的專案目錄,裡面可能有 json.py 之類的檔案)。
#
# Shell 選項透明性:先記下進入時的 SHELLOPTS 是否有被 export(只有 export 過才會
# 影響子 bash),並立刻關掉繼承的 xtrace / verbose —— 否則它們會把 hook 的內部命令
# (乃至 payload)trace/印到 stderr,污染下游 stderr。整個捕捉+關閉本身也用
# stderr 抑制包起來(這兩行在 set +x 生效前會被 trace,故先吞掉)。
# 包裹模式結尾會把「進入時的 SHELLOPTS」原封還給下游(parity):使用者若刻意
# export 了 errexit/pipefail 等選項,下游行為要與直接執行完全一致。
# 已知限制:若呼叫環境 export 了 SHELLOPTS=noexec,bash 會在啟動時就 parse-only、
# 不執行本腳本(回 0)—— 那是使用者自毀整個 statusline 環境,hook 內無法自救。
# set +a 必須在「任何賦值之前」關掉:若呼叫環境開了 allexport(set -a),否則本腳本
# 後續每個賦值(WRAP_TARGET / OUT_DIR / PYTHON_BIN / PY_EXTRACT …)都會被自動
# export 而洩漏給下游、破壞 parity(grok r3 #1)。ENTRY_SHELLOPTS 在 set +a 生效前
# 賦值,故一併 export -n。
{ ENTRY_SHELLOPTS="$(/usr/bin/printenv SHELLOPTS 2>/dev/null || :)"; set +a +x +v; export -n ENTRY_SHELLOPTS 2>/dev/null || :; } 2>/dev/null
set -euo pipefail

usage_error() {
    printf 'claude-statusline-hook: %s\nusage: claude-statusline-hook.sh [--wrap /path/to/statusline [-- args...]]\n' "$1" >&2
    printf '🐾 hook config error: %s' "$1"
    exit 2
}

# ---- 參數解析(set -u 下必須先初始化;不收整串 shell 指令,邊界由陣列保留) ----
WRAP_TARGET=""
FORWARD_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --wrap)
            [ -z "$WRAP_TARGET" ] || usage_error "duplicate --wrap"
            [ $# -ge 2 ] || usage_error "--wrap requires a path"
            [ -n "$2" ] || usage_error "--wrap requires a non-empty path"
            case "$2" in -*) usage_error "--wrap expects a path, got flag-like value: $2" ;; esac
            WRAP_TARGET="$2"
            shift 2 ;;
        --)
            [ -n "$WRAP_TARGET" ] || usage_error "'--' is only valid after --wrap"
            shift
            FORWARD_ARGS=("$@")
            break ;;
        *)
            usage_error "unknown argument: $1" ;;
    esac
done

# ---- 遞迴護欄(fail-loud;設定錯誤而非 telemetry 失敗) ----
# env 深度護欄抓「hook 內再包 hook」(含腳本副本);realpath 自比對抓直接與 symlink 自包。
# realpath 失敗(目標不存在)時退回原字串比較,不得中斷 —— 讓不存在的目標走到調用處回 127。
if [ -n "$WRAP_TARGET" ]; then
    [ -z "${AIPET_STATUSLINE_HOOK_ACTIVE:-}" ] || usage_error "recursive statusline hook invocation"
    self_path=$(/bin/realpath "$0" 2>/dev/null || printf '%s' "$0")
    target_path=$(/bin/realpath "$WRAP_TARGET" 2>/dev/null || printf '%s' "$WRAP_TARGET")
    [ "$self_path" != "$target_path" ] || usage_error "--wrap target is this hook itself"
fi

# ---- stdin 只讀一次;哨兵保住結尾換行(命令替換會剝尾端 newline,包裹模式需 byte 保真) ----
# (bash 變數不能存 NUL byte;合法 JSON payload 不含 NUL,故無影響。)
# set +a:關掉繼承的 allexport,否則 payload 會被自動 export 成環境變數傳給下游
# (完整未過濾內容洩漏,且夠大會讓下游 execve E2BIG)。用私有變數名並顯式 export -n,
# 連「呼叫者剛好已 export 同名變數」的情況也擋掉;呼叫者原本的 INPUT 環境變數保持不動。
set +a
_hook_stdin=$(/bin/cat; printf x)
_hook_stdin=${_hook_stdin%x}
export -n _hook_stdin 2>/dev/null || :

# HOME 未設時不得在 set -u 下死亡(fail-soft 優先),也不得把空 HOME 展開成 /Library:
# 無處可落地就走純顯示/純轉發路徑。
if [ -n "${AIPET_DATA_DIR:-}" ]; then
    OUT_DIR="$AIPET_DATA_DIR"
elif [ -n "${HOME:-}" ]; then
    OUT_DIR="$HOME/Library/Application Support/AIPetUsage"
else
    OUT_DIR=""
fi
PYTHON_BIN="${AIPET_STATUSLINE_PYTHON:-/usr/bin/python3}"

# 單一 python 行程:驗證型別、只重建白名單欄位、寫入臨時檔(僅當至少一窗可用)、
# 印出狀態列文字。寫檔例外時自行 unlink 半成品,確保永不落地壞檔。
# python 內只用雙引號,整段以單引號交給 bash。
PY_EXTRACT='
import json, math, os, stat, sys
from datetime import datetime, timezone

# 數值白名單:bool/NaN/Inf 之外,整數也限制在 IEEE double 可精確表示的範圍 ——
# python 的任意精度整數(如 400 位數)json.dumps 得出去,但 Foundation 的
# JSONSerialization 會整檔拒讀,等同用壞檔蓋掉好檔。
INT_BOUND = 2 ** 53

def num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v if -INT_BOUND <= v <= INT_BOUND else None
    if isinstance(v, float) and math.isfinite(v):
        return v
    return None

# 字串白名單:必須是合法 UTF-8 可編碼(lone surrogate 會讓 json.dumps 寫出
# Foundation 拒讀的跳脫序列)。
def safe_str(v):
    if not isinstance(v, str):
        return None
    try:
        v.encode("utf-8")
    except UnicodeEncodeError:
        return None
    return v

def window(v):
    if not isinstance(v, dict):
        return None
    pct = num(v.get("used_percentage"))
    if pct is None:
        pct = num(v.get("used_percent"))
    if pct is None:
        return None
    out = {"used_percentage": pct}
    resets = num(v.get("resets_at"))
    if resets is not None:
        out["resets_at"] = resets
    return out

d = json.load(sys.stdin)
if not isinstance(d, dict):
    d = {}
raw = d.get("rate_limits")
rl = {}
if isinstance(raw, dict):
    for key in ("five_hour", "seven_day"):
        w = window(raw.get(key))
        if w is not None:
            rl[key] = w

m = d.get("model")
model_out = None
if isinstance(m, dict):
    model_out = {"id": safe_str(m.get("id")),
                 "display_name": safe_str(m.get("display_name"))}

tmp_path = sys.argv[1] if len(sys.argv) > 1 else ""
if rl and tmp_path:
    out = {"schema_version": 1,
           "captured_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "model": model_out,
           "rate_limits": rl}
    try:
        payload = json.dumps(out).encode("utf-8")
        # 群組可寫目錄的 TOCTOU 防護:mktemp 與寫入之間若有人動了臨時檔就中止。
        #   O_NOFOLLOW    —— 換成 symlink → open 直接失敗(不跟隨到別人的檔案)。
        #   不帶 O_TRUNC  —— O_TRUNC 會在 fstat 把關「之前」就先截斷,攻擊者換成
        #                    指向受害檔的 hardlink 時會被當場清空;改成先驗證再截斷。
        #   fstat 三關卡 —— 必須是自己擁有的、單一連結(nlink==1,擋 hardlink)的
        #                    regular file,才 ftruncate + 寫入。
        fd = os.open(tmp_path, os.O_WRONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(fd)
            if (st.st_uid != os.getuid()
                    or not stat.S_ISREG(st.st_mode)
                    or st.st_nlink != 1):
                raise OSError("tmp file was tampered with")
            os.fchmod(fd, 0o600)   # 在已驗證的 fd 上收窄權限(不透過路徑名,避免再一次 TOCTOU)
            os.ftruncate(fd, 0)
            # 逐位元組寫完:os.write 可能短寫(磁碟滿/檔案大小上限),忽略回傳值會
            # 落地截斷的 JSON;回 0 或例外一律當失敗(下方 except 會 unlink)。
            total = 0
            while total < len(payload):
                n = os.write(fd, payload[total:])
                if n <= 0:
                    raise OSError("short write")
                total += n
        finally:
            os.close(fd)
    except Exception:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass

display = (model_out or {}).get("display_name") or "Claude"
def pct_text(key):
    w = rl.get(key)
    v = w.get("used_percentage") if w else None
    return f"{round(v)}%" if v is not None else "—"
five = pct_text("five_hour")
week = pct_text("seven_day")
sys.stdout.write(f"🐾 {display} · 5h {five} · wk {week}")
'

# ---- telemetry 全階段封裝:全 best-effort,stdout = 狀態列文字,回傳非零 = 解析失敗 ----
# 呼叫端一律以 subshell 執行(umask 077 不外洩給後續行程)並一次性抑制 stderr;
# 臨時檔生命週期自足:任一步失敗即自清,只有「非空 + 非目錄 + mv 全成功」才算落地
# (權限已由 python 在已驗證的 fd 上 fchmod 600)。
persist_and_render() {
    umask 077
    local tmp rendered dest
    tmp=""
    if [ -n "$OUT_DIR" ]; then
        /bin/mkdir -p "$OUT_DIR" || :
        # 只在資料夾「由自己擁有、且 group/other 皆不可寫」時才落地 —— 這一刀切掉
        # 群組可寫目錄的整個 TOCTOU 攻擊面(攻擊者根本無法在此放 symlink/hardlink
        # 或在 mktemp 與 mv 之間掉包)。這是 owned+private 目錄才啟用 telemetry 的
        # 硬性前提;普通單人 Mac 的預設資料夾天生符合(我們也 chmod 700)。
        # OUT_DIR 是普通檔案時 [ -d ] 為假,自然跳過(不動它的權限)。
        if [ -d "$OUT_DIR" ]; then
            local owner perms
            owner=$(/usr/bin/stat -f '%u' "$OUT_DIR" 2>/dev/null || printf '')
            # 先驗擁有權:只對「自己擁有」的目錄收窄權限並落地。非自己擁有的目錄
            # (他人的、系統的)一律不碰(不 chmod、不建檔)—— owner 檢查是防止在
            # 他人可寫目錄裡被 symlink/hardlink 掉包的主防線。
            if [ "$owner" = "$(/usr/bin/id -u)" ]; then
                /bin/chmod 700 "$OUT_DIR" || :
                # 清掃殘留臨時檔(persist 被看門狗 kill 掉時會留下)。只掃 10 分鐘以上的
                # 舊檔 —— 並行刷新中的活 tmp 只有幾秒壽命,絕不會被誤刪。
                /usr/bin/find "$OUT_DIR" -maxdepth 1 -name ".claude-statusline.json.*" -mmin +10 -delete 2>/dev/null || :
                # 收窄後再確認 group/other 皆不可寫(chmod 若因罕見原因失敗就不落地)。
                perms=$(/usr/bin/stat -f '%Lp' "$OUT_DIR" 2>/dev/null || printf '')
                if [ -n "$perms" ] && [ $((0$perms & 022)) -eq 0 ]; then
                    tmp=$(/usr/bin/mktemp "$OUT_DIR/.claude-statusline.json.XXXXXX") || tmp=""
                fi
            fi
        fi
    fi
    if ! rendered=$(printf '%s' "$_hook_stdin" | "$PYTHON_BIN" -I -c "$PY_EXTRACT" "$tmp"); then
        [ -z "$tmp" ] || /bin/rm -f "$tmp"
        return 1
    fi
    # 直譯器回 0 卻沒有輸出(壞掉的 AIPET_STATUSLINE_PYTHON 替身)不算成功:
    # 不落地、也讓獨立模式退固定字串,而不是印出空狀態列。
    if [ -z "$rendered" ]; then
        [ -z "$tmp" ] || /bin/rm -f "$tmp"
        return 1
    fi
    if [ -n "$tmp" ]; then
        dest="$OUT_DIR/claude-statusline.json"
        # 權限已由 python 在已驗證的 fd 上 fchmod 600(不再走路徑名 chmod)。
        # 落地目標若已是目錄(或指向目錄的 symlink),mv 會「搬進去」且回 0 —— 假成功,拒絕。
        if [ -s "$tmp" ] && [ ! -d "$dest" ] && /bin/mv -f "$tmp" "$dest"; then
            :
        else
            /bin/rm -f "$tmp"
        fi
    fi
    printf '%s' "$rendered"
    return 0
}

# ---- 獨立模式:顯示與落地解耦 —— 只有解析失敗/直譯器缺失才退固定字串, ----
# ---- 純落地失敗(目錄不可寫等)仍顯示真實百分比。 ----
if [ -z "$WRAP_TARGET" ]; then
    if LINE=$(persist_and_render 2>/dev/null); then
        printf '%s' "$LINE"
    else
        printf '🐾 Claude'
    fi
    exit 0
fi

# ---- 包裹模式:先盡力落地(stdout/stderr 全吞),再把原始 stdin 餵給你的指令。 ----
# 落地有看門狗上限:直譯器或檔案系統卡死時,最多延遲下游數秒,絕不永久擋住狀態列。
# 刻意不用 exec:bash 3.2 的 exec 失敗會把 127/126 摺疊成 1 或 126;
# 一般調用可原樣透傳 —— 下游退出碼精確保留(不存在 127、不可執行 126、
# 死於 signal 時為 bash 慣例的 128+n)。procsub 餵入端的 stderr 抑制,
# 下游不讀 stdin 時的 broken-pipe 訊息不會污染其 stderr。
# set -m:讓 persist 與看門狗兩個背景 job 各自成為 process group leader。
# persist(pgid==persist_pid)→ killpg 才能連 pipeline 裡的直譯器子行程一起殺
# (只殺 subshell 會讓卡死的直譯器變孤兒,每次刷新累積行程與臨時檔);
# 看門狗(pgid==watchdog_pid)→ 收尾 killpg 才能連它內部的 sleep 一起殺,
# 否則正常路徑會留下一個 sleep 孤兒睡滿 5 秒。
set -m
(persist_and_render) >/dev/null 2>&1 &
persist_pid=$!
( /bin/sleep 5; /bin/kill -9 -"$persist_pid" 2>/dev/null ) >/dev/null 2>&1 &
watchdog_pid=$!
set +m
# disown:看門狗不留在 job table,稍後把它 kill 掉時 bash 才不會在 stderr
# 印出「Killed: 9 …」的工作診斷(那會污染下游的 stderr)。
disown "$watchdog_pid" 2>/dev/null || :
wait "$persist_pid" >/dev/null 2>&1 || :
/bin/kill -9 -"$persist_pid" >/dev/null 2>&1 || :   # 清掉整組殘留(正常已結束時無害)
/bin/kill -9 -"$watchdog_pid" >/dev/null 2>&1 || : # killpg 看門狗:連它的 sleep 一起收

export AIPET_STATUSLINE_HOOK_ACTIVE=1
# 下游調用的 shell 選項 parity:
#   進入時 SHELLOPTS 有被 export → macOS bash 啟動時會 import 它(實測 errexit
#   會讓下游 bash 腳本的失敗命令中止、nounset 會報 unbound),所以本 hook 的
#   set -euo pipefail 會透過被 export 的 SHELLOPTS 傳染給下游。用 env(1) 把
#   「進入時的原值」還給下游(與直接執行一致),再用 bash -c '"$@"' trampoline
#   避免 BSD env 把「含 = 的 target 路徑」誤當環境賦值;trampoline 不用 exec,
#   一般調用才能保住 127(不存在)/126(不可執行)/128+n(signal)的區分。
#   沒 export → 下游本來就看不到我們的選項,直接調用即可。
# fd 導向:外層 { } 3>&2 2>/dev/null 把 fd3 設為原 stderr、group 的 stderr 丟到
#   /dev/null(吞掉 bash 對「下游死於 signal」印的 Terminated/Killed 診斷);
#   內層 cmd 2>&3 3>&- 把下游 stderr 接回原 stderr,並對下游關閉 fd3
#   (下游不得繼承這個借道用的 fd)。
set +e +u +o pipefail
if [ -n "$ENTRY_SHELLOPTS" ]; then
    { /usr/bin/env "SHELLOPTS=$ENTRY_SHELLOPTS" /bin/bash -c '"$@"' _ \
        "$WRAP_TARGET" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"} \
        < <(printf '%s' "$_hook_stdin" 2>/dev/null) 2>&3 3>&-; } 3>&2 2>/dev/null
else
    { "$WRAP_TARGET" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"} \
        < <(printf '%s' "$_hook_stdin" 2>/dev/null) 2>&3 3>&-; } 3>&2 2>/dev/null
fi
exit $?
