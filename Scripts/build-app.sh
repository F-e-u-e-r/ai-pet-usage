#!/bin/bash
# 產出可雙擊執行的 macOS app bundle:dist/AI Pet Usage.app
# (LSUIElement 選單列常駐;ad-hoc 簽名讓通知與 TCC 行為正常)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AI Pet Usage.app"
BUNDLE_ID="dev.aipetusage.app"
VERSION="0.1.0"

"$ROOT/Scripts/swiftpm.sh" build -c release --product AIPetUsage
"$ROOT/Scripts/swiftpm.sh" build -c release --product aipet

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/AIPetUsage" "$APP/Contents/MacOS/AIPetUsage"
# aipet CLI 也隨附:排程匯出的 LaunchAgent 以絕對路徑呼叫它(見 ScheduledReportManager)。
cp "$ROOT/.build/release/aipet" "$APP/Contents/MacOS/aipet"

# SwiftPM 資源(價目表 JSON)放標準的 Contents/Resources(codesign / 公證合法結構)。
# UsageCore 的 PricingRegistry.resourceBundle() 以 Bundle.main.resourceURL 穩健定位——
# app 主程式與獨立執行的 aipet(launchd 排程)都解析到此,不依賴會在資源遺失時 fatalError 的
# Bundle.module,也不需在 .app 根放非標準檔。
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

# 先簽巢狀的 aipet,再簽外層 app(外層密封含已簽的 helper)。
codesign --force --sign - "$APP/Contents/MacOS/aipet" 2>/dev/null || true
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Run:   open \"$APP\""
