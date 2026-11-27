#!/usr/bin/env bash
# Install dist build to /Applications and register the widget (personal use, no App Store).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/AI Pet Usage.app"
DST="/Applications/AI Pet Usage.app"

[ -d "$SRC" ] || { echo "Run Scripts/build-app.sh first." >&2; exit 1; }
# checks/project.sh (also run by the commit hook) builds dist/ with SKIP_WIDGET=1, and a failed widget
# build can leave the appex incomplete; installing either would replace a working app with a widget-less
# one. Refuse before touching /Applications.
APPEX_SRC="$SRC/Contents/PlugIns/AIPetUsageWidgetExtension.appex"
PLIST_SRC="$APPEX_SRC/Contents/Info.plist"
EXEC_SRC="$APPEX_SRC/Contents/MacOS/AIPetUsageWidgetExtension"
[ -f "$PLIST_SRC" ] && [ -s "$PLIST_SRC" ] && [ -f "$EXEC_SRC" ] && [ -s "$EXEC_SRC" ] && [ -x "$EXEC_SRC" ] || {
  echo "Refusing: $SRC has no complete widget extension" >&2
  echo "(likely built by checks/project.sh or with SKIP_WIDGET=1, or the widget build failed)." >&2
  echo "Run Scripts/build-app.sh with SKIP_WIDGET unset, then re-run this script." >&2
  exit 1
}

SHARED_ROOT="/Users/Shared/AIPetUsage"
UID_DIR="${SHARED_ROOT}/$(id -u)"
ME="$(id -u)"

shared_mirror_reject_symlink() {
  local path="$1"
  if [ -L "$path" ]; then
    echo "Refusing: $path is a symlink (create a real directory first)." >&2
    exit 1
  fi
}

if [ -e "$SHARED_ROOT" ]; then
  shared_mirror_reject_symlink "$SHARED_ROOT"
  [ -d "$SHARED_ROOT" ] || {
    echo "Refusing: $SHARED_ROOT exists but is not a directory." >&2
    exit 1
  }
else
  mkdir -p "$SHARED_ROOT"
  shared_mirror_reject_symlink "$SHARED_ROOT"
fi

ROOT_OWNER="$(stat -f '%u' "$SHARED_ROOT" 2>/dev/null || echo "")"
# Multi-user ad-hoc widget: sticky root must be root-owned (sol/grok gate). Prompt once when we own it.
if [ "$ROOT_OWNER" = "$ME" ]; then
  echo "Promoting $SHARED_ROOT to root:wheel for multi-user widget mirror (sudo once)…"
  if sudo chown root:wheel "$SHARED_ROOT" 2>/dev/null && sudo chmod 1777 "$SHARED_ROOT" 2>/dev/null; then
    ROOT_OWNER="0"
  else
    echo "Note: mirror stays user-owned (single macOS user only). Or run:" >&2
    echo "  sudo chown root:wheel \"$SHARED_ROOT\" && sudo chmod 1777 \"$SHARED_ROOT\"" >&2
  fi
fi
if [ -n "$ROOT_OWNER" ] && [ "$ROOT_OWNER" != "$ME" ] && [ "$ROOT_OWNER" != "0" ]; then
  echo "Refusing: $SHARED_ROOT is owned by uid $ROOT_OWNER." >&2
  echo "For another macOS user, fix once as admin:" >&2
  echo "  sudo chown root:wheel \"$SHARED_ROOT\" && sudo chmod 1777 \"$SHARED_ROOT\"" >&2
  exit 1
fi
if [ "$ROOT_OWNER" = "$ME" ] || [ "$ROOT_OWNER" = "0" ]; then
  chmod -h 1777 "$SHARED_ROOT" 2>/dev/null || {
    echo "Warning: could not set sticky mode on $SHARED_ROOT; ad-hoc widget mirror may not write." >&2
  }
fi
legacy_flat="${SHARED_ROOT}/widget-snapshot.json"
if [ -f "$legacy_flat" ] && [ ! -L "$legacy_flat" ]; then
  rm -f "$legacy_flat" 2>/dev/null || true
fi

if [ -e "$UID_DIR" ]; then
  shared_mirror_reject_symlink "$UID_DIR"
  [ -d "$UID_DIR" ] || {
    echo "Refusing: $UID_DIR exists but is not a directory." >&2
    exit 1
  }
  UID_OWNER="$(stat -f '%u' "$UID_DIR" 2>/dev/null || echo "")"
  if [ -n "$UID_OWNER" ] && [ "$UID_OWNER" != "$ME" ]; then
    echo "Refusing: $UID_DIR is owned by uid $UID_OWNER." >&2
    exit 1
  fi
else
  mkdir -p "$UID_DIR"
  shared_mirror_reject_symlink "$UID_DIR"
fi
chmod 700 "$UID_DIR" 2>/dev/null || true

echo "Installing to $DST ..."
rm -rf "$DST"
ditto "$SRC" "$DST"
"$ROOT/Scripts/register-widget.sh" "$DST"
# A running widget extension keeps the OLD binary's layout in memory after the .appex is
# replaced (snapshot data updates, view code does not). Stop it and WidgetKit's cache
# daemon so the next render launches the new build; launchd respawns both on demand.
if pkill -U "$ME" -x AIPetUsageWidgetExtension; then
  echo "Stopped running widget extension (will relaunch from the new build)."
fi
killall chronod 2>/dev/null || true
echo "Done. Open once: open \"$DST\""
