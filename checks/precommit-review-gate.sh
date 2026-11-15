#!/usr/bin/env bash
# Pre-commit gate: executable checks + dual-family review (gpt-6.1-sol + grok).
#
# Usage:
#   bash checks/precommit-review-gate.sh              # checks only (default)
#   PRE_COMMIT_REVIEW=1 bash checks/precommit-review-gate.sh   # + sol + grok PROCEED
#
# Panel raters (optional, findings enrichment only — not ship authority):
#   codex, agy, grok, opencode, nim, typesafe — set PANEL_REVIEW=1 with dispatch.py on PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/checks/.artifacts"
mkdir -p "$ART"
cd "$ROOT"

# CLT-only hosts: skip full usagecore-tests **run** (compile still in widget-golden/project) and app bundle.
export SKIP_USAGE_TESTS_RUN="${SKIP_USAGE_TESTS_RUN:-1}"
export SKIP_APP_BUILD="${SKIP_APP_BUILD:-1}"

echo "== Phase 1: ground-truth gates =="
bash checks/run-all.sh

echo "== Phase 2: findings packet =="
STAT="$(git diff --stat 2>/dev/null || true)"
DIFF_HEAD="$(git diff --name-only 2>/dev/null | head -80 || true)"
PACKET="$ART/precommit-packet-$(date -u +%Y%m%dT%H%M%SZ).md"
cat >"$PACKET" <<EOF
# Pre-commit packet (AI Pet Usage)

## Scope
WidgetKit macOS widget + WidgetSnapshot pipeline (Codex / Antigravity / Grok / OpenCode).

## Ground truth
- checks/run-all.sh: GREEN (this run)

## Changed files (sample)
\`\`\`
${DIFF_HEAD:-"(no unstaged diff or not a git repo)"}
\`\`\`

## Diff stat
\`\`\`
${STAT:-"(empty)"}
\`\`\`

## Review contract
Respond with exactly one line first: \`PROCEED\` or \`FIX\`.
Then list findings as \`(reviewer, F#): claim — evidence — severity\`.

### Static findings (machine)
- F1: Widget snapshot must stay share-safe (no paths / secrets in JSON).
- F2: App Group \`group.dev.aipetusage.app\` required for sandboxed widget extension.
- F3: Nim and TypeSafe AI are **not** wired as providers; widget order documents Codex/AG/Grok/OC only.
- F4: Widget extension requires Xcode project build (Extensions/AIPetUsageWidget); SKIP_WIDGET=1 in project gate until embedded.

## Gate reviewers (authority)
- **gpt-6.1-sol** (codex family)
- **grok-4.6** (xAI)

Panel raters (non-authoritative when PANEL_REVIEW=1): codex, agy, grok, opencode, nim, typesafe.
EOF
echo "Wrote $PACKET"

if [ "${PRE_COMMIT_REVIEW:-0}" != "1" ]; then
  echo "Phase 3 skipped (set PRE_COMMIT_REVIEW=1 for sol + grok gate)"
  exit 0
fi

DISPATCH="${DISPATCH_PY:-$HOME/.claude/lib/dispatch.py}"
if [ ! -f "$DISPATCH" ]; then
  echo "PRE_COMMIT_REVIEW=1 but dispatch.py not found at $DISPATCH" >&2
  exit 1
fi

review() {
  local tool="$1" model="$2" tag="$3"
  local out="$ART/review-${tag}.txt"
  python3 "$DISPATCH" "$tool" --model "$model" -p "$(cat "$PACKET")

You are a pre-commit gate reviewer ($tag). No tools. Read the packet. First line PROCEED or FIX only." \
    >"$out" 2>&1 || true
  head -1 "$out" | tr -d '\r' | awk '{print tolower($0)}'
}

if [ "${PANEL_REVIEW:-0}" = "1" ]; then
  echo "== Phase 3a: panel ratings (non-authoritative) =="
  while IFS=':' read -r tool model tag; do
    [ -n "$tool" ] || continue
    echo "  panel $tag → $(review "$tool" "$model" "$tag" || echo error)"
  done <<'PANEL'
codex:gpt-5.6-luna:panel-codex
agy:gemini-3.8-flash-medium:panel-agy
grok:grok-4.6:panel-grok
opencode:gpt-5.6-luna:panel-opencode
nim:gpt-5.6-luna:panel-nim
typesafe:gpt-5.6-luna:panel-typesafe
PANEL
fi

echo "== Phase 3b: gate reviewers (authority) =="
SOL="$(review codex gpt-6.1-sol gate-sol || echo fix)"
GROK="$(review grok grok-4.6 gate-grok || echo fix)"
echo "  sol:  $SOL"
echo "  grok: $GROK"

case "$SOL" in
  proceed) ;;
  *) echo "GATE RED: gpt-6.1-sol did not PROCEED (see $ART/review-gate-sol.txt)"; exit 1 ;;
esac
case "$GROK" in
  proceed) ;;
  *) echo "GATE RED: grok-4.6 did not PROCEED (see $ART/review-gate-grok.txt)"; exit 1 ;;
esac
echo "GATE GREEN: dual-family PROCEED"