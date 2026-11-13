#!/bin/bash
# Runs the Homebrew tests in a throwaway SwiftPM package with no remote dependencies.
#
# The package is assembled from copies of the engine sources and the test files, so its manifest
# has no `.package(url:)` entry and SwiftPM has nothing to fetch. Every brew command in the tests
# goes to a fake executable created under the throwaway folder. No test starts the App, the helper,
# a real Homebrew, or reads the user's preferences.
#
# The active toolchain must be able to parse Package.swift. On a machine that only has the Command
# Line Tools, set DEVELOPER_DIR to a complete Xcode before running:
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Tests/UI/run-isolated-tests.sh
#
# Usage:
#   Tests/UI/run-isolated-tests.sh             # model + engine Homebrew tests
#   Tests/UI/run-isolated-tests.sh --model-only
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
mode="${1:-all}"
case "$mode" in
  all|--model-only) ;;
  *) echo "usage: $0 [--model-only]" >&2; exit 2 ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/machelper-isolated-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

real_home="$HOME"
prefs="$real_home/Library/Preferences"
list_prefs() {
    if [ -d "$prefs" ]; then
        find "$prefs" -maxdepth 1 -name 'UpdatesModelTests-*' -exec basename {} \; | sort
    fi
}
before_prefs="$(list_prefs)"

mkdir -p "$work/Sources" "$work/Tests/UpdatesModelTests" "$work/Tests/EngineTests" \
         "$work/home" "$work/tmp"
cp -R "$root/Sources/CSystemBridge" "$work/Sources/CSystemBridge"
cp -R "$root/Sources/DiskScan" "$work/Sources/DiskScan"
cp -R "$root/Sources/PrivilegedOps" "$work/Sources/PrivilegedOps"
cp -R "$root/Sources/CleanEngine" "$work/Sources/CleanEngine"
mkdir -p "$work/Sources/UpdatesFeature"
cp "$root/App/Updates/UpdatesModel.swift" "$work/Sources/UpdatesFeature/UpdatesModel.swift"
cp "$here/UpdatesModelTests.swift" "$work/Tests/UpdatesModelTests/UpdatesModelTests.swift"
cp "$root/Tests/CleanEngineTests/CleanEngineTests.swift" "$work/Tests/EngineTests/CleanEngineTests.swift"
cp "$root/Tests/CleanEngineTests/HomebrewUpdatesCheckTests.swift" "$work/Tests/EngineTests/HomebrewUpdatesCheckTests.swift"

cat > "$work/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHelperIsolatedTests",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSystemBridge",
                linkerSettings: [
                    .linkedFramework("IOKit"),
                    .linkedFramework("CoreFoundation"),
                    .linkedLibrary("IOReport"),
                ]),
        .target(name: "DiskScan", dependencies: ["CSystemBridge"]),
        .target(name: "PrivilegedOps"),
        .target(name: "CleanEngine", dependencies: ["DiskScan", "PrivilegedOps"],
                resources: [.copy("Rules"), .copy("Artifacts"), .copy("UninstallRules"),
                            .process("Localizable.xcstrings"), .process("Rules.xcstrings")]),
        .target(name: "UpdatesFeature", dependencies: ["CleanEngine"]),
        .testTarget(name: "UpdatesModelTests", dependencies: ["UpdatesFeature", "CleanEngine"]),
        .testTarget(name: "EngineTests", dependencies: ["CleanEngine"]),
    ]
)
EOF

# Keep the isolation property explicit: a remote package would make resolution able to reach the
# network even though the flags below would try to stop it.
if grep -q '\.package(url:' "$work/Package.swift"; then
    echo "error: the isolated test manifest must not contain remote package dependencies" >&2
    exit 1
fi

cd "$work"
export HOME="$work/home"
export TMPDIR="$work/tmp"

# The manifest has no remote packages. These flags make a resolution attempt fail instead of
# silently reaching the network if one is ever added.
swift test --package-path "$work" --disable-automatic-resolution --skip-update --filter 'UpdatesModelTests|UpdatesFreshnessTests'
if [ "$mode" = "all" ]; then
    swift test --package-path "$work" --disable-automatic-resolution --skip-update \
        --filter 'HomebrewUpdatesCheckTests|UpdatesHeadlineTests|HomebrewUpdateSessionTests|HomebrewUpdatesPerformanceTests'
fi

after_prefs="$(list_prefs)"
if [ "$before_prefs" != "$after_prefs" ]; then
    echo "error: tests added preference files under $prefs" >&2
    diff <(printf '%s\n' "$before_prefs") <(printf '%s\n' "$after_prefs") >&2 || true
    exit 1
fi
