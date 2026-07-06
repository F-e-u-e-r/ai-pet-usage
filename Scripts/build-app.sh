#!/bin/bash
# 產出可雙擊執行的 macOS app bundle:dist/AI Pet Usage.app
# (LSUIElement 選單列常駐;ad-hoc 簽名讓通知與 TCC 行為正常)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AI Pet Usage.app"
BUNDLE_ID="dev.aipetusage.app"
VERSION="0.1.0"

"$ROOT/Scripts/swiftpm.sh" build -c release --product AIPetUsage

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/AIPetUsage" "$APP/Contents/MacOS/AIPetUsage"

# SwiftPM 資源(價目表 JSON)必須隨附,否則發佈後會退回過期的編譯內建價。
cp -R "$ROOT/.build/release/AIPetUsage_UsageCore.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AI Pet Usage</string>
    <key>CFBundleDisplayName</key><string>AI Pet Usage</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>AIPetUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local-first. No data leaves this Mac.</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Run:   open \"$APP\""
