#!/usr/bin/env bash
# Install dist build to /Applications and register the widget (personal use, no App Store).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/AI Pet Usage.app"
DST="/Applications/AI Pet Usage.app"

[ -d "$SRC" ] || { echo "Run Scripts/build-app.sh first." >&2; exit 1; }

mkdir -p "/Users/Shared/AIPetUsage"
chmod 1777 "/Users/Shared/AIPetUsage" 2>/dev/null || chmod 755 "/Users/Shared/AIPetUsage"

echo "Installing to $DST ..."
rm -rf "$DST"
ditto "$SRC" "$DST"
"$ROOT/Scripts/register-widget.sh" "$DST"
echo "Done. Open once: open \"$DST\""