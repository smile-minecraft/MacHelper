#!/bin/bash
# 用完整 Xcode 的工具鏈跑這個獨立驗證套件。
#
# 為什麼需要指定 DEVELOPER_DIR：這台機器 `xcode-select -p` 指向 Command Line Tools，
# 而 CLT 的 Swift 6.4.0 會讓 SwiftPM manifest 連到不存在的
# PackageDescription.Package.__allocating_init(...swiftLanguageVersions...)。
# Xcode 27.2 的 Swift 6.4.2 不會。詳見同資料夾的 README.md。
set -euo pipefail

cd "$(dirname "$0")"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer}"
export DEVELOPER_DIR

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    echo "找不到可用的 Swift 工具鏈：DEVELOPER_DIR=$DEVELOPER_DIR" >&2
    exit 1
fi

exec /usr/bin/swift test "$@"
