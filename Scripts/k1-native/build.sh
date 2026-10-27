#!/bin/bash
# build.sh — 編譯 K1-NATIVE 工具 k1ctx(或其單元測試 runner)。
#
# 建置模型(owner N3,已記錄於 README.md):獨立的 Swift 原始碼(Scripts/k1-native/*.swift),以 Apple 工具鏈的 swiftc 直接
# 編譯成單一執行檔 —— 不是 Package.swift 的 target(不擴張 App runtime 架構)、不下載任何相依、只連結 Darwin/libSystem。
# 原始碼屬於不可變的 repo / tag;CI 與 release 都從「本次 checkout 的這份原始碼」編譯;編譯失敗 = 非零退出(fail-closed),
# 不留任何部分輸出。
#
# 用法:Scripts/k1-native/build.sh <絕對輸出路徑>            → 編譯 k1ctx
#       Scripts/k1-native/build.sh --tests <絕對輸出路徑>    → 編譯單元測試 runner(K1Native.swift + Tests/main.swift)
# 環境:SWIFTC(預設 swiftc;CI 的 macos runner 工具鏈健全;本機若 CommandLineTools 損壞,可改指向可用的 swiftc)。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode=tool
if [ "${1:-}" = --tests ]; then mode=tests; shift; fi
out="${1:-}"
if [ -z "$out" ]; then
    echo "usage: build.sh [--tests] <absolute-output-path>" >&2
    exit 2
fi
case "$out" in
    /*) ;;
    *) echo "build.sh: 輸出路徑須為絕對路徑:$out" >&2; exit 2 ;;
esac
if [ "$#" -ne 1 ]; then echo "build.sh: 多餘參數" >&2; exit 2; fi

SWIFTC="${SWIFTC:-swiftc}"
if [ "$mode" = tests ]; then
    srcs=("$HERE/K1Native.swift" "$HERE/Tests/main.swift"); module=k1ctx_tests
else
    srcs=("$HERE/K1Native.swift" "$HERE/main.swift"); module=k1ctx
fi
for s in "${srcs[@]}"; do
    [ -f "$s" ] || { echo "build.sh: 原始碼不存在:$s" >&2; exit 1; }
done

# 先編到同目錄的暫存名再原子換名:編譯失敗時絕不留下半成品;舊的輸出(若有)在成功前不被動到。
tmp="$out.build.$$"
trap 'rm -f "$tmp"' EXIT
"$SWIFTC" -swift-version 5 -O -module-name "$module" -o "$tmp" "${srcs[@]}"
[ -x "$tmp" ] || { echo "build.sh: 編譯器未產出可執行檔" >&2; exit 1; }
mv -f "$tmp" "$out"
trap - EXIT
