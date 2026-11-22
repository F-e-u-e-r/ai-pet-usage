#!/usr/bin/env bash
# Writes a JWT for Cursor GetCurrentPeriodUsage into AI Pet Usage's bearer file.
# **This script** may prompt Keychain (cursor-agent token); the app reads the file only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${CURSOR_DASHBOARD_BEARER_FILE:-$HOME/Library/Application Support/AIPetUsage/cursor-dashboard-bearer.txt}"

mkdir -p "$(dirname "$OUT")"
TOKEN="$(security find-generic-password -s cursor-access-token -a cursor-user -w 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  echo "export-cursor-dashboard-bearer: no cursor-agent Keychain token found." >&2
  echo "Sign in via cursor-agent, or paste a JWT manually into:" >&2
  echo "  $OUT" >&2
  exit 1
fi
umask 077
printf '%s' "$TOKEN" >"$OUT"
chmod 600 "$OUT" 2>/dev/null || true
echo "Wrote bearer JWT to $OUT (mode 600). Enable Cursor quota in AI Pet Usage."