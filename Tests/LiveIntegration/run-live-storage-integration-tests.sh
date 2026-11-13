#!/bin/bash
#
# Runs the menu panel's SSD and network sources against the live Storage module.
#
# `Tests/UI/run-monitor-panel-integration-tests.sh` compiles the real views but replaces
# `MetricsHistory`, `HistoryStore` and the rest of Storage with minimal stand-ins, because those
# files were being changed in parallel. That leaves a blind spot: an API or behaviour change in
# Storage would only show up after the app target was built. This runner closes the gap.
#
# The throwaway package is assembled from the working tree:
#
#   Sources/Storage/*.swift                         the whole live module (GRDB only)
#   Sources/Metrics/*.swift                         the live reading types
#   Sources/SMCKit/*.swift, Sources/CSystemBridge   the thin layers Metrics needs
#   App/Monitor/MonitorPanel.swift                  whole menu panel (split for private tabs)
#   App/Monitor/DiskCapacitySelectionModel.swift    selection, disk and history state
#   App/Monitor/DiskCapacityHistoryChart.swift      seven-day free-space chart
#   App/Monitor/NetworkDetailsSection.swift         network page's live section
#   App/Monitor/NetworkDetailsContent.swift         network page's presentation-only content
#   App/Monitor/HistoryManagementSection.swift      settings section for monitoring history
#   App/Monitor/Formatting.swift                    Fmt
#   Tests/LiveIntegration/LiveStorageIntegrationTests.swift
#
# The manifest below records the SHA-256 of every source this run compiled, so a later run can
# prove which working-tree version produced the result.
#
# Stand-ins (also listed in the test file):
#
#   * `MonitorStore`, `LiveHistory`, `SeriesKey`, `ChartPoint`: the real store owns hardware
#     samplers, the shared database and the background loops. The stand-in exposes only the
#     properties the panel reads and records `watchProcesses` calls. Its `persistentHistory`
#     holds the real live `MetricsHistory` the test creates.
#   * The design system (`Theme`, `Palette`, `SurfaceShape`, small components and fonts): the
#     real one reads `ThemeStore` and user appearance preferences. The stand-ins keep the same
#     signatures and draw plain shapes, so the production bodies compile and render unchanged.
#   * `HelperClient`, `ThemeStore`, `UpdateAvailableButton`, `Host`, `AppSection`: app-shell
#     types the panel mentions. `Host`'s members added by `MonitorPanel.swift` are compiled as
#     written; the base type is empty because no menu tab used here reads the machine model.
#   * `MonitorPanel.swift`'s private `Series`, `DiskTab`, `DiskSectionHeader` and `NetworkTab`
#     are extracted byte-for-byte by `generate-panel-sections.py` (only `private` removed) so the
#     test target can construct them. The generator reverses those edits and compares against the
#     original blocks. `DiskTabRender` drops only the `.task`/`.onReceive` block because
#     `ImageRenderer` can run lifecycle modifiers in-process; `NetworkTabRender` replaces only
#     the live `NetworkDetailsSection()` call with a boundary view. The full production
#     `DiskTab`/`NetworkTab` remain compiled and are what `MonitorPanel` uses.
#
# Not exercised (there is no safe way to do it in a test process):
#
#   * Disk Arbitration, `getifaddrs`, `sysctl`, SystemConfiguration, SMC/IOReport and every
#     other native sampler. The volume list and the capacity readings are fake values; the
#     network page is rendered from a synthetic `NetworkDetailsSnapshot`.
#   * The real background service (`SMAppService`), the helper, the menu bar and a full app
#     launch.
#   * The app's final bundle-localized strings: the catalogs are compiled and shipped with the
#     test bundle, but production code asks `Bundle.main`, which is the test runner here.
#
# The GRDB checkout is used read-only; SwiftPM builds it inside the throwaway folder. Set
# MACHELPER_GRDB_CHECKOUT when it lives elsewhere. The manifest must not contain
# `.package(url:)`, and the run uses `--disable-automatic-resolution` so a resolution attempt
# fails instead of reaching the network.
#
# Every write, including `HOME`, `CFFIXED_USER_HOME`, `TMPDIR` and caches, stays inside the
# throwaway folder. The test asserts that `MetricsHistory.defaultURL` and the agent file URLs
# resolve inside that scratch home before it opens anything.
#
# Requirements: a complete Xcode with the macOS SDK and xcstringstool. Set DEVELOPER_DIR when
# xcode-select points at the command-line tools:
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Tests/LiveIntegration/run-live-storage-integration-tests.sh
#
# Set MACHELPER_LIVE_SCRATCH_ROOT to change the scratch disk (default below). Set
# MACHELPER_KEEP_WORK=1 to keep the throwaway package for debugging; the default removes
# exactly the directory this script created. The test log is kept in the scratch root either
# way.
#
# Usage:
#   Tests/LiveIntegration/run-live-storage-integration-tests.sh
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

scratch_root="${MACHELPER_LIVE_SCRATCH_ROOT:-/Volumes/Smile-Data/MainData/opencode-scratch}"
if ! mkdir -p "$scratch_root" 2>/dev/null; then
    scratch_root="${TMPDIR:-/tmp}"
    mkdir -p "$scratch_root"
fi
work="$(mktemp -d "$scratch_root/machelper-live-storage-tests.XXXXXX")"
log="$scratch_root/$(basename "$work").log"
cleanup() {
    if [[ "${MACHELPER_KEEP_WORK:-0}" == "1" ]]; then
        echo "kept isolated live test package: $work"
    else
        rm -rf "$work"
    fi
    echo "test log: $log"
}
trap cleanup EXIT

# Keep every write SwiftPM, the compiler and the tests make inside this throwaway folder.
# Foundation's homeDirectoryForCurrentUser honours CFFIXED_USER_HOME, not HOME; the isolation
# test asserts the default database URLs resolve under this path before opening anything.
export HOME="$work/home"
export CFFIXED_USER_HOME="$work/home"
export TMPDIR="$work/tmp"
export XDG_CACHE_HOME="$work/cache"
export MACHELPER_LIVE_SCRATCH_HOME="$work/home"
echo "isolated live test package: $work (HOME, CFFIXED_USER_HOME, TMPDIR and caches are inside it)"
mkdir -p "$HOME" "$TMPDIR" "$XDG_CACHE_HOME" \
         "$work/package/Sources/HelperProtocol" \
         "$work/package/Sources/CSystemBridge" \
         "$work/package/Sources/SMCKit" \
         "$work/package/Sources/Metrics" \
         "$work/package/Sources/Storage" \
         "$work/package/Sources/MonitorPanelFeature" \
         "$work/package/Tests/LiveStorageIntegrationTests/Resources/Localizations"

cp -R "$root/Sources/CSystemBridge/." "$work/package/Sources/CSystemBridge/"
cp "$root"/Sources/SMCKit/*.swift "$work/package/Sources/SMCKit/"
cp "$root"/Sources/Metrics/*.swift "$work/package/Sources/Metrics/"
# The live Storage module: every file, not a snapshot and not a stand-in.
cp "$root"/Sources/Storage/*.swift "$work/package/Sources/Storage/"
cp "$root/App/Monitor/DiskCapacitySelectionModel.swift" "$work/package/Sources/MonitorPanelFeature/DiskCapacitySelectionModel.swift"
cp "$root/App/Monitor/DiskCapacityHistoryChart.swift" "$work/package/Sources/MonitorPanelFeature/DiskCapacityHistoryChart.swift"
cp "$root/App/Monitor/NetworkDetailsSection.swift" "$work/package/Sources/MonitorPanelFeature/NetworkDetailsSection.swift"
cp "$root/App/Monitor/NetworkDetailsContent.swift" "$work/package/Sources/MonitorPanelFeature/NetworkDetailsContent.swift"
cp "$root/App/Monitor/HistoryManagementSection.swift" "$work/package/Sources/MonitorPanelFeature/HistoryManagementSection.swift"
cp "$root/App/Monitor/Formatting.swift" "$work/package/Sources/MonitorPanelFeature/Formatting.swift"
cp "$here/Support/PanelTestSupport.swift" "$work/package/Sources/MonitorPanelFeature/PanelTestSupport.swift"
cp "$here/LiveStorageIntegrationTests.swift" "$work/package/Tests/LiveStorageIntegrationTests/LiveStorageIntegrationTests.swift"
cp "$root/App/Resources/DiskVolumeSelection.xcstrings" "$work/package/Tests/LiveStorageIntegrationTests/Resources/DiskVolumeSelection.xcstrings"
cp "$root/App/Resources/DiskCapacityHistory.xcstrings" "$work/package/Tests/LiveStorageIntegrationTests/Resources/DiskCapacityHistory.xcstrings"
cp "$root/App/Resources/NetworkDetails.xcstrings" "$work/package/Tests/LiveStorageIntegrationTests/Resources/NetworkDetails.xcstrings"

cat > "$work/package/Sources/HelperProtocol/Placeholder.swift" <<'EOF'
/// The menu panel only imports HelperProtocol for the app-shell helper status, which is a
/// stand-in here. An empty module keeps the import compiling without pulling in the helper
/// protocol or its security surface.
public enum HelperProtocolPlaceholder {}
EOF

# Split the private page sections out of the live MonitorPanel.swift, exactly as the UI script
# does. The generator verifies that reversing its edits reproduces the source blocks, and it
# records the hash of the production file it read.
python3 "$here/generate-panel-sections.py" \
        "$root/App/Monitor/MonitorPanel.swift" \
        "$work/package/Sources/MonitorPanelFeature/MonitorPanel.swift" \
        "$work/package/Sources/MonitorPanelFeature/MonitorPanelSections.swift" \
        "$work/package/Sources/MonitorPanelFeature/MonitorPanelRenderSections.swift"

cat > "$work/package/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveStorageIsolatedTests",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$grdb"),
    ],
    targets: [
        .target(
            name: "CSystemBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("IOReport"),
            ]
        ),
        .target(name: "SMCKit", dependencies: ["CSystemBridge"]),
        .target(
            name: "Metrics",
            dependencies: ["CSystemBridge", "SMCKit"],
            linkerSettings: [.linkedFramework("DiskArbitration")]
        ),
        .target(
            name: "Storage",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "HelperProtocol"),
        .target(
            name: "MonitorPanelFeature",
            dependencies: ["Metrics", "SMCKit", "Storage", "HelperProtocol"]
        ),
        .testTarget(
            name: "LiveStorageIntegrationTests",
            dependencies: [
                "MonitorPanelFeature", "Metrics", "SMCKit", "Storage",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Resources")]
        ),
    ]
)
EOF

# Compile the real catalogs into the test bundle. The production views call `localized()` with
# Bundle.main, which is the test runner here, so this checks the catalogs parse and ships them
# with the test bundle; it does not claim the app's final string resolution.
for catalog in DiskVolumeSelection DiskCapacityHistory NetworkDetails; do
    xcrun xcstringstool compile "$work/package/Tests/LiveStorageIntegrationTests/Resources/$catalog.xcstrings" \
        --output-directory "$work/package/Tests/LiveStorageIntegrationTests/Resources/Localizations"
done

# Keep the isolation property explicit: a remote package would make resolution able to reach the
# network even though the flags below would try to stop it.
if grep -q '\.package(url:' "$work/package/Package.swift"; then
    echo "error: the isolated test manifest must not contain remote package dependencies" >&2
    exit 1
fi

echo "--- live source manifest (sha256 of the working tree files this run compiled) ---"
echo "git HEAD: $(git -C "$root" rev-parse HEAD)"
echo "working tree changes: $(git -C "$root" status --porcelain | wc -l | tr -d ' ') paths"
for file in \
    "$root"/Sources/Storage/*.swift \
    "$root"/Sources/Metrics/*.swift \
    "$root"/Sources/SMCKit/*.swift \
    "$root/App/Monitor/MonitorPanel.swift" \
    "$root/App/Monitor/DiskCapacitySelectionModel.swift" \
    "$root/App/Monitor/DiskCapacityHistoryChart.swift" \
    "$root/App/Monitor/NetworkDetailsSection.swift" \
    "$root/App/Monitor/NetworkDetailsContent.swift" \
    "$root/App/Monitor/HistoryManagementSection.swift" \
    "$root/App/Monitor/Formatting.swift" \
    "$here/LiveStorageIntegrationTests.swift" \
    "$here/Support/PanelTestSupport.swift" \
    "$here/generate-panel-sections.py" \
    "$here/run-live-storage-integration-tests.sh"; do
    printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "${file#"$root"/}"
done
echo "--- end manifest ---"

set +e
swift test --package-path "$work/package" \
    --disable-automatic-resolution \
    --filter 'LiveStorageIntegrationTests' 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
echo "swift test exit status: $status"
exit "$status"
