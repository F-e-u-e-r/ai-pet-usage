#!/usr/bin/env bash
# Register the embedded WidgetKit extension with PlugInKit (required for gallery listing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/AI Pet Usage.app}"
WIDGET_ID="dev.aipetusage.app.widget"
APPEX="$APP/Contents/PlugIns/AIPetUsageWidgetExtension.appex"

[ -d "$APPEX" ] || { echo "register-widget: no appex at $APPEX" >&2; exit 1; }

# Drop stale copies so the gallery does not point at an old .appex path (e.g. dist vs /Applications).
while IFS= read -r old; do
  [ -n "$old" ] && pluginkit -r "$old" 2>/dev/null || true
done < <(pluginkit -m -D -p com.apple.widgetkit-extension -i "$WIDGET_ID" 2>/dev/null \
  | sed -n 's/.*Path = \(.*\)/\1/p' || true)

add_rc=0
pluginkit -a -v "$APPEX" 2>&1 || add_rc=$?
if [ "$add_rc" -ne 0 ]; then
  echo "register-widget: pluginkit -a failed (exit $add_rc)" >&2
  exit "$add_rc"
fi

pluginkit -e use -p com.apple.widgetkit-extension -i "$WIDGET_ID" 2>&1 || true

echo "register-widget: registered $WIDGET_ID"
echo "  pluginkit status:"
pluginkit -m -p com.apple.widgetkit-extension -i "$WIDGET_ID" -vv 2>&1 | sed 's/^/    /' || true
if ! pluginkit -m -p com.apple.widgetkit-extension -i "$WIDGET_ID" 2>&1 | grep -q "$WIDGET_ID"; then
  echo "register-widget: WARN — plugin not visible in pluginkit -m (gallery may not list it)" >&2
fi
echo ""
echo "If the widget still does not appear:"
echo "  1) Install to /Applications (Scripts/install-local-app.sh)"
echo "  2) Open the app once, then Notification Center → Edit Widgets → search \"AI Pet Usage\""
echo "  3) Run: killall pkd; killall NotificationCenter"