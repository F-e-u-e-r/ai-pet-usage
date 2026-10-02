#!/bin/bash
# Writes the app bundle's Info.plist. Called by Scripts/build-app.sh; kept separate so the version
# invariants can be tested without building the app (usagecore-tests + Scripts/test-release-version.sh).
#
# Inputs (environment): VERSION, BUILD_CHANNEL, RELEASE_TAG, BUNDLE_ID.
# Contract (docs/release/VERSIONING.md):
#   CFBundleShortVersionString = CFBundleVersion = X.Y.Z   (Apple requires numeric; never "-beta.N")
#   AIPetUsageBuildChannel     = release | source | dev    (build provenance, NOT the release channel)
#   AIPetUsageReleaseTag       = full canonical tag        (release builds ONLY; absent otherwise)
# Validation runs first (release-version.sh --check-build-env). On any violation nothing is written and
# the script exits non-zero.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: write-info-plist.sh <output-path>" >&2; exit 2; }
OUT="$1"
VERSION="${VERSION:-0.0.0}"
BUILD_CHANNEL="${BUILD_CHANNEL:-source}"
RELEASE_TAG="${RELEASE_TAG:-}"
BUNDLE_ID="${BUNDLE_ID:-dev.aipetusage.app}"

VERSION="$VERSION" BUILD_CHANNEL="$BUILD_CHANNEL" RELEASE_TAG="$RELEASE_TAG" \
    "$(dirname "$0")/release-version.sh" --check-build-env

{
    cat <<EOF
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
    <key>AIPetUsageBuildChannel</key><string>${BUILD_CHANNEL}</string>
EOF
    if [ "$BUILD_CHANNEL" = release ]; then
        printf '    <key>AIPetUsageReleaseTag</key><string>%s</string>\n' "$RELEASE_TAG"
    fi
    cat <<'EOF'
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local-first. Your usage data never leaves this Mac.</string>
</dict>
</plist>
EOF
} > "$OUT"
