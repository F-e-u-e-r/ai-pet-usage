#!/bin/bash
# AI Pet Usage 的 Claude Code statusline hook(原創實作)。
#
# Claude Code 每次刷新狀態列會把官方 JSON payload 餵進 statusline 指令的 stdin,
# 其中含 `rate_limits`(5 小時 / 週窗口的官方 used_percentage 與 resets_at)。
# 本腳本只把 `model` 與 `rate_limits` 兩個欄位落地到 AI Pet Usage 的資料夾
# (供 adapter 讀取官方限額),刻意丟棄 session id / transcript path / cwd 等其餘
# 欄位(隱私最小化),並輸出一行簡短狀態文字給 Claude Code 顯示。
#
# 安裝:在 ~/.claude/settings.json 加入
#   "statusLine": {"type": "command", "command": "/bin/bash <repo>/Scripts/claude-statusline-hook.sh"}
# (若已有其他 statusline 工具在保存同一 payload,AI Pet Usage 會直接讀那份,毋需本腳本。)
set -euo pipefail

OUT_DIR="$HOME/Library/Application Support/AIPetUsage"
mkdir -p "$OUT_DIR"

INPUT=$(cat)
TMP=$(mktemp "$OUT_DIR/.claude-statusline.json.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# 單一 python 行程:解析 stdin → 只寫出 {model, rate_limits} 到臨時檔 → 印出狀態列。
# 解析成功才原子替換落地檔;失敗則保留舊檔並退回固定字串(不覆蓋既有良好資料)。
# 用 -c 傳程式、pipe 傳 payload,避免 heredoc 佔用 stdin。
if printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {"model": d.get("model"), "rate_limits": d.get("rate_limits")}
with open(sys.argv[1], "w") as f:
    json.dump(out, f)
model = (out.get("model") or {}).get("display_name", "Claude")
rl = out.get("rate_limits") or {}
def pct(key):
    v = (rl.get(key) or {}).get("used_percentage")
    return f"{round(v)}%" if isinstance(v, (int, float)) else "—"
five = pct("five_hour")
week = pct("seven_day")
sys.stdout.write(f"🐾 {model} · 5h {five} · wk {week}")
' "$TMP" 2>/dev/null; then
    mv -f "$TMP" "$OUT_DIR/claude-statusline.json"
else
    printf '🐾 Claude'
fi
