#!/bin/bash
# Same billing envelope as AI Pet Usage (post-fix GrokQuotaEngine). Quick check without the GUI app.
set -euo pipefail
AUTH="${GROK_HOME:+$GROK_HOME/auth.json}"
AUTH="${AUTH:-$HOME/.grok/auth.json}"
python3 - "$AUTH" <<'PY'
import json, os, ssl, sys, urllib.request
from pathlib import Path

auth = Path(sys.argv[1])
if not auth.is_file():
    print("not logged in — run grok once (~/.grok/auth.json missing)")
    raise SystemExit(2)
store = json.load(open(auth))
key = None
for v in store.values():
    if isinstance(v, dict) and v.get("key"):
        key = v["key"]
        break
if not key:
    print("no session key in auth.json")
    raise SystemExit(2)

req = urllib.request.Request(
    "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
    headers={
        "Authorization": f"Bearer {key}",
        "X-XAI-Token-Auth": "xai-grok-cli",
        "Accept": "application/json",
        "User-Agent": "AIPetUsage/grok-quota-peek",
    },
    method="GET",
)
try:
    with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=20) as r:
        body = json.loads(r.read(500_000))
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code} — login may be expired; run grok once, then retry")
    raise SystemExit(1)

cfg = body.get("config") if isinstance(body, dict) else None
if not isinstance(cfg, dict):
    print("billing response has no config object")
    raise SystemExit(1)

pct = None
for row in cfg.get("productUsage") or []:
    if isinstance(row, dict) and row.get("product") == "GrokBuild":
        pct = row.get("usagePercent")
        break
if pct is None:
    pct = cfg.get("creditUsagePercent")
if not isinstance(pct, (int, float)):
    print("no usage percent in billing response (same as old app: no usage data)")
    raise SystemExit(1)

end = (cfg.get("currentPeriod") or {}).get("end") or cfg.get("billingPeriodEnd")
print(f"Grok weekly build usage: {pct:.0f}% used", end="")
if end:
    print(f" (period ends {end})")
else:
    print()
PY