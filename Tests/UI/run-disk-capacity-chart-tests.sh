#!/bin/bash
#
# Runs the DiskCapacityHistory chart tests in a throwaway SwiftPM package.
#
# The package is assembled from copies of the production chart and the upstream Storage value
# types, so the manifest has no `.package(url:)` entry and SwiftPM has nothing to fetch. The
# shared design system is replaced by a small stub (see TestSupport.swift below), so the test
# never reads ThemeStore, user preferences, the app, the helper or the real disk. Every point is
# synthetic; nothing opens the history database.
#
# The local GRDB checkout is used read-only because the upstream Storage file imports GRDB. It is
# never modified; SwiftPM builds it inside this throwaway folder. Set MACHELPER_GRDB_CHECKOUT
# when the checkout lives elsewhere.
#
# Requirements: a complete Xcode with the macOS SDK and xcstringstool. Set DEVELOPER_DIR when
# xcode-select points at the command-line tools:
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Tests/UI/run-disk-capacity-chart-tests.sh
#
# Usage:
#   Tests/UI/run-disk-capacity-chart-tests.sh
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

work="$(mktemp -d "${TMPDIR:-/tmp}/machelper-disk-capacity-chart-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Keep every write SwiftPM, the compiler and the tests make inside this throwaway folder.
export HOME="$work/home"
export TMPDIR="$work/tmp"
echo "isolated test package: $work (HOME and TMPDIR are inside it)"
mkdir -p "$HOME" "$TMPDIR" \
         "$work/Sources/Storage" \
         "$work/Sources/DiskCapacityHistoryFeature" \
         "$work/Tests/DiskCapacityHistoryChartTests/Resources/Localizations"

cp "$root/Sources/Storage/VolumeCapacityHistory.swift" "$work/Sources/Storage/VolumeCapacityHistory.swift"
cp "$root/Sources/Storage/HistorySegments.swift" "$work/Sources/Storage/HistorySegments.swift"
# HistorySegments also holds the bucket overload, so its real value types come along.
cp "$root/Sources/Storage/SeriesHistory.swift" "$work/Sources/Storage/SeriesHistory.swift"
cp "$root/Sources/Storage/FinishedMinute.swift" "$work/Sources/Storage/FinishedMinute.swift"
cp "$root/App/Monitor/DiskCapacityHistoryChart.swift" "$work/Sources/DiskCapacityHistoryFeature/DiskCapacityHistoryChart.swift"
cp "$here/DiskCapacityHistoryChartTests.swift" "$work/Tests/DiskCapacityHistoryChartTests/DiskCapacityHistoryChartTests.swift"
cp "$root/App/Resources/DiskCapacityHistory.xcstrings" "$work/Tests/DiskCapacityHistoryChartTests/Resources/DiskCapacityHistory.xcstrings"

# Compile the real catalog into the test bundle so the tests can resolve every key through the
# same table name the view uses. The source catalog is copied too for the completeness check.
xcrun xcstringstool compile "$work/Tests/DiskCapacityHistoryChartTests/Resources/DiskCapacityHistory.xcstrings" \
    --output-directory "$work/Tests/DiskCapacityHistoryChartTests/Resources/Localizations"

# The production chart uses the app's shared visual language. These stubs keep that surface and
# replace the ThemeStore-backed implementation, which would otherwise read user preferences.
cat > "$work/Sources/DiskCapacityHistoryFeature/TestSupport.swift" <<'EOF'
import AppKit
import SwiftUI

// Test-only stand-ins for the app design system. Only the look is replaced; the production chart
// is compiled unchanged. The red accent is deliberately distinctive so the pixel checks can
// count the real marks without mistaking the theme's normal cyan for a mark.
enum Theme {
    static let cyan = Color(red: 0.9, green: 0.05, blue: 0.05)
    static var smallNumeral: Font { .system(size: 10 * DiskCapacityHistoryTestFontScale.value, design: .monospaced) }
}

enum Palette {
    static let text = Color.black
    static let textMuted = Color(white: 0.35)
    static let textFaint = Color(white: 0.55)
    static let inset = Color(white: 0.94)
}

struct SurfaceShape: InsettableShape {
    var cornerRadius: CGFloat
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.cornerRadius = cornerRadius
    }

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> SurfaceShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// Simulates the app's text-size setting. The tests raise it to check that the chart still
/// renders at the menu width without reading ThemeStore.
enum DiskCapacityHistoryTestFontScale {
    nonisolated(unsafe) static var value: CGFloat = 1
}

extension Font {
    static func mh(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * DiskCapacityHistoryTestFontScale.value, weight: weight, design: design)
    }
}
EOF

# The copied upstream store calls a few members of other Storage files. These stubs keep it
# compiling without pulling in the history database or its migrations.
cat > "$work/Sources/Storage/TestStorageSupport.swift" <<'EOF'
import Foundation
import GRDB

/// Test-only stand-in for the shared history database wrapper. The chart never opens a
/// database; the copied upstream store only needs the type for its convenience init.
public struct MetricsHistory {
    public let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    /// The copied store asks the shared history for its whole-hour boundary. The chart never
    /// records, but the file must compile against the latest storage API.
    public static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

enum HistoryKind {
    case minuteSamples
}

/// The copied upstream store reads the clear marker through this type. The chart never records
/// or clears history, so no marker is returned.
enum HistorySetting {
    static func clearedAt(_ kind: HistoryKind, _ db: Database) throws -> Date? { nil }
}
EOF

cat > "$work/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskCapacityHistoryIsolatedTests",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$grdb"),
    ],
    targets: [
        .target(name: "Storage", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "DiskCapacityHistoryFeature", dependencies: ["Storage"]),
        .testTarget(
            name: "DiskCapacityHistoryChartTests",
            dependencies: ["DiskCapacityHistoryFeature", "Storage"],
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
    --filter 'DiskCapacityHistoryChartTests'
