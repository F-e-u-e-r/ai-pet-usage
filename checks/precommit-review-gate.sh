#!/usr/bin/env bash
# Pre-commit gate: executable checks + dual-family review (gpt-6.1-sol + grok-4.7).
#
# Usage:
#   bash checks/precommit-review-gate.sh              # checks only (default)
#   PRE_COMMIT_REVIEW=1 bash checks/precommit-review-gate.sh   # + sol + grok-4.7 PROCEED
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
# Prefer branch delta vs main (clean tree still produces a packet); fall back to index + worktree.
BASE_REF="${PRE_COMMIT_BASE_REF:-origin/main}"
DIFF_MAX_LINES="${PRE_COMMIT_DIFF_LINES:-200}"
SECURITY_PATHS=(
  Sources/UsageCore/SharedMirrorGate.swift
  Sources/UsageCore/WidgetSnapshot.swift
  Sources/UsageCore/PrivacyRedaction.swift
  Sources/UsageCore/GrokQuota.swift
  Extensions/AIPetUsageWidget/UsageTimelineProvider.swift
)
if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  DIFF_RANGE="${BASE_REF}...HEAD"
  DIFF_HEAD="$(git diff --name-only "$DIFF_RANGE" 2>/dev/null | head -80 || true)"
  STAT="$(git diff --stat "$DIFF_RANGE" 2>/dev/null || true)"
  DIFF_PATCH="$(git diff "$DIFF_RANGE" 2>/dev/null | head -n "$DIFF_MAX_LINES" || true)"
  PACKET_SCOPE="Branch vs ${BASE_REF} (merge-base...HEAD)"
else
  {
    git diff --cached --name-only
    git diff --name-only
  } 2>/dev/null | sort -u | head -80 >"$ART/.diff-names.tmp"
  DIFF_HEAD="$(cat "$ART/.diff-names.tmp" 2>/dev/null || true)"
  STAT="$( { git diff --cached --stat; git diff --stat; } 2>/dev/null || true)"
  DIFF_PATCH="$( { git diff --cached; git diff; } 2>/dev/null | head -n "$DIFF_MAX_LINES" || true)"
  PACKET_SCOPE="Staged + unstaged changes"
  rm -f "$ART/.diff-names.tmp"
fi

SECURITY_DIFF=""
for path in "${SECURITY_PATHS[@]}"; do
  if [ ! -e "$path" ]; then continue; fi
  if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  chunk="$(git diff "$DIFF_RANGE" -- "$path" 2>/dev/null || true)"
  else
  chunk="$( { git diff --cached -- "$path"; git diff -- "$path"; } 2>/dev/null || true)"
  fi
  [ -n "$chunk" ] || continue
  SECURITY_DIFF="${SECURITY_DIFF}

### \`${path}\`
\`\`\`diff
${chunk}
\`\`\`"
done

WORKTREE_STAT="$(git diff HEAD --stat 2>/dev/null || true)"
WORKTREE_PATCH="$(git diff HEAD 2>/dev/null | head -n "$DIFF_MAX_LINES" || true)"

SUPPLEMENT=""
for path in "${SECURITY_PATHS[@]}"; do
  [ -f "$path" ] || continue
  worktree_diff="$(git diff HEAD -- "$path" 2>/dev/null || true)"
  tracked=0
  git ls-files --error-unmatch "$path" >/dev/null 2>&1 && tracked=1
  if [ -n "$worktree_diff" ] || { [ "$tracked" -eq 0 ] && [ -f "$path" ]; }; then
    SUPPLEMENT="${SUPPLEMENT}

### Full file: \`${path}\` (working tree; branch diff may be empty)
\`\`\`swift
$(cat "$path")
\`\`\`"
  fi
done

GATE_NOTES="Phase 1 defaults: SKIP_USAGE_TESTS_RUN=${SKIP_USAGE_TESTS_RUN:-1}, SKIP_APP_BUILD=${SKIP_APP_BUILD:-1} (override for full suite: SKIP_USAGE_TESTS_RUN=0)."

PACKET="$ART/precommit-packet-$(date -u +%Y%m%dT%H%M%SZ).md"
cat >"$PACKET" <<EOF
# Pre-commit packet (AI Pet Usage)

## Scope
${PACKET_SCOPE} — AI Pet Usage (menu-bar meter + optional macOS widget).

## Ground truth
- checks/run-all.sh: GREEN (this run)
- ${GATE_NOTES}

## Changed files (sample)
\`\`\`
${DIFF_HEAD:-"(no diff vs ${BASE_REF:-working tree})"}
\`\`\`

## Diff stat
\`\`\`
${STAT:-"(empty)"}
\`\`\`

## Patch (first ${DIFF_MAX_LINES} lines)
\`\`\`diff
${DIFF_PATCH:-"(no patch)"}
\`\`\`

## Security / widget focus (full file diffs)
${SECURITY_DIFF:-"(no changes in focus paths)"}

## Working tree vs HEAD (uncommitted fixes — authority over branch diff)
\`\`\`
${WORKTREE_STAT:-"(clean)"}
\`\`\`
\`\`\`diff
${WORKTREE_PATCH:-"(no uncommitted diff)"}
\`\`\`

## Security focus — full files (when absent from branch diff)
${SUPPLEMENT:-"(included in diffs above)"}

## Review contract
Respond with exactly one line first: \`PROCEED\` or \`FIX\`.
Then list findings as \`(reviewer, F#): claim — evidence — severity\`.

### Static findings (machine)
- F1: Widget snapshot must stay share-safe (no paths / secrets in JSON).
- F2: Sandboxed widget reads App Group when signed with a team; ad-hoc uses per-UID \`/Users/Shared/AIPetUsage/<uid>/\` mirror (see docs/macOS_WIDGET.md).
- F3: Nim and TypeSafe AI are **not** wired as providers; widget order documents Codex/AG/Grok/OC only.
- F4: Widget extension builds via \`macOS/AIPetUsageWidget.xcodeproj\` and \`Scripts/build-widget-extension.sh\` (embedded in \`Scripts/build-app.sh\` unless SKIP_WIDGET=1).

## Gate reviewers (authority)
- **gpt-6.1-sol** (codex family)
- **grok-4.7** (xAI)

Panel raters (non-authoritative when PANEL_REVIEW=1): codex, agy, grok, opencode, nim, typesafe (typesafe routed via nim dispatch).

## Product notes (Grok meter)
- Track A (2026-08-10): \`creditUsagePercent\` is billing credits, not Grok 5h/weekly rate-limit windows.
- UI maps it to the weekly **chrome column** only, with \`.estimated\` confidence (docs/DATA_SOURCES.md).
- Token \`todayActivityPercent\` is **not** copied into weekly when no official quota.
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
  local tool="$1" model="$2" tag="$3" role="${4:-$tag}"
  local prompt="$ART/review-prompt-${tag}.md"
  local timeout="${DISPATCH_TIMEOUT:-900}"

  cat >"$prompt" <<PROMPT
$(cat "$PACKET")

---

You are a pre-commit gate reviewer ($role). No tools. Read the packet above.
Respond with exactly one line first: PROCEED or FIX (nothing else on line 1).
Then list findings as (reviewer, F#): claim — evidence — severity.
PROMPT

  rm -f "$ART/${tag}-final.txt" "$ART/${tag}-out.txt" "$ART/${tag}-result.json"

  local rc=0
  python3 "$DISPATCH" "$tool" \
    --model "$model" \
    --prompt-file "$prompt" \
    --outdir "$ART" \
    --name "$tag" \
    --cwd "$ROOT" \
    --timeout "$timeout" \
    --sandbox read-only \
    >"$ART/dispatch-${tag}.log" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "review $tag: dispatch exit $rc (see $ART/dispatch-${tag}.log)" >&2
    echo "fix"
    return 0
  fi

  local body=""
  if [ -f "$ART/${tag}-final.txt" ]; then
    body="$ART/${tag}-final.txt"
  elif [ -f "$ART/${tag}-out.txt" ]; then
    body="$ART/${tag}-out.txt"
  else
    echo "fix"
    echo "review $tag: no output (dispatch rc=$rc, see $ART/dispatch-${tag}.log)" >&2
    return 0
  fi

  local verdict
  verdict="$(awk '
    {
      if ($0 ~ /^[[:space:]]*$/) next
      line = $0
      gsub(/^[[:space:]]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      sub(/\.$/, "", line)
      l = tolower(line)
      if (l == "proceed") { print "proceed"; exit }
      if (l == "fix") { print "fix"; exit }
      print "fix"; exit
    }
  ' "$body")"
  echo "${verdict:-fix}"
}

if [ "${PANEL_REVIEW:-0}" = "1" ]; then
  echo "== Phase 3a: panel ratings (non-authoritative) =="
  while IFS=':' read -r tool model tag role; do
    [ -n "$tool" ] || continue
    role="${role:-$tag}"
    verdict="$(review "$tool" "$model" "$tag" "$role" || echo error)"
    echo "  panel $tag → $verdict"
  done <<'PANEL'
codex:gpt-5.6-luna:panel-codex:Codex implementer
agy:gemini-3.8-flash-medium:panel-agy:Antigravity agy
grok:grok-4.7:panel-grok:Grok
opencode:opencode/glm-5.3-flash-free:panel-opencode:OpenCode
nim:nvidia/z-ai/glm-5.3-flash:panel-nim:NIM
PANEL
fi

echo "== Phase 3b: gate reviewers (authority) =="
SOL="$(review codex gpt-6.1-sol gate-sol "gpt-6.1-sol authority" || echo fix)"
GROK_MODEL="${PRE_COMMIT_GROK_MODEL:-grok-4.7}"
GROK="$(review grok "$GROK_MODEL" gate-grok "grok-4.7 authority" || echo fix)"
echo "  sol:  $SOL"
echo "  grok: $GROK"

case "$SOL" in
  proceed) ;;
  *) echo "GATE RED: gpt-6.1-sol did not PROCEED (see $ART/gate-sol-out.txt or $ART/gate-sol-final.txt)"; exit 1 ;;
esac
case "$GROK" in
  proceed) ;;
  *) echo "GATE RED: $GROK_MODEL did not PROCEED (see $ART/gate-grok-out.txt)"; exit 1 ;;
esac
echo "GATE GREEN: dual-family PROCEED"