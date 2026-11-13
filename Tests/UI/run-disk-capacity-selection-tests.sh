#!/bin/bash
#
# Runs the disk capacity selection tests in a throwaway SwiftPM package.
#
# The package is assembled from copies of the production selection model, the upstream disk
# volume types, and the per-volume capacity value types, so the manifest has no `.package(url:)`
# entry and SwiftPM has nothing to fetch. The test uses fake volumes and a fake history reader
# only: it never samples a real disk, opens the history database, starts the app or the helper,
# or reads user preferences.
#
# The local GRDB checkout is used read-only because the upstream Storage file imports GRDB. It is
# never modified; SwiftPM builds it inside this throwaway folder. Set MACHELPER_GRDB_CHECKOUT
# when the checkout lives elsewhere.
#
# During parallel work on the live VolumeCapacityHistory.swift, point
# MACHELPER_VOLUME_CAPACITY_SOURCE at a reviewed snapshot of that file and pass its sha256 in
# MACHELPER_VOLUME_CAPACITY_SHA256. Without the override the script copies the live file.
#
# Requirements: a complete Xcode with the macOS SDK and xcstringstool. Set DEVELOPER_DIR when
# xcode-select points at the command-line tools:
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Tests/UI/run-disk-capacity-selection-tests.sh
#
# Usage:
#   Tests/UI/run-disk-capacity-selection-tests.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-*.app /Volumes/Smile-Data/Applications/Xcode-*.app; do
        if [[ -d "$candidate/Contents/Developer" ]]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "error: swift is unavailable; set DEVELOPER_DIR to an Xcode with the macOS SDK" >&2
    exit 1
fi
if ! xcrun --find xcstringstool >/dev/null 2>&1; then
    echo "error: xcstringstool is unavailable; set DEVELOPER_DIR to a complete Xcode" >&2
    exit 1
fi

grdb="${MACHELPER_GRDB_CHECKOUT:-}"
if [[ -z "$grdb" ]]; then
    for candidate in \
        "$root/.build/checkouts/GRDB.swift" \
        "/Volumes/Smile-Data/MainData/Project-Nest/MacHelper/.build/checkouts/GRDB.swift"; do
        if [[ -d "$candidate" ]]; then
            grdb="$candidate"
            break
        fi
    done
fi
if [[ ! -d "$grdb" ]]; then
    echo "error: GRDB.swift checkout not found; set MACHELPER_GRDB_CHECKOUT" >&2
    exit 1
fi

volume_history="${MACHELPER_VOLUME_CAPACITY_SOURCE:-$root/Sources/Storage/VolumeCapacityHistory.swift}"
if [[ ! -f "$volume_history" ]]; then
    echo "error: VolumeCapacityHistory.swift not found at $volume_history" >&2
    exit 1
fi
if [[ -n "${MACHELPER_VOLUME_CAPACITY_SHA256:-}" ]]; then
    actual="$(shasum -a 256 "$volume_history" | awk '{print $1}')"
    if [[ "$actual" != "$MACHELPER_VOLUME_CAPACITY_SHA256" ]]; then
        echo "error: VolumeCapacityHistory.swift sha256 is $actual, expected $MACHELPER_VOLUME_CAPACITY_SHA256" >&2
        exit 1
    fi
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/machelper-disk-selection-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Keep every write SwiftPM, the compiler and the tests make inside this throwaway folder.
export HOME="$work/home"
export TMPDIR="$work/tmp"
echo "isolated test package: $work (HOME and TMPDIR are inside it)"
echo "capacity source: $volume_history"
mkdir -p "$HOME" "$TMPDIR" \
         "$work/Sources/Metrics" \
         "$work/Sources/Storage" \
         "$work/Sources/DiskCapacitySelectionFeature" \
         "$work/Tests/DiskCapacitySelectionTests/Resources/Localizations"

cp "$root/Sources/Metrics/DiskVolumes.swift" "$work/Sources/Metrics/DiskVolumes.swift"
cp "$volume_history" "$work/Sources/Storage/VolumeCapacityHistory.swift"
cp "$root/App/Monitor/DiskCapacitySelectionModel.swift" "$work/Sources/DiskCapacitySelectionFeature/DiskCapacitySelectionModel.swift"
cp "$here/DiskCapacitySelectionTests.swift" "$work/Tests/DiskCapacitySelectionTests/DiskCapacitySelectionTests.swift"
cp "$root/App/Resources/DiskVolumeSelection.xcstrings" "$work/Tests/DiskCapacitySelectionTests/Resources/DiskVolumeSelection.xcstrings"

# The copied upstream store references two types and one helper from other Storage files that
# the selection model never uses. These stubs keep the store compiling without pulling in the
# history database.
cat > "$work/Sources/Storage/ScratchSupport.swift" <<'EOF'
import Foundation
import GRDB

/// Test-only stand-in for the shared history database wrapper. The selection model never opens
/// a database; the copied upstream store only needs the type to declare its convenience init.
public struct MetricsHistory {
    public let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    /// The copied store asks the shared history for its whole-hour boundary. The selection
    /// tests never record, but the file must compile against the latest storage API.
    public static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

enum HistoryKind {
    case minuteSamples
}

/// The copied upstream store reads the clear marker through this type. The selection tests never
/// record or clear history, so no marker is returned.
enum HistorySetting {
    static func clearedAt(_ kind: HistoryKind, _ db: Database) throws -> Date? { nil }
}
EOF

# Compile the real catalog into the test bundle so the tests can resolve every key through the
# same table name the view uses. The source catalog is copied too for the completeness check.
xcrun xcstringstool compile "$work/Tests/DiskCapacitySelectionTests/Resources/DiskVolumeSelection.xcstrings" \
    --output-directory "$work/Tests/DiskCapacitySelectionTests/Resources/Localizations"

cat > "$work/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskCapacitySelectionIsolatedTests",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$grdb"),
    ],
    targets: [
        .target(
            name: "Metrics",
            linkerSettings: [.linkedFramework("DiskArbitration")]
        ),
        .target(
            name: "Storage",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "DiskCapacitySelectionFeature",
            dependencies: ["Metrics", "Storage"]
        ),
        .testTarget(
            name: "DiskCapacitySelectionTests",
            dependencies: ["DiskCapacitySelectionFeature", "Metrics", "Storage"],
            resources: [.copy("Resources")]
        ),
    ]
)
EOF

# Keep the isolation property explicit: a remote package would make resolution able to reach the
# network even though the flags below would try to stop it.
if grep -q '\.package(url:' "$work/Package.swift"; then
    echo "error: the isolated test manifest must not contain remote package dependencies" >&2
    exit 1
fi

swift test --package-path "$work" \
    --disable-automatic-resolution \
    --filter 'DiskCapacitySelectionTests'
