#!/bin/bash
# AI Pet Usage 的 Claude Code statusline hook(原創實作)。
#
# Claude Code 每次刷新狀態列會把官方 JSON payload 餵進 statusline 指令的 stdin,
# 其中含 `rate_limits`(5 小時 / 週窗口的官方 used_percentage 與 resets_at)。
# 此腳本把 payload 原封保存到 AI Pet Usage 的資料夾(供 adapter 讀取官方限額),
# 並輸出一行簡短狀態文字給 Claude Code 顯示。
#
# 安裝:在 ~/.claude/settings.json 加入
#   "statusLine": {"type": "command", "command": "/bin/bash <repo>/Scripts/claude-statusline-hook.sh"}
# (若已有其他 statusline 工具在保存同一 payload,AI Pet Usage 會直接讀那份,毋需本腳本。)
set -euo pipefail

OUT_DIR="$HOME/Library/Application Support/AIPetUsage"
mkdir -p "$OUT_DIR"

INPUT=$(cat)
TMP="$OUT_DIR/.claude-statusline.json.tmp"
printf '%s' "$INPUT" > "$TMP"
mv -f "$TMP" "$OUT_DIR/claude-statusline.json"

# 狀態列顯示:model · 5h X% · wk Y%(解析失敗時退回固定字串)。
# 注意:heredoc 會佔用 python 的 stdin,payload 必須改以檔案路徑傳入。
/usr/bin/python3 - "$OUT_DIR/claude-statusline.json" <<'PY' 2>/dev/null || printf '🐾 Claude'
import json, sys
d = json.load(open(sys.argv[1]))
model = (d.get("model") or {}).get("display_name", "Claude")
rl = d.get("rate_limits") or {}
def pct(key):
    v = (rl.get(key) or {}).get("used_percentage")
    return f"{round(v)}%" if isinstance(v, (int, float)) else "—"
print(f"🐾 {model} · 5h {pct('five_hour')} · wk {pct('seven_day')}", end="")
PY
