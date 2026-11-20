#!/usr/bin/env bash
# Build macOS WidgetKit extension and embed in dist/AI Pet Usage.app
# Requires full Xcode (not CLT-only). Set SKIP_WIDGET=1 to skip in build-app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
PROJ="$ROOT/macOS/AIPetUsageWidget.xcodeproj"
APP="${AIPET_APP_BUNDLE:-$ROOT/dist/AI Pet Usage.app}"
APPEX_DST="$APP/Contents/PlugIns/AIPetUsageWidgetExtension.appex"
SIGN_ID="${WIDGET_SIGN_IDENTITY:--}"

if [ ! -d "$PROJ" ]; then
  echo "build-widget: missing $PROJ — open Package.swift in Xcode, add Widget Extension target" >&2
  echo "  Sources: Extensions/AIPetUsageWidget/" >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "build-widget: xcodebuild unavailable" >&2
  exit 1
fi

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  ENT="$ROOT/Extensions/AIPetUsageWidget/AIPetUsageWidget.entitlements"
else
  ENT="$ROOT/Extensions/AIPetUsageWidget/AIPetUsageWidget.adhoc.entitlements"
  echo "build-widget: no DEVELOPMENT_TEAM — personal ad-hoc widget (sandbox + /Users/Shared snapshot)" >&2
fi

XCBUILD_ARGS=(
  -project "$PROJ"
  -scheme AIPetUsageWidgetExtension
  -configuration Release
  -derivedDataPath "$ROOT/.build/DerivedData"
  ONLY_ACTIVE_ARCH=NO
  CODE_SIGN_IDENTITY="${WIDGET_SIGN_IDENTITY:--}"
  CODE_SIGN_ENTITLEMENTS="$ENT"
)
# Optional: export DEVELOPMENT_TEAM=XXXXXXXXXX for signed App Group on device-like installs.
[ -n "${DEVELOPMENT_TEAM:-}" ] && XCBUILD_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")

xcodebuild "${XCBUILD_ARGS[@]}" build

BUILT="$(find "$ROOT/.build/DerivedData" -name 'AIPetUsageWidgetExtension.appex' -type d | head -1)"
[ -n "$BUILT" ] || { echo "build-widget: .appex not found in DerivedData" >&2; exit 1; }

[ -d "$APP" ] || { echo "build-widget: app bundle missing — run Scripts/build-app.sh first" >&2; exit 1; }
mkdir -p "$(dirname "$APPEX_DST")"
rm -rf "$APPEX_DST"
cp -R "$BUILT" "$APPEX_DST"
if [ -f "$ENT" ]; then
  codesign --force --sign "$SIGN_ID" --entitlements "$ENT" "$APPEX_DST" || {
    echo "build-widget: codesign appex failed" >&2
    exit 1
  }
else
  codesign --force --sign "$SIGN_ID" "$APPEX_DST" || exit 1
fi
echo "Embedded widget: $APPEX_DST"