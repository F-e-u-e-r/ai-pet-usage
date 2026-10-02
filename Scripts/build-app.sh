#!/bin/bash
# 產出可雙擊執行的 macOS app bundle:dist/AI Pet Usage.app
# (LSUIElement 選單列常駐;ad-hoc 簽名讓通知與 TCC 行為正常)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AI Pet Usage.app"
BUNDLE_ID="dev.aipetusage.app"
# 版號由環境注入(release workflow 以 canonical tag 驅動,如 tag v0.1.0-beta.1 → VERSION=0.1.0 +
# RELEASE_TAG=v0.1.0-beta.1)。CFBundleShortVersionString / CFBundleVersion **必須是數字**(Apple 契約),
# 故本機預設數字 0.0.0;「是否正式版」由 AIPetUsageBuildChannel 標記(source/dev 版不觸發更新提示,見
# UpdateChecker);完整發行身分只放在 release build 的 AIPetUsageReleaseTag。規範:docs/release/VERSIONING.md。
VERSION="${VERSION:-0.0.0}"
BUILD_CHANNEL="${BUILD_CHANNEL:-source}"
RELEASE_TAG="${RELEASE_TAG:-}"

# 先驗證版本不變式再進入(較慢的)Swift 建置;write-info-plist.sh 寫檔前會再驗證一次。
VERSION="$VERSION" BUILD_CHANNEL="$BUILD_CHANNEL" RELEASE_TAG="$RELEASE_TAG" \
    "$ROOT/Scripts/release-version.sh" --check-build-env

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

VERSION="$VERSION" BUILD_CHANNEL="$BUILD_CHANNEL" RELEASE_TAG="$RELEASE_TAG" BUNDLE_ID="$BUNDLE_ID" \
    "$ROOT/Scripts/write-info-plist.sh" "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# 先簽巢狀的 aipet,再簽外層 app(外層密封含已簽的 helper)。
# STRICT_SIGN=1(release workflow):簽章失敗即 fail 並 --verify --strict 驗證 —
# CI 產出未簽 bundle 下載後是「已損壞」,比 quarantine 更難排;不用 --deep 簽(會掩蓋漏簽)。
if [[ "${STRICT_SIGN:-0}" == "1" ]]; then
    codesign --force --sign - "$APP/Contents/MacOS/aipet"
    codesign --force --sign - "$APP"
    codesign --verify --deep --strict "$APP"
else
    codesign --force --sign - "$APP/Contents/MacOS/aipet" 2>/dev/null || true
    codesign --force --sign - "$APP" 2>/dev/null || true
fi

echo "Built: $APP"
echo "Run:   open \"$APP\""
