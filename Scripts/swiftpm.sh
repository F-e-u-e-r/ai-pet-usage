#!/bin/bash
# swift build/test/run 的包裝器,自動修復這台機器 CommandLineTools 的兩處已知損壞:
#
#   1. usr/lib/swift/pm/ManifestAPI 內殘留 2024/02 的舊版 *.private.swiftinterface,
#      與新版 libPackageDescription.dylib 符號不符 → manifest 連結失敗。
#      修法:複製一份 ManifestAPI、刪除 stale private interface,
#      以 SWIFTPM_CUSTOM_LIBS_DIR 指向副本。
#
#   2. usr/include/swift/module.modulemap 是舊版殘留,與 swift/bridging.modulemap
#      重複定義 SwiftBridging module → 所有 import Foundation 的編譯失敗。
#      修法:以 -vfsoverlay 在編譯期把殘留檔遮成純註解檔。
#
# 兩個修復都只影響本次編譯行程,完全不改動系統檔案。
# CLT 重新安裝修好後,此腳本會自動偵測並跳過對應修復。
#
# 用法:Scripts/swiftpm.sh build -c release
#       Scripts/swiftpm.sh test
#       Scripts/swiftpm.sh run aipet status
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLT="/Library/Developer/CommandLineTools"
FIX="$ROOT/.build/clt-fix"
mkdir -p "$FIX"

EXTRA_ARGS=()

# 修復 1:ManifestAPI 的 stale private interface
if ls "$CLT"/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface >/dev/null 2>&1; then
    if [ ! -d "$FIX/pm" ]; then
        cp -R "$CLT/usr/lib/swift/pm" "$FIX/pm"
        find "$FIX/pm" -name "*.private.swiftinterface" -delete
    fi
    export SWIFTPM_CUSTOM_LIBS_DIR="$FIX/pm"
fi

# 修復 2:重複定義 SwiftBridging 的殘留 modulemap
if [ -f "$CLT/usr/include/swift/module.modulemap" ] && [ -f "$CLT/usr/include/swift/bridging.modulemap" ]; then
    printf '// shadowed by AIPetUsage build: stale duplicate of SwiftBridging (real one lives in bridging.modulemap)\n' \
        > "$FIX/empty.modulemap"
    cat > "$FIX/overlay.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "type": "directory",
      "name": "$CLT/usr/include/swift",
      "contents": [
        { "type": "file", "name": "module.modulemap", "external-contents": "$FIX/empty.modulemap" }
      ]
    }
  ]
}
EOF
    EXTRA_ARGS+=(-Xswiftc -vfsoverlay -Xswiftc "$FIX/overlay.yaml")
fi

# 旗標必須緊跟在子命令(build/test/run)之後:
# `swift run <product> -Xswiftc …` 會把旗標傳給被執行的程式而不是編譯器。
SUBCOMMAND="${1:-build}"
shift || true
exec swift "$SUBCOMMAND" ${EXTRA_ARGS+"${EXTRA_ARGS[@]}"} "$@"
