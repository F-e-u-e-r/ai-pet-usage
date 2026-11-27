#!/usr/bin/env bash
# Golden gate for WidgetSnapshotBuilder row filter (macOS widget).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CASES="$ROOT/checks/widget-golden/cases.jsonl"
cd "$ROOT"

python3 - "$CASES" <<'PY'
import json, sys
from pathlib import Path

def root_id(pid: str) -> str:
    if pid.startswith("antigravity"):
        return "antigravity"
    if pid.startswith("claude-code"):
        return "claude-code"
    return pid

def enabled_for(pid: str, enabled: set[str]) -> bool:
    return pid in enabled or root_id(pid) in enabled

fail = 0
for line in Path(sys.argv[1]).read_text().splitlines():
    line = line.strip()
    if not line:
        continue
    case = json.loads(line)
    enabled = set(case["enabled"])
    rows: list[str] = []
    for lim in case["limits"]:
        pid = lim["id"]
        if not enabled_for(pid, enabled):
            continue
        five, week = lim.get("five"), lim.get("week")
        idle = bool(lim.get("idle", False))
        if five is None and week is None and not idle:
            continue
        rows.append(pid)
    want = case["expectRows"]
    if rows != want:
        print(f"FAIL {case['id']}: got {rows} want {want}", file=sys.stderr)
        fail += 1
    else:
        print(f"PASS {case['id']}")
sys.exit(1 if fail else 0)
PY

echo "widget-golden: compile WidgetSnapshotTests"
Scripts/swiftpm.sh build --product usagecore-tests
echo "widget-golden: OK"