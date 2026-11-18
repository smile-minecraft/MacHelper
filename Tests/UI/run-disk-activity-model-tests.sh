#!/bin/zsh
# Standalone check of the production DiskIOSection / DiskActivityModel sampling lifecycle.
#
# It copies only the files these checks need into a throwaway package:
#   Sources/Metrics/{ProcessDiskIO,ProcessGrouping,Processes}.swift
#   App/Monitor/{DiskActivityModel,DiskIOSection}.swift
#   Tests/UI/{SamplingTestSupport,DiskActivityModelTests,DiskIOSectionTests,DiskIOSectionDisplayStandins}.swift
# The display stand-ins (linked into the same target as the production section, mirroring the app's
# single-module layout) substitute only DiskIOSection's display dependencies (theme colors, text
# tools, Meter, SkeletonRows, ProcessIcon) so the unmodified production section can mount
# headlessly; the section and the model compile from the production sources themselves.
# No network, no GRDB, no string-table toolchain, no checkout of this repository. The host window
# is never shown or activated. The throwaway directory is deleted on exit.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/machelper-disk-activity.XXXXXX")
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/package/sources/metrics" "$work/package/sources/feature" "$work/package/tests"

cp "$repo_root/Sources/Metrics/ProcessDiskIO.swift" "$repo_root/Sources/Metrics/ProcessGrouping.swift" "$repo_root/Sources/Metrics/Processes.swift" "$work/package/sources/metrics/"
cp "$repo_root/App/Monitor/DiskActivityModel.swift" "$repo_root/App/Monitor/DiskIOSection.swift" "$work/package/sources/feature/"
# Same target as the production section so their internal symbols are visible, as in the app.
cp "$repo_root/Tests/UI/DiskIOSectionDisplayStandins.swift" "$work/package/sources/feature/"
cp "$repo_root/Tests/UI/SamplingTestSupport.swift" "$repo_root/Tests/UI/DiskActivityModelTests.swift" "$repo_root/Tests/UI/DiskIOSectionTests.swift" "$work/package/tests/"

cat > "$work/package/Package.swift" <<'EOF'
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DiskActivityCheck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Metrics", path: "sources/metrics"),
        .target(name: "DiskActivityFeature", dependencies: ["Metrics"], path: "sources/feature"),
        .testTarget(name: "DiskActivityModelTests", dependencies: ["DiskActivityFeature", "Metrics"], path: "tests"),
    ]
)
EOF

if command -v xcrun >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1; then
    SWIFT=$(xcrun --find swift)
else
    SWIFT=$(command -v swift)
fi
case "$SWIFT" in
    /*) ;;
    *) SWIFT=$(command -v "$SWIFT") ;;
esac

"$SWIFT" test \
    --package-path "$work/package" \
    --disable-automatic-resolution \
    --jobs 2 \
    --filter DiskActivityModelLifecycleTests --filter DiskIOSectionTests
