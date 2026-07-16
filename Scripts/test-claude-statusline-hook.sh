#!/bin/bash
# claude-statusline-hook.sh 的殼層測試套件(純 bash,無外部相依;macOS 專用 —— BSD stat)。
# 一律以系統 /bin/bash(3.2)執行 hook,與使用者機器一致;dev shell 的 bash 5 會遮蔽
# 3.2 的 set -u 空陣列等地雷,故所有調用都固定走 /bin/bash。
# timeout 一律用 python3 subprocess(macOS 無 GNU timeout,亦不得依賴 Homebrew coreutils)。
# 執行:/bin/bash Scripts/test-claude-statusline-hook.sh(任一失敗 → exit 非零)
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/claude-statusline-hook.sh"
PYBIN=/usr/bin/python3

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ✗ %s — %s\n' "$1" "$2"; }

# ---- 沙盒與調用 helpers ----------------------------------------------------

SB=""
DATA_DIR=""
new_sandbox() {
    SB=$(mktemp -d "${TMPDIR:-/tmp}/aipet-hook-test.XXXXXX")
    DATA_DIR="$SB/data dir"        # 刻意含空格
}
CLEANUP_DIRS=()
trap 'for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d"; done' EXIT
sandbox() { new_sandbox; CLEANUP_DIRS+=("$SB"); }

STATUS=0
# run_hook <stdin檔> [hook參數...]:stdout→$SB/out.bin,stderr→$SB/err.bin,退出碼→STATUS
run_hook() {
    local stdin_file="$1"; shift
    set +e
    env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" \
        /bin/bash "$HOOK" "$@" < "$stdin_file" > "$SB/out.bin" 2> "$SB/err.bin"
    STATUS=$?
    set -e
}

# run_hook_timeout <秒> <stdin檔> [hook參數...]:同上,但由 python3 看門狗限時(逾時 STATUS=124)
run_hook_timeout() {
    local secs="$1" stdin_file="$2"; shift 2
    set +e
    STATUS=$("$PYBIN" - "$secs" "$stdin_file" "$SB/out.bin" "$SB/err.bin" \
        env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" /bin/bash "$HOOK" "$@" <<'PYEOF'
import subprocess, sys
secs = float(sys.argv[1])
with open(sys.argv[2], "rb") as i, open(sys.argv[3], "wb") as o, open(sys.argv[4], "wb") as e:
    try:
        r = subprocess.run(sys.argv[5:], stdin=i, stdout=o, stderr=e, timeout=secs)
        print(r.returncode)
    except subprocess.TimeoutExpired:
        print(124)
PYEOF
)
    set -e
}

# 斷言 helpers(名稱 + 條件;失敗記錄但不中斷套件)
assert_status() {  # <名稱> <期望退出碼>
    if [ "$STATUS" -eq "$2" ]; then ok "$1"; else bad "$1" "exit=$STATUS, expected $2"; fi
}
assert_out_is() {  # <名稱> <期望 stdout 字串(byte-exact,無尾端換行)>
    printf '%s' "$2" > "$SB/expected.bin"
    if cmp -s "$SB/out.bin" "$SB/expected.bin"; then ok "$1"; else
        bad "$1" "stdout=$(cat "$SB/out.bin") expected=$2"; fi
}
assert_out_contains() {
    if grep -q "$2" "$SB/out.bin"; then ok "$1"; else bad "$1" "stdout=$(cat "$SB/out.bin")"; fi
}
assert_err_contains() {
    if grep -q "$2" "$SB/err.bin"; then ok "$1"; else bad "$1" "stderr=$(cat "$SB/err.bin")"; fi
}
assert_err_empty() {
    if [ ! -s "$SB/err.bin" ]; then ok "$1"; else bad "$1" "stderr=$(cat "$SB/err.bin")"; fi
}
assert_files_equal() {  # <名稱> <檔A> <檔B>
    if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$2 != $3"; fi
}
assert_no_landed() {  # <名稱>:落地檔不存在
    if [ ! -e "$DATA_DIR/claude-statusline.json" ]; then ok "$1"; else
        bad "$1" "unexpected landed file: $(cat "$DATA_DIR/claude-statusline.json")"; fi
}

LANDED=""
landed() { LANDED="$DATA_DIR/claude-statusline.json"; }

# 預埋一份「好檔」(固定舊 mtime),回頭比對內容與 mtime 都不被動 ——
# 內容相同但 mtime 被刷新會讓過期限額假裝新鮮(codex code-review r1 #6)。
SEED_MTIME=""
seed_good() {
    mkdir -p "$DATA_DIR"
    printf '%s' '{"schema_version":1,"captured_at":"2026-07-16T00:00:00Z","model":null,"rate_limits":{"five_hour":{"used_percentage":10}}}' \
        > "$DATA_DIR/claude-statusline.json"
    cp "$DATA_DIR/claude-statusline.json" "$SB/seed.bin"
    touch -t 202601010101 "$DATA_DIR/claude-statusline.json"
    SEED_MTIME=$(stat -f %m "$DATA_DIR/claude-statusline.json")
}
assert_seed_untouched() {
    landed
    if ! cmp -s "$LANDED" "$SB/seed.bin"; then bad "$1" "good file was clobbered"; return; fi
    if [ "$(stat -f %m "$LANDED")" != "$SEED_MTIME" ]; then bad "$1" "content same but mtime refreshed (fake freshness)"; return; fi
    ok "$1"
}

# ---- fixtures ---------------------------------------------------------------

# 完整 payload:各層都塞了必須被丟棄的欄位(session/cwd/未知窗口/窗內未知欄位/未知頂層)
FULL_PAYLOAD='{"session_id":"sekrit-session","cwd":"/Users/someone/project","transcript_path":"/tmp/t.jsonl","model":{"id":"claude-fable-5","display_name":"Fable","extra_model_field":"drop-me"},"rate_limits":{"five_hour":{"used_percentage":42.4,"resets_at":1789000000,"queue_depth":9},"seven_day":{"used_percentage":81,"resets_at":1789400000},"one_hour":{"used_percentage":5}},"unknown_top":"drop"}'
FULL_DISPLAY='🐾 Fable · 5h 42% · wk 81%'

write_full_payload() { printf '%s' "$FULL_PAYLOAD" > "$SB/payload.json"; }

make_stub() {  # make_stub <路徑>:讀完 stdin 存檔、印 STUB-OUT、stderr 印 STUB-ERR、exit 0
    # stub 內用 /bin/cat:敵意 PATH 測試(T34)下 stub 自身也不得依賴 PATH
    printf '#!/bin/bash\n/bin/cat > "%s"\nprintf STUB-OUT\nprintf STUB-ERR >&2\n' "$SB/stdin-capture.bin" > "$1"
    chmod +x "$1"
}

echo "== claude-statusline-hook test suite =="
echo "hook: $HOOK"

# ---- 1+2+3+4. 獨立模式 happy path:顯示、凍結 schema、權限、無殘留 ----------
sandbox; write_full_payload
run_hook "$SB/payload.json"
assert_status  "T01 standalone exit 0" 0
assert_out_is  "T01 standalone display byte-exact" "$FULL_DISPLAY"
landed
if "$PYBIN" - "$LANDED" <<'PYEOF'
import json, re, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
assert sorted(d) == ["captured_at", "model", "rate_limits", "schema_version"], sorted(d)
assert d["schema_version"] == 1
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", d["captured_at"]), d["captured_at"]
assert sorted(d["model"]) == ["display_name", "id"]
assert d["model"] == {"id": "claude-fable-5", "display_name": "Fable"}
rl = d["rate_limits"]
assert sorted(rl) == ["five_hour", "seven_day"], sorted(rl)
assert rl["five_hour"] == {"used_percentage": 42.4, "resets_at": 1789000000}, rl
assert rl["seven_day"] == {"used_percentage": 81, "resets_at": 1789400000}, rl
for tok in ("sekrit-session", "cwd", "transcript", "queue_depth", "one_hour",
            "unknown_top", "extra_model_field"):
    assert tok not in raw, tok
PYEOF
then ok "T02 frozen schema exact (allowlist at every level)"; else bad "T02 frozen schema" "landed=$(cat "$LANDED")"; fi
[ "$(stat -f %Lp "$LANDED")" = 600 ] && ok "T03 file perms 600" || bad "T03 file perms" "$(stat -f %Lp "$LANDED")"
[ "$(stat -f %Lp "$DATA_DIR")" = 700 ] && ok "T03 dir perms 700" || bad "T03 dir perms" "$(stat -f %Lp "$DATA_DIR")"
if ls "$DATA_DIR"/.claude-statusline.json.* >/dev/null 2>&1; then bad "T04 no tmp litter" "$(ls "$DATA_DIR")"; else ok "T04 no tmp litter"; fi

# ---- 5. wrap:stdin byte-identical(無尾端換行;\n\n 結尾) ------------------
sandbox; write_full_payload
make_stub "$SB/stub.sh"
run_hook "$SB/payload.json" --wrap "$SB/stub.sh"
assert_files_equal "T05 stdin byte-identical (no trailing newline)" "$SB/stdin-capture.bin" "$SB/payload.json"
printf '%s\n\n' "$FULL_PAYLOAD" > "$SB/payload-nl.json"
run_hook "$SB/payload-nl.json" --wrap "$SB/stub.sh"
assert_files_equal "T05 stdin byte-identical (trailing \\n\\n preserved)" "$SB/stdin-capture.bin" "$SB/payload-nl.json"

# ---- 6+7+8. wrap:stdout/stderr 透傳、exit 傳遞、落地照常 --------------------
sandbox; write_full_payload
make_stub "$SB/stub.sh"
run_hook "$SB/payload.json" --wrap "$SB/stub.sh"     # stub 無 args → 抓 bash 3.2 空陣列地雷
assert_status  "T06 wrap exit 0" 0
assert_out_is  "T06 wrap stdout passthrough exact" "STUB-OUT"
printf '%s' 'STUB-ERR' > "$SB/expected-err.bin"
assert_files_equal "T08 wrap stderr passthrough exact (zero contamination)" "$SB/err.bin" "$SB/expected-err.bin"
landed
[ -s "$LANDED" ] && ok "T06 wrap still lands file" || bad "T06 wrap lands file" "missing"
printf '#!/bin/bash\ncat >/dev/null\nexit 3\n' > "$SB/exit3.sh"; chmod +x "$SB/exit3.sh"
run_hook "$SB/payload.json" --wrap "$SB/exit3.sh"
assert_status "T07 downstream exit 3 preserved" 3

# ---- 9+10. 壞 JSON:預埋好檔不動;wrap 下游照跑;standalone 退固定字串 -------
sandbox; seed_good
printf '%s' 'not json {' > "$SB/bad.json"
make_stub "$SB/stub.sh"
run_hook "$SB/bad.json" --wrap "$SB/stub.sh"
assert_status "T09 malformed+wrap exit 0" 0
assert_out_is "T09 malformed+wrap downstream stdout" "STUB-OUT"
assert_seed_untouched "T09 malformed+wrap no clobber"
run_hook "$SB/bad.json"
assert_status "T10 malformed standalone exit 0" 0
assert_out_is "T10 malformed standalone fallback" "🐾 Claude"
assert_seed_untouched "T10 malformed standalone no clobber"

# ---- 11. 直譯器缺失:wrap 下游照跑;standalone 退固定字串 --------------------
sandbox; write_full_payload; seed_good
make_stub "$SB/stub.sh"
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" AIPET_STATUSLINE_PYTHON=/nonexistent/python3 \
    /bin/bash "$HOOK" --wrap "$SB/stub.sh" < "$SB/payload.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T11 missing interpreter + wrap exit 0" 0
assert_out_is "T11 missing interpreter + wrap downstream runs" "STUB-OUT"
assert_seed_untouched "T11 missing interpreter no clobber"
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" AIPET_STATUSLINE_PYTHON=/nonexistent/python3 \
    /bin/bash "$HOOK" < "$SB/payload.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T11 missing interpreter standalone exit 0" 0
assert_out_is "T11 missing interpreter standalone fallback" "🐾 Claude"

# ---- 12. rate_limits 缺失 / null:不覆蓋、顯示 —、wrap 照跑 ------------------
sandbox; seed_good
make_stub "$SB/stub.sh"
printf '%s' '{"model":{"id":"m","display_name":"Fable"}}' > "$SB/norl.json"
run_hook "$SB/norl.json"
assert_status "T12 missing rate_limits standalone exit 0" 0
assert_out_is "T12 missing rate_limits display em-dashes" '🐾 Fable · 5h — · wk —'
assert_seed_untouched "T12 missing rate_limits no clobber"
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":null}' > "$SB/nullrl.json"
run_hook "$SB/nullrl.json"
assert_seed_untouched "T12 null rate_limits no clobber"
run_hook "$SB/norl.json" --wrap "$SB/stub.sh"
assert_status "T12 missing rate_limits + wrap exit 0" 0
assert_out_is "T12 missing rate_limits + wrap downstream" "STUB-OUT"

# ---- 13. wrap 目標在含空格路徑 ----------------------------------------------
sandbox; write_full_payload
mkdir -p "$SB/wrap target dir"
make_stub "$SB/wrap target dir/my status line.sh"
run_hook "$SB/payload.json" --wrap "$SB/wrap target dir/my status line.sh"
assert_status "T13 spaced wrap path exit 0" 0
assert_out_is "T13 spaced wrap path stdout" "STUB-OUT"
assert_files_equal "T13 spaced wrap path stdin" "$SB/stdin-capture.bin" "$SB/payload.json"

# ---- 14. -- 之後參數邊界保留 -------------------------------------------------
sandbox; write_full_payload
printf '#!/bin/bash\ncat >/dev/null\n{ printf "%%s\\n" "$#"; printf "%%s\\n" "$@"; } > "%s"\n' "$SB/args-capture.txt" > "$SB/argstub.sh"
chmod +x "$SB/argstub.sh"
run_hook "$SB/payload.json" --wrap "$SB/argstub.sh" -- "arg one" "two  spaces" ""
printf '3\narg one\ntwo  spaces\n\n' > "$SB/args-expected.txt"
assert_files_equal "T14 arg boundaries preserved (spaces + empty arg)" "$SB/args-capture.txt" "$SB/args-expected.txt"

# ---- 15+27+30. 遞迴護欄:直接自包、symlink 自包、env 深度護欄 ----------------
sandbox; write_full_payload
run_hook_timeout 10 "$SB/payload.json" --wrap "$HOOK"
assert_status "T15 direct self-wrap exit 2" 2
assert_out_contains "T15 direct self-wrap config error" "hook config error"
ln -s "$HOOK" "$SB/alias-hook.sh"
run_hook_timeout 10 "$SB/payload.json" --wrap "$SB/alias-hook.sh"
assert_status "T27 symlink self-wrap exit 2 (realpath, not string compare)" 2
assert_out_contains "T27 symlink self-wrap config error" "hook config error"
make_stub "$SB/stub.sh"
set +e
STATUS=$("$PYBIN" - 10 "$SB/payload.json" "$SB/out.bin" "$SB/err.bin" \
    env AIPET_STATUSLINE_HOOK_ACTIVE=1 AIPET_DATA_DIR="$DATA_DIR" /bin/bash "$HOOK" --wrap "$SB/stub.sh" <<'PYEOF'
import subprocess, sys
secs = float(sys.argv[1])
with open(sys.argv[2], "rb") as i, open(sys.argv[3], "wb") as o, open(sys.argv[4], "wb") as e:
    try:
        r = subprocess.run(sys.argv[5:], stdin=i, stdout=o, stderr=e, timeout=secs)
        print(r.returncode)
    except subprocess.TimeoutExpired:
        print(124)
PYEOF
)
set -e
assert_status "T30 env depth guard exit 2 (copy/indirect recursion)" 2
assert_out_contains "T30 env depth guard config error" "hook config error"

# ---- 16. 設定錯誤 fail-loud --------------------------------------------------
sandbox; write_full_payload
for badargs in "--frobnicate" "--wrap" "--wrap|" "--wrap|--" "--wrap|-foo" "--wrap|a|--wrap|b" "--"; do
    IFS='|' read -r -a ARGV <<< "$badargs"
    # "--wrap|" 代表 --wrap 帶空字串值
    if [ "$badargs" = "--wrap|" ]; then ARGV=("--wrap" ""); fi
    run_hook "$SB/payload.json" ${ARGV[@]+"${ARGV[@]}"}
    assert_status "T16 config error ($badargs) exit 2" 2
    assert_err_contains "T16 config error ($badargs) usage on stderr" "usage:"
    assert_out_contains "T16 config error ($badargs) visible line" "hook config error"
done

# ---- 17. 靜態 lint:禁 eval token(全文含註解) ------------------------------
if grep -Eq '(^|[^[:alnum:]_.])eval([^[:alnum:]_]|$)' "$HOOK"; then
    bad "T17 no-eval lint" "found forbidden token"
else ok "T17 no-eval lint"; fi

# ---- 17b. TOCTOU 防護哨兵:三道 gate 不得被 regression 拿掉(grok r2 #1 已實測 ----
# O_TRUNC 版會清空 hardlinked victim;修正版 nlink!=1 會 REJECT)。黑盒無法穩定
# 注入 mktemp 後的 race,故以靜態斷言鎖住防護不回歸。
# 用 os.O_ 前綴精確鎖「程式碼實際旗標」,不被註解裡的 O_TRUNC 字樣干擾。
if grep -q 'os\.O_NOFOLLOW' "$HOOK" && ! grep -q 'os\.O_TRUNC' "$HOOK" && grep -q 'st_nlink != 1' "$HOOK"; then
    ok "T17b TOCTOU gate intact (os.O_NOFOLLOW, no os.O_TRUNC, nlink==1 check)"
else bad "T17b TOCTOU gate" "protection weakened"; fi

# ---- 18. 下游不讀 stdin(128KB payload):exit 0、stdout 精確、stderr 空 ------
sandbox
"$PYBIN" -c 'import json,sys; sys.stdout.write(json.dumps({"junk":"x"*131072,"rate_limits":{"five_hour":{"used_percentage":42}}}))' > "$SB/big.json"
printf '#!/bin/bash\nexec <&-\nprintf NOREAD\n' > "$SB/noread.sh"; chmod +x "$SB/noread.sh"
run_hook "$SB/big.json" --wrap "$SB/noread.sh"
assert_status "T18 downstream ignores stdin exit 0" 0
assert_out_is "T18 downstream ignores stdin stdout exact" "NOREAD"
assert_err_empty "T18 downstream ignores stdin stderr empty (no broken-pipe noise)"

# ---- 19+20+24. 無用窗口不得蓋好檔;bool 不算數;未知欄位不落地 ----------------
sandbox; seed_good
make_stub "$SB/stub.sh"
for p in '{"rate_limits":{"five_hour":null}}' \
         '{"rate_limits":{"five_hour":"unavailable"}}' \
         '{"rate_limits":{"five_hour":{}}}' \
         '{"rate_limits":{"five_hour":{"resets_at":1789000000}}}' \
         '{"rate_limits":{"one_hour":{"used_percentage":5}}}' \
         '{"rate_limits":{"five_hour":{"used_percentage":true}}}' \
         '{"rate_limits":{}}'; do
    printf '%s' "$p" > "$SB/p.json"
    run_hook "$SB/p.json"
    assert_status "T19/20/24 unusable window standalone exit 0 ($p)" 0
    assert_seed_untouched "T19/20/24 unusable window no clobber ($p)"
done
run_hook "$SB/p.json" --wrap "$SB/stub.sh"
assert_out_is "T19 unusable window + wrap downstream runs" "STUB-OUT"

# ---- 21. 單一 usable 窗口:只落該窗,另一窗顯示 — -----------------------------
sandbox
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42.4,"resets_at":1789000000},"seven_day":{"used_percentage":"n/a"}}}' > "$SB/one.json"
run_hook "$SB/one.json"
assert_out_is "T21 single usable window display" '🐾 Fable · 5h 42% · wk —'
landed
if "$PYBIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); rl=d["rate_limits"]; assert sorted(rl)==["five_hour"], rl' "$LANDED"; then
    ok "T21 single usable window landed alone"
else bad "T21 single usable window" "$(cat "$LANDED")"; fi

# ---- 22+23. 0% 有效不得變 —;101% 不截斷 -------------------------------------
sandbox
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":101}}}' > "$SB/edge.json"
run_hook "$SB/edge.json"
assert_out_is "T22/23 zero and over-100 display" '🐾 Fable · 5h 0% · wk 101%'
landed
if "$PYBIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); rl=d["rate_limits"]; assert rl["five_hour"]["used_percentage"]==0; assert rl["seven_day"]["used_percentage"]==101' "$LANDED"; then
    ok "T22/23 zero and over-100 landed verbatim"
else bad "T22/23 landed values" "$(cat "$LANDED")"; fi

# ---- 25+26. wrap 目標不存在 → 127;不可執行 → 126;不遮蔽、無 fallback --------
sandbox; write_full_payload
run_hook "$SB/payload.json" --wrap "$SB/does-not-exist.sh"
assert_status "T25 missing target exit 127" 127
assert_err_contains "T25 missing target bash error on stderr" "No such file"
if grep -q '🐾' "$SB/out.bin"; then bad "T25 no fallback on stdout" "$(cat "$SB/out.bin")"; else ok "T25 no fallback on stdout"; fi
landed
[ -s "$LANDED" ] && ok "T25 landing still happened before failure" || bad "T25 landing" "missing"
printf '#!/bin/bash\nprintf never\n' > "$SB/noexec.sh"; chmod 644 "$SB/noexec.sh"
rm -f "$DATA_DIR/claude-statusline.json"
run_hook "$SB/payload.json" --wrap "$SB/noexec.sh"
assert_status "T26 non-executable target exit 126" 126
assert_err_contains "T26 non-executable bash error on stderr" "Permission denied"
if grep -q '🐾' "$SB/out.bin"; then bad "T26 no fallback on stdout" "$(cat "$SB/out.bin")"; else ok "T26 no fallback on stdout"; fi
landed
[ -s "$LANDED" ] && ok "T26 landing still happened before failure" || bad "T26 landing" "missing"

# ---- 28. AIPET_DATA_DIR 是普通檔案:顯示不受累(解耦);wrap 不受累;檔案不被動 ----
sandbox; write_full_payload
DATA_DIR="$SB/plainfile"
printf 'do not touch' > "$DATA_DIR"
BEFORE_MODE=$(stat -f %Lp "$DATA_DIR")
run_hook "$SB/payload.json"
assert_status "T28 datadir-is-file standalone exit 0" 0
assert_out_is "T28 datadir-is-file standalone still renders real percents" "$FULL_DISPLAY"
[ "$(cat "$DATA_DIR")" = 'do not touch' ] && ok "T28 plain file content untouched" || bad "T28 plain file" "content changed"
[ "$(stat -f %Lp "$DATA_DIR")" = "$BEFORE_MODE" ] && ok "T28 plain file mode untouched" || bad "T28 plain file mode" "was $BEFORE_MODE now $(stat -f %Lp "$DATA_DIR")"
make_stub "$SB/stub.sh"
run_hook "$SB/payload.json" --wrap "$SB/stub.sh"
assert_status "T28 datadir-is-file wrap exit 0" 0
assert_out_is "T28 datadir-is-file wrap stdout" "STUB-OUT"
printf '%s' 'STUB-ERR' > "$SB/expected-err.bin"
assert_files_equal "T28 datadir-is-file wrap stderr clean" "$SB/err.bin" "$SB/expected-err.bin"

# ---- 29. 大型 malformed JSON(extraction SIGPIPE 邊界):下游照跑 --------------
sandbox; seed_good
{ printf 'not json {'; "$PYBIN" -c 'print("x"*262144)'; } > "$SB/bigbad.json"
make_stub "$SB/stub.sh"
run_hook "$SB/bigbad.json" --wrap "$SB/stub.sh"
assert_status "T29 big malformed + wrap exit 0" 0
assert_out_is "T29 big malformed + wrap downstream stdout" "STUB-OUT"
printf '%s' 'STUB-ERR' > "$SB/expected-err.bin"
assert_files_equal "T29 big malformed + wrap stderr only downstream's" "$SB/err.bin" "$SB/expected-err.bin"
assert_seed_untouched "T29 big malformed no clobber"

# ---- 31. used_percent fallback → 正規化為 used_percentage ---------------------
sandbox
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percent":42.4,"resets_at":1789000000}}}' > "$SB/alt.json"
run_hook "$SB/alt.json"
assert_out_is "T31 used_percent display" '🐾 Fable · 5h 42% · wk —'
landed
if "$PYBIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); w=d["rate_limits"]["five_hour"]; assert w=={"used_percentage":42.4,"resets_at":1789000000}, w' "$LANDED"; then
    ok "T31 used_percent normalized on disk"
else bad "T31 used_percent normalization" "$(cat "$LANDED")"; fi

# ---- 32. 黑盒全形狀比對(未知欄位塞滿各層後,落地檔恰為凍結 schema) ------------
sandbox; write_full_payload
run_hook "$SB/payload.json"
landed
if "$PYBIN" - "$LANDED" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
ca = d.pop("captured_at")
assert isinstance(ca, str) and ca.endswith("Z")
assert d == {"schema_version": 1,
             "model": {"id": "claude-fable-5", "display_name": "Fable"},
             "rate_limits": {"five_hour": {"used_percentage": 42.4, "resets_at": 1789000000},
                             "seven_day": {"used_percentage": 81, "resets_at": 1789400000}}}, d
PYEOF
then ok "T32 whole-object frozen schema equality (minus timestamp)"; else bad "T32 whole-object equality" "$(cat "$LANDED")"; fi

# ---- 33. NaN / Inf:不落地、安全顯示、resets_at NaN 丟欄位保窗口 ---------------
sandbox; seed_good
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":NaN},"seven_day":{"used_percentage":Infinity}}}' > "$SB/nan.json"
run_hook "$SB/nan.json"
assert_status "T33 NaN/Inf standalone exit 0" 0
assert_out_is "T33 NaN/Inf display em-dashes" '🐾 Fable · 5h — · wk —'
assert_seed_untouched "T33 NaN/Inf no clobber"
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":NaN}}}' > "$SB/nanreset.json"
run_hook "$SB/nanreset.json"
landed
if "$PYBIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); w=d["rate_limits"]["five_hour"]; assert w=={"used_percentage":42}, w' "$LANDED"; then
    ok "T33 NaN resets_at dropped, window kept"
else bad "T33 NaN resets_at" "$(cat "$LANDED")"; fi

# ---- 29b. 直譯器不讀 stdin 就退出(真 SIGPIPE 邊界;json.load 讀到 EOF 故 29 不觸發) ----
sandbox; seed_good
printf '#!/bin/bash\nexit 0\n' > "$SB/pystub.sh"; chmod +x "$SB/pystub.sh"
"$PYBIN" -c 'import json,sys; sys.stdout.write(json.dumps({"junk":"x"*262144}))' > "$SB/big2.json"
make_stub "$SB/stub.sh"
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" AIPET_STATUSLINE_PYTHON="$SB/pystub.sh" \
    /bin/bash "$HOOK" --wrap "$SB/stub.sh" < "$SB/big2.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T29b interpreter exits without reading (256KB) + wrap exit 0" 0
assert_out_is "T29b downstream stdout intact" "STUB-OUT"
printf '%s' 'STUB-ERR' > "$SB/expected-err.bin"
assert_files_equal "T29b stderr only downstream's" "$SB/err.bin" "$SB/expected-err.bin"
assert_seed_untouched "T29b no clobber"

# ---- 34. 敵意/空 PATH:hook 內部工具全走絕對路徑,不受 PATH 影響 ---------------
sandbox; write_full_payload
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE PATH=/nonexistent AIPET_DATA_DIR="$DATA_DIR" \
    /bin/bash "$HOOK" < "$SB/payload.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T34 hostile PATH standalone exit 0" 0
assert_out_is "T34 hostile PATH standalone display" "$FULL_DISPLAY"
landed
[ -s "$LANDED" ] && ok "T34 hostile PATH still lands" || bad "T34 hostile PATH landing" "missing"
make_stub "$SB/stub.sh"
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE PATH=/nonexistent AIPET_DATA_DIR="$DATA_DIR" \
    /bin/bash "$HOOK" --wrap "$SB/stub.sh" < "$SB/payload.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T34 hostile PATH wrap exit 0" 0
assert_out_is "T34 hostile PATH wrap stdout" "STUB-OUT"
assert_files_equal "T34 hostile PATH wrap stdin byte-identical" "$SB/stdin-capture.bin" "$SB/payload.json"

# ---- 35. python -I 隔離:cwd 的 json.py 與敵意 PYTHONPATH 均不得介入 ----------
sandbox; write_full_payload
printf 'raise SystemExit(97)\n' > "$SB/json.py"
set +e
( cd "$SB" && env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" PYTHONPATH="$SB" \
    /bin/bash "$HOOK" < "$SB/payload.json" > "$SB/out.bin" 2> "$SB/err.bin" )
STATUS=$?
set -e
assert_status "T35 cwd json.py shadow + PYTHONPATH standalone exit 0" 0
assert_out_is "T35 isolated interpreter renders normally" "$FULL_DISPLAY"
landed
[ -s "$LANDED" ] && ok "T35 isolated interpreter still lands" || bad "T35 landing" "missing"

# ---- 36. 合法但非物件的頂層 JSON:正常「無資料」顯示,不是解析失敗 fallback ------
sandbox; seed_good
for p in 'null' '[]' '"x"'; do
    printf '%s' "$p" > "$SB/p.json"
    run_hook "$SB/p.json"
    assert_status "T36 non-dict payload ($p) exit 0" 0
    assert_out_is "T36 non-dict payload ($p) renders em-dashes" '🐾 Claude · 5h — · wk —'
    assert_seed_untouched "T36 non-dict payload ($p) no clobber"
done

# ---- 37. HOME 未設且無 AIPET_DATA_DIR:不得死於 set -u;顯示/轉發照常 ----------
sandbox; write_full_payload
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE -u HOME -u AIPET_DATA_DIR \
    /bin/bash "$HOOK" < "$SB/payload.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T37 unset HOME standalone exit 0" 0
assert_out_is "T37 unset HOME still renders real percents" "$FULL_DISPLAY"
make_stub "$SB/stub.sh"
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE -u HOME -u AIPET_DATA_DIR \
    /bin/bash "$HOOK" --wrap "$SB/stub.sh" < "$SB/payload.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T37 unset HOME wrap exit 0" 0
assert_out_is "T37 unset HOME wrap downstream runs" "STUB-OUT"

# ---- 38. 落地路徑已是目錄:mv 不得「搬進去」假成功;無殘留;顯示照常 -------------
sandbox; write_full_payload
mkdir -p "$DATA_DIR/claude-statusline.json"
run_hook "$SB/payload.json"
assert_status "T38 dest-is-directory standalone exit 0" 0
assert_out_is "T38 dest-is-directory still renders" "$FULL_DISPLAY"
[ -d "$DATA_DIR/claude-statusline.json" ] && ok "T38 directory left as-is" || bad "T38 directory" "replaced"
if [ -z "$(ls -A "$DATA_DIR/claude-statusline.json")" ]; then ok "T38 nothing moved inside the directory"; else
    bad "T38 no move-into-dir" "$(ls -A "$DATA_DIR/claude-statusline.json")"; fi
if ls "$DATA_DIR"/.claude-statusline.json.* >/dev/null 2>&1; then bad "T38 no tmp litter" "$(ls "$DATA_DIR")"; else ok "T38 no tmp litter"; fi

# ---- 39. SHELLOPTS 透明性(parity;codex r1 #3、r2 #1/#3) ----------------------
# 用「功能性」檢查而非查 $- / $SHELLOPTS 字串 —— 實測 macOS bash 3.2 非互動啟動時
# 這兩個變數不反映實際選項狀態,但選項本身確實生效(env SHELLOPTS=errexit 會讓
# 下游 bash 腳本的 false 中止)。故用 false→是否續跑 來判斷 errexit 有沒有傳染。
sandbox; write_full_payload
# optstub:errexit 生效時 false 會中止 → 不印 AFTER-FALSE。
printf '#!/bin/bash\n/bin/cat >/dev/null\nfalse\nprintf AFTER-FALSE\n' > "$SB/optstub.sh"; chmod +x "$SB/optstub.sh"
# (a) 呼叫環境 export SHELLOPTS(含 errexit)→ 下游應繼承而中止(parity)。
# (退出碼此處會是 1 —— 下游因 errexit 在 false 中止,那正是要驗的 parity,故不斷言 exit 0)
set +e
/bin/bash -c 'set -e; export SHELLOPTS; exec env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$1" /bin/bash "$2" --wrap "$3" < "$4"' \
    _ "$DATA_DIR" "$HOOK" "$SB/optstub.sh" "$SB/payload.json" > "$SB/out.bin" 2>/dev/null
set -e
if grep -q 'AFTER-FALSE' "$SB/out.bin"; then
    bad "T39a parity: exported errexit must reach downstream" "downstream did not abort on false"
else ok "T39a parity: exported errexit reaches downstream (aborts on false)"; fi
# (b) 沒 export → hook 自己的 errexit 不得洩漏(下游續跑,印 AFTER-FALSE)。
run_hook "$SB/payload.json" --wrap "$SB/optstub.sh"
if grep -q 'AFTER-FALSE' "$SB/out.bin"; then
    ok "T39b no export: hook errexit does not leak (downstream continues)"
else bad "T39b hook errexit leaked to downstream" "downstream aborted on false"; fi
# (c) 繼承 xtrace 時,payload(session id/cwd)絕不得 trace 到 stderr(隱私)。
printf '%s' '{"session_id":"LEAKME-SESSION","cwd":"/Users/leak/cwd","rate_limits":{"five_hour":{"used_percentage":1}}}' > "$SB/leak.json"
printf '#!/bin/bash\n/bin/cat >/dev/null\nprintf QUIET\n' > "$SB/quiet.sh"; chmod +x "$SB/quiet.sh"
set +e
/bin/bash -c 'set -x; export SHELLOPTS; exec env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$1" /bin/bash "$2" --wrap "$3" < "$4"' \
    _ "$DATA_DIR" "$HOOK" "$SB/quiet.sh" "$SB/leak.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T39c inherited xtrace wrap exit 0" 0
if grep -q 'LEAKME-SESSION\|/Users/leak/cwd' "$SB/err.bin"; then
    bad "T39c payload must never appear on stderr under inherited xtrace" "$(head -5 "$SB/err.bin")"
else ok "T39c no payload leak under inherited xtrace"; fi
# (d) exported SHELLOPTS + target 路徑含 '='(BSD env 會誤當環境賦值)→ 仍執行 target。
mkdir -p "$SB/eq dir"
printf '#!/bin/bash\n/bin/cat >/dev/null\nprintf EQ-RAN\n' > "$SB/eq dir/a=b.sh"; chmod +x "$SB/eq dir/a=b.sh"
set +e
/bin/bash -c 'set -e; export SHELLOPTS; exec env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$1" /bin/bash "$2" --wrap "$3" < "$4"' \
    _ "$DATA_DIR" "$HOOK" "$SB/eq dir/a=b.sh" "$SB/payload.json" > "$SB/out.bin" 2>/dev/null
STATUS=$?
set -e
assert_status "T39d exported SHELLOPTS + '=' target exit 0" 0
assert_out_is "T39d '=' target still runs under trampoline" "EQ-RAN"

# ---- 49. fd 3 不得洩漏給下游(stderr shim 用完即關) --------------------------
sandbox; write_full_payload
# 下游探測 fd3:開得成(dup 成功)= 洩漏;開不成 = 已關閉(預期)。
printf '#!/bin/bash\n/bin/cat >/dev/null\nif { true >&3; } 2>/dev/null; then printf FD3-OPEN; else printf FD3-CLOSED; fi\n' > "$SB/fd3.sh"; chmod +x "$SB/fd3.sh"
run_hook "$SB/payload.json" --wrap "$SB/fd3.sh"
assert_out_is "T49 fd3 closed for downstream (not leaked)" "FD3-CLOSED"

# ---- 50a. 我擁有但曾 group/other 可寫的目錄:hook 收窄成 700 後才落地 ----------
sandbox; write_full_payload
mkdir -p "$DATA_DIR"; chmod 777 "$DATA_DIR"
run_hook "$SB/payload.json"
assert_status "T50a own-but-777 dir standalone exit 0" 0
assert_out_is "T50a own-but-777 dir renders real percents" "$FULL_DISPLAY"
[ "$(stat -f %Lp "$DATA_DIR")" = 700 ] && ok "T50a dir narrowed to 700 before landing" || bad "T50a dir perms" "$(stat -f %Lp "$DATA_DIR")"
landed; [ -s "$LANDED" ] && ok "T50a lands after narrowing (own dir)" || bad "T50a landing" "missing"

# ---- 50b. 非自己擁有的目錄:owner 檢查拒絕落地;不 chmod、不建檔;顯示照常 -------
# 用系統目錄 /(owner=root)—— hook 因 owner≠自己而完全不碰它,故安全不污染。
sandbox; write_full_payload
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="/" \
    /bin/bash "$HOOK" < "$SB/payload.json" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T50b non-owned dir standalone exit 0" 0
assert_out_is "T50b non-owned dir still renders real percents" "$FULL_DISPLAY"
[ ! -e "/claude-statusline.json" ] && ok "T50b refuses to land in non-owned dir" || bad "T50b landed in /" "unexpected file at /claude-statusline.json"
make_stub "$SB/stub.sh"
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="/" \
    /bin/bash "$HOOK" --wrap "$SB/stub.sh" < "$SB/payload.json" > "$SB/out.bin" 2>/dev/null
STATUS=$?
set -e
assert_status "T50b non-owned dir wrap exit 0" 0
assert_out_is "T50b non-owned dir wrap downstream runs" "STUB-OUT"

# ---- 50c. owner 檢查哨兵:防護不得被 regression 拿掉 --------------------------
grep -q 'id -u' "$HOOK" && grep -q 'stat -f' "$HOOK" \
    && ok "T50c owner/perms gate present in hook" \
    || bad "T50c owner gate" "removed"

# ---- 51. payload 不得變成下游的環境變數(allexport / 呼叫者已 export INPUT) ----
sandbox; write_full_payload
# 下游把自己看到的 INPUT 環境變數印出;必須不含 payload。
printf '#!/bin/bash\n/bin/cat >/dev/null\nprintf "INPUT=[%%s]" "${INPUT:-<unset>}"\n' > "$SB/envprobe.sh"; chmod +x "$SB/envprobe.sh"
# (a) 呼叫者開了 allexport
set +e
/bin/bash -c 'set -a; export SHELLOPTS; exec env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$1" /bin/bash "$2" --wrap "$3" < "$4"' \
    _ "$DATA_DIR" "$HOOK" "$SB/envprobe.sh" "$SB/payload.json" > "$SB/out.bin" 2>/dev/null
STATUS=$?
set -e
assert_status "T51a allexport wrap exit 0" 0
if grep -q 'used_percentage\|session_id' "$SB/out.bin"; then
    bad "T51a payload must not become an env var under allexport" "$(cat "$SB/out.bin")"
else ok "T51a payload not exported under allexport"; fi
# (b) 呼叫者原本就有 INPUT 環境變數 → 應原封傳給下游,不被 hook 覆蓋
set +e
INPUT="caller-original-input" env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" \
    /bin/bash "$HOOK" --wrap "$SB/envprobe.sh" < "$SB/payload.json" > "$SB/out.bin" 2>/dev/null
STATUS=$?
set -e
assert_out_is "T51b caller's own INPUT preserved for downstream" "INPUT=[caller-original-input]"

# ---- 40. 下游死於 signal:128+n 透傳,且 bash 的 Terminated 診斷不得污染 stderr ----
sandbox; write_full_payload
printf '#!/bin/bash\n/bin/cat >/dev/null\nkill -TERM $$\n' > "$SB/sigstub.sh"; chmod +x "$SB/sigstub.sh"
run_hook "$SB/payload.json" --wrap "$SB/sigstub.sh"
assert_status "T40 downstream SIGTERM → exit 143" 143
assert_err_empty "T40 no Terminated diagnostic on stderr"

# ---- 41. `--` 之後的字面 --wrap 原樣轉發(不被解析成旗標) ---------------------
sandbox; write_full_payload
printf '#!/bin/bash\n/bin/cat >/dev/null\n{ printf "%%s\\n" "$#"; printf "%%s\\n" "$@"; } > "%s"\n' "$SB/args-capture.txt" > "$SB/argstub.sh"
chmod +x "$SB/argstub.sh"
run_hook "$SB/payload.json" --wrap "$SB/argstub.sh" -- --wrap /tmp/x
printf '2\n--wrap\n/tmp/x\n' > "$SB/args-expected.txt"
assert_files_equal "T41 literal --wrap after -- forwarded verbatim" "$SB/args-capture.txt" "$SB/args-expected.txt"

# ---- 42. resets_at 型別矩陣、model 非字串、scalar rate_limits、溢位百分比 -------
sandbox; seed_good
# resets_at: bool/string/Infinity → 丟欄位保窗口;0 → 有效數值保留
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":true}}}' > "$SB/p.json"
run_hook "$SB/p.json"; landed
if "$PYBIN" -c 'import json,sys; w=json.load(open(sys.argv[1]))["rate_limits"]["five_hour"]; assert w=={"used_percentage":42}, w' "$LANDED"; then
    ok "T42 resets_at bool dropped, window kept"; else bad "T42 resets_at bool" "$(cat "$LANDED")"; fi
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":"soon"}}}' > "$SB/p.json"
run_hook "$SB/p.json"; landed
if "$PYBIN" -c 'import json,sys; w=json.load(open(sys.argv[1]))["rate_limits"]["five_hour"]; assert w=={"used_percentage":42}, w' "$LANDED"; then
    ok "T42 resets_at string dropped, window kept"; else bad "T42 resets_at string" "$(cat "$LANDED")"; fi
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":Infinity}}}' > "$SB/p.json"
run_hook "$SB/p.json"; landed
if "$PYBIN" -c 'import json,sys; w=json.load(open(sys.argv[1]))["rate_limits"]["five_hour"]; assert w=={"used_percentage":42}, w' "$LANDED"; then
    ok "T42 resets_at Infinity dropped, window kept"; else bad "T42 resets_at Infinity" "$(cat "$LANDED")"; fi
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":0}}}' > "$SB/p.json"
run_hook "$SB/p.json"; landed
if "$PYBIN" -c 'import json,sys; w=json.load(open(sys.argv[1]))["rate_limits"]["five_hour"]; assert w=={"used_percentage":42,"resets_at":0}, w' "$LANDED"; then
    ok "T42 resets_at 0 kept (valid numeric)"; else bad "T42 resets_at 0" "$(cat "$LANDED")"; fi
# model 欄位非字串 → null;溢位百分比(1e999 → inf)→ 窗口不可用
printf '%s' '{"model":{"id":123,"display_name":["x"]},"rate_limits":{"five_hour":{"used_percentage":42}}}' > "$SB/p.json"
run_hook "$SB/p.json"; landed
if "$PYBIN" -c 'import json,sys; m=json.load(open(sys.argv[1]))["model"]; assert m=={"id":None,"display_name":None}, m' "$LANDED"; then
    ok "T42 non-string model fields become null"; else bad "T42 model typing" "$(cat "$LANDED")"; fi
seed_good
printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":1e999}}}' > "$SB/p.json"
run_hook "$SB/p.json"
assert_out_is "T42 overflow percentage renders em-dash" '🐾 Claude · 5h — · wk —'
assert_seed_untouched "T42 overflow percentage no clobber"
printf '%s' '{"rate_limits":"busy"}' > "$SB/p.json"
run_hook "$SB/p.json"
assert_seed_untouched "T42 scalar rate_limits no clobber"

# ---- 43. 一窗有效 + 一窗 NaN:只落有效窗,且落地檔是嚴格合法 JSON ---------------
sandbox
printf '%s' '{"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42.4,"resets_at":1789000000},"seven_day":{"used_percentage":NaN}}}' > "$SB/p.json"
run_hook "$SB/p.json"
assert_out_is "T43 mixed windows display" '🐾 Fable · 5h 42% · wk —'
landed
if "$PYBIN" -c '
import json, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw, parse_constant=lambda s: (_ for _ in ()).throw(ValueError(s)))  # 嚴格:NaN/Inf 立即報錯
assert sorted(d["rate_limits"]) == ["five_hour"], d
' "$LANDED"; then ok "T43 landed strictly valid JSON with only usable window"; else bad "T43 strict JSON" "$(cat "$LANDED")"; fi

# ---- 44. 落地路徑是「指向檔案的 symlink」:rename 取代 symlink 本身,不追隨 ------
sandbox; write_full_payload
mkdir -p "$DATA_DIR"
printf 'target original' > "$SB/link-target.txt"
ln -s "$SB/link-target.txt" "$DATA_DIR/claude-statusline.json"
run_hook "$SB/payload.json"
assert_status "T44 dest-is-symlink standalone exit 0" 0
landed
if [ -L "$LANDED" ]; then bad "T44 symlink must be replaced by a real file" "still a symlink"; else ok "T44 symlink replaced by real file"; fi
[ "$(cat "$SB/link-target.txt")" = 'target original' ] && ok "T44 symlink target untouched" || bad "T44 symlink target" "was written through"
if "$PYBIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["rate_limits"]["five_hour"]["used_percentage"]==42.4' "$LANDED"; then
    ok "T44 landed content correct"; else bad "T44 landed content" "$(cat "$LANDED")"; fi

# ---- 45. 直譯器回 0 但無輸出(壞替身):獨立模式退固定字串,不印空白、不落地 -----
sandbox; seed_good
printf '#!/bin/bash\n/bin/cat >/dev/null\nexit 0\n' > "$SB/mutepy.sh"; chmod +x "$SB/mutepy.sh"
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" AIPET_STATUSLINE_PYTHON="$SB/mutepy.sh" \
    /bin/bash "$HOOK" < "$SB/seed.bin" > "$SB/out.bin" 2> "$SB/err.bin"
STATUS=$?
set -e
assert_status "T45 mute interpreter standalone exit 0" 0
assert_out_is "T45 mute interpreter falls back (not empty output)" "🐾 Claude"
assert_seed_untouched "T45 mute interpreter no clobber"

# ---- 46. consumer 相容性:巨大整數與 lone surrogate 不得寫出 Foundation 拒讀的檔 ----
sandbox; seed_good
"$PYBIN" -c 'import json,sys; big=int("9"*400); sys.stdout.write(json.dumps({"model":{"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":big}}}))' > "$SB/bigint-resets.json"
run_hook "$SB/bigint-resets.json"
assert_out_is "T46 huge-int resets_at still renders" '🐾 Fable · 5h 42% · wk —'
landed
if "$PYBIN" -c 'import json,sys; w=json.load(open(sys.argv[1]))["rate_limits"]["five_hour"]; assert w=={"used_percentage":42}, w' "$LANDED"; then
    ok "T46 huge-int resets_at dropped, window kept"; else bad "T46 huge-int resets_at" "$(cat "$LANDED")"; fi
seed_good
"$PYBIN" -c 'import json,sys; big=int("9"*400); sys.stdout.write(json.dumps({"rate_limits":{"five_hour":{"used_percentage":big}}}))' > "$SB/bigint-pct.json"
run_hook "$SB/bigint-pct.json"
assert_out_is "T46 huge-int percentage unusable, renders em-dash" '🐾 Claude · 5h — · wk —'
assert_seed_untouched "T46 huge-int percentage no clobber"
"$PYBIN" -c 'import json,sys; s=json.loads("\"\\ud800\""); sys.stdout.write(json.dumps({"model":{"id":s,"display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":42}}}))' > "$SB/surrogate.json"
run_hook "$SB/surrogate.json"
landed
if "$PYBIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["model"]=={"id":None,"display_name":"Fable"}, d["model"]' "$LANDED"; then
    ok "T46 lone-surrogate model.id becomes null (file stays consumer-readable)"; else bad "T46 surrogate" "$(cat "$LANDED")"; fi

# ---- 47. 卡死的直譯器:看門狗把落地限時,下游仍在數秒內執行(不永久卡住) --------
sandbox; write_full_payload
printf '#!/bin/bash\n/bin/cat >/dev/null\n/bin/sleep 60\n' > "$SB/hangpy.sh"; chmod +x "$SB/hangpy.sh"
make_stub "$SB/stub.sh"
set +e
STATUS=$("$PYBIN" - 20 "$SB/payload.json" "$SB/out.bin" "$SB/err.bin" \
    env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" AIPET_STATUSLINE_PYTHON="$SB/hangpy.sh" \
    /bin/bash "$HOOK" --wrap "$SB/stub.sh" <<'PYEOF'
import subprocess, sys
secs = float(sys.argv[1])
with open(sys.argv[2], "rb") as i, open(sys.argv[3], "wb") as o, open(sys.argv[4], "wb") as e:
    try:
        r = subprocess.run(sys.argv[5:], stdin=i, stdout=o, stderr=e, timeout=secs)
        print(r.returncode)
    except subprocess.TimeoutExpired:
        print(124)
PYEOF
)
set -e
assert_status "T47 hanging interpreter bounded (downstream ran within 20s)" 0
assert_out_is "T47 hanging interpreter downstream stdout" "STUB-OUT"
printf '%s' 'STUB-ERR' > "$SB/expected-err.bin"
assert_files_equal "T47 hanging interpreter stderr only downstream's (no watchdog noise)" "$SB/err.bin" "$SB/expected-err.bin"
# 看門狗必須連同 pipeline 裡卡死的直譯器一起殺(killpg),不得留孤兒(grok r2 #2)。
UNIQ_MARK="hangpy-$$-$RANDOM"
mv "$SB/hangpy.sh" "$SB/$UNIQ_MARK.sh"
sandbox; write_full_payload
printf '#!/bin/bash\n/bin/cat >/dev/null\n/bin/sleep 41\n' > "$SB/$UNIQ_MARK.sh"; chmod +x "$SB/$UNIQ_MARK.sh"
make_stub "$SB/stub.sh"
set +e
env -u AIPET_STATUSLINE_HOOK_ACTIVE AIPET_DATA_DIR="$DATA_DIR" AIPET_STATUSLINE_PYTHON="$SB/$UNIQ_MARK.sh" \
    /bin/bash "$HOOK" --wrap "$SB/stub.sh" < "$SB/payload.json" > "$SB/out.bin" 2>/dev/null
set -e
"$PYBIN" -c 'import time; time.sleep(7)'   # 等過看門狗的 5 秒殺點
if pgrep -f "$UNIQ_MARK" >/dev/null 2>&1 || pgrep -f 'sleep 41' >/dev/null 2>&1; then
    bad "T47 watchdog kills the whole tree (no orphan interpreter)" "orphan survived"
    pkill -9 -f "$UNIQ_MARK" 2>/dev/null || :; pkill -9 -f 'sleep 41' 2>/dev/null || :
else ok "T47 watchdog kills the whole tree (no orphan interpreter)"; fi

# ---- 47b. 正常路徑不得留看門狗的 sleep 孤兒(收尾 killpg 看門狗) --------------
sandbox; write_full_payload
# pgrep 無匹配回非零,在 set -o pipefail 下會觸發 set -e —— 用 { } || : 中和。
BEFORE=$( { pgrep -f '/bin/sleep 5' 2>/dev/null | wc -l | tr -d ' '; } || : ); BEFORE=${BEFORE:-0}
make_stub "$SB/stub.sh"
run_hook "$SB/payload.json" --wrap "$SB/stub.sh"
assert_status "T47b normal wrap exit 0" 0
"$PYBIN" -c 'import time; time.sleep(1)'
AFTER=$( { pgrep -f '/bin/sleep 5' 2>/dev/null | wc -l | tr -d ' '; } || : ); AFTER=${AFTER:-0}
if [ "${AFTER:-0}" -le "${BEFORE:-0}" ]; then ok "T47b no watchdog sleep orphan after normal wrap"; else
    bad "T47b watchdog sleep orphan" "before=$BEFORE after=$AFTER"; fi

# ---- 48. 看門狗殺掉 persist 留下的舊 tmp:下次執行會清掃(只掃 >10 分鐘) --------
sandbox; write_full_payload
mkdir -p "$DATA_DIR"
printf 'stale' > "$DATA_DIR/.claude-statusline.json.STALE1"
touch -t 202601010101 "$DATA_DIR/.claude-statusline.json.STALE1"
printf 'fresh' > "$DATA_DIR/.claude-statusline.json.FRESH1"   # 新 tmp(模擬並行中)不得被清
run_hook "$SB/payload.json"
assert_status "T48 sweep run exit 0" 0
[ ! -e "$DATA_DIR/.claude-statusline.json.STALE1" ] && ok "T48 stale tmp swept" || bad "T48 stale tmp" "still present"
[ -e "$DATA_DIR/.claude-statusline.json.FRESH1" ] && ok "T48 fresh tmp untouched (concurrent-safe)" || bad "T48 fresh tmp" "wrongly deleted"
rm -f "$DATA_DIR/.claude-statusline.json.FRESH1"

# ---- 結果 --------------------------------------------------------------------
echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
