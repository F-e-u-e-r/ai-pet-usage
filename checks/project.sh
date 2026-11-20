#!/usr/bin/env bash
# Project gate: SwiftPM release build + usagecore-tests (CI parity).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "project: swift build (UsageCore + CLI + tests)"
Scripts/swiftpm.sh build --product aipet
Scripts/swiftpm.sh build --product usagecore-tests

if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  echo "project: swift build (AIPetUsage — Xcode.app)"
  Scripts/swiftpm.sh build -c release --product AIPetUsage
else
  echo "project: skip AIPetUsage GUI (no Xcode.app; UsageCore gate still ran)"
fi

if [ "${SKIP_USAGE_TESTS_RUN:-0}" != "1" ]; then
  echo "project: usagecore-tests (run)"
  Scripts/swiftpm.sh run usagecore-tests
else
  echo "project: usagecore-tests run skipped (SKIP_USAGE_TESTS_RUN=1)"
fi

echo "project: optional app bundle (SKIP_APP_BUILD=1 to skip)"
if [ "${SKIP_APP_BUILD:-0}" != "1" ]; then
  SKIP_WIDGET=1 Scripts/build-app.sh
fi