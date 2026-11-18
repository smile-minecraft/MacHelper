#!/bin/bash
#
# Type-checks and renders the real menu-bar SSD and network pages in a throwaway SwiftPM package.
#
# The package is assembled from copies of the production files, so the manifest has no
# `.package(url:)` entry and SwiftPM has nothing to fetch:
#
#   App/Monitor/MonitorPanel.swift                  the whole menu panel (split for private tabs)
#   App/Monitor/DiskCapacitySelectionModel.swift    selection, volume and history state
#   App/Monitor/DiskCapacityHistoryChart.swift      seven-day free-space chart
#   App/Monitor/NetworkDetailsSection.swift         the network page's live section
#   App/Monitor/NetworkDetailsContent.swift         the network page's presentation-only content
#   App/Monitor/HistoryManagementSection.swift      the settings section for monitoring history
#   App/Monitor/Formatting.swift                    Fmt
#   Sources/Metrics/*.swift                         real reading types and the network/disk values
#   Sources/SMCKit/*.swift                          real fan reading type
#   Sources/CSystemBridge                           the thin C layer those modules use
#
# `MonitorPanel`'s `DiskTab`, `DiskSectionHeader` and `NetworkTab` are private to the file, so the
# script compiles the panel in two parts: `MonitorPanel.swift` without those four declarations
# (the panel, the other tabs and all helpers), and `MonitorPanelSections.swift` with the extracted
# declarations. The extracted text is byte-for-byte the source; only `private` is removed from the
# four declarations so the test target can construct them. The generator reverses those edits and
# compares against the original blocks. Every line of the production file is still compiled, and
# `MonitorPanel` keeps referring to the same types because both parts are in one module.
#
# Stand-ins (all listed here so the limits of the result are explicit):
#
#   * `MonitorStore`, `LiveHistory`, `SeriesKey`, `ChartPoint`: the real store owns live hardware
#     samplers, the shared history database and the background recording loops. The stand-in only
#     exposes the properties the panel reads and records `watchProcesses` calls.
#   * The design system (`Theme`, `Palette`, `SurfaceShape`, the small components and fonts):
#     the real one reads `ThemeStore` and user appearance preferences. The stand-ins keep the
#     same init signatures and draw plain shapes, so the production view bodies compile and
#     render unchanged.
#   * `HelperClient`, `ThemeStore`, `UpdateAvailableButton`, `Host`, `AppSection`: app-shell
#     types the panel mentions. `Host`'s members added by `MonitorPanel.swift` are compiled as
#     written; the base type is empty because no menu tab used here reads the machine model.
#   * `MetricsHistory`, `HistorySetting`, `HistoryKind`, `HistoryStore`, `HistoryRetention`,
#     `HistoryDiskUsage`, `SeriesBucket`: the real Storage files are being changed in parallel.
#     `VolumeCapacityHistory` is compiled from a fixed snapshot; the rest are minimal stand-ins.
#     The in-memory GRDB database in the test is created and filled by the test itself.
#
# The network section's default `NetworkDetailsSampler` reads real interfaces. The test never
# renders that section: `NetworkTabRender` replaces exactly that one call with a boundary view,
# and the real `NetworkTab` body is built and type-checked but never hosted. This is required
# because `ImageRenderer` was observed to run SwiftUI lifecycle modifiers in the test process;
# `DiskTabRender` therefore also drops the page's `.task`/`.onReceive` block and the test drives
# the model directly. The full production `DiskTab`/`NetworkTab` (with those modifiers) remain
# compiled and are what `MonitorPanel` uses.
#
# The local GRDB checkout is used read-only because the upstream Storage file imports GRDB. It is
# never modified; SwiftPM builds it inside this throwaway folder. Set MACHELPER_GRDB_CHECKOUT
# when the checkout lives elsewhere.
#
# During parallel work on the live `Sources/Storage/VolumeCapacityHistory.swift`, point
# MACHELPER_VOLUME_CAPACITY_SOURCE at a reviewed snapshot of that file and pass its sha256 in
# MACHELPER_VOLUME_CAPACITY_SHA256. Without the override the script copies the live file.
# The same override mechanism exists for `HistorySegments.swift`; it is copied live by default and
# its sha256 is printed in the manifest below.
#
# Requirements: a complete Xcode with the macOS SDK and xcstringstool. Set DEVELOPER_DIR when
# xcode-select points at the command-line tools:
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Tests/UI/run-monitor-panel-integration-tests.sh
#
# Set MACHELPER_SCRATCH_ROOT to create the throwaway package under a specific disk (for example
# /Volumes/Smile-Data/MainData/opencode-scratch). Set MACHELPER_KEEP_WORK=1 to keep it for
# debugging; the default removes exactly the directory this script created.
#
# Usage:
#   Tests/UI/run-monitor-panel-integration-tests.sh
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

history_segments="${MACHELPER_HISTORY_SEGMENTS_SOURCE:-$root/Sources/Storage/HistorySegments.swift}"
if [[ ! -f "$history_segments" ]]; then
    echo "error: HistorySegments.swift not found at $history_segments" >&2
    exit 1
fi
if [[ -n "${MACHELPER_HISTORY_SEGMENTS_SHA256:-}" ]]; then
    actual="$(shasum -a 256 "$history_segments" | awk '{print $1}')"
    if [[ "$actual" != "$MACHELPER_HISTORY_SEGMENTS_SHA256" ]]; then
        echo "error: HistorySegments.swift sha256 is $actual, expected $MACHELPER_HISTORY_SEGMENTS_SHA256" >&2
        exit 1
    fi
fi

scratch_root="${MACHELPER_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$scratch_root"
work="$(mktemp -d "$scratch_root/machelper-monitor-panel-tests.XXXXXX")"
cleanup() {
    if [[ "${MACHELPER_KEEP_WORK:-0}" == "1" ]]; then
        echo "kept isolated test package: $work"
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT

# Keep every write SwiftPM, the compiler and the tests make inside this throwaway folder.
export HOME="$work/home"
export TMPDIR="$work/tmp"
export XDG_CACHE_HOME="$work/cache"
echo "isolated test package: $work (HOME, TMPDIR and caches are inside it)"
mkdir -p "$HOME" "$TMPDIR" "$XDG_CACHE_HOME" \
         "$work/package/Sources/HelperProtocol" \
         "$work/package/Sources/CSystemBridge" \
         "$work/package/Sources/SMCKit" \
         "$work/package/Sources/Metrics" \
         "$work/package/Sources/Storage" \
         "$work/package/Sources/MonitorPanelFeature" \
         "$work/package/Tests/MonitorPanelIntegrationTests/Resources/Localizations"

cp -R "$root/Sources/CSystemBridge/." "$work/package/Sources/CSystemBridge/"
cp "$root"/Sources/SMCKit/*.swift "$work/package/Sources/SMCKit/"
cp "$root"/Sources/Metrics/*.swift "$work/package/Sources/Metrics/"
cp "$volume_history" "$work/package/Sources/Storage/VolumeCapacityHistory.swift"
cp "$history_segments" "$work/package/Sources/Storage/HistorySegments.swift"
cp "$root/App/Monitor/DiskCapacitySelectionModel.swift" "$work/package/Sources/MonitorPanelFeature/DiskCapacitySelectionModel.swift"
cp "$root/App/Monitor/DiskCapacityHistoryChart.swift" "$work/package/Sources/MonitorPanelFeature/DiskCapacityHistoryChart.swift"
cp "$root/App/Monitor/NetworkDetailsSection.swift" "$work/package/Sources/MonitorPanelFeature/NetworkDetailsSection.swift"
cp "$root/App/Monitor/NetworkDetailsContent.swift" "$work/package/Sources/MonitorPanelFeature/NetworkDetailsContent.swift"
cp "$root/App/Monitor/HistoryManagementSection.swift" "$work/package/Sources/MonitorPanelFeature/HistoryManagementSection.swift"
cp "$root/App/Monitor/Formatting.swift" "$work/package/Sources/MonitorPanelFeature/Formatting.swift"
cp "$here/MonitorPanelIntegrationTests.swift" "$work/package/Tests/MonitorPanelIntegrationTests/MonitorPanelIntegrationTests.swift"
cp "$root/App/Resources/DiskVolumeSelection.xcstrings" "$work/package/Tests/MonitorPanelIntegrationTests/Resources/DiskVolumeSelection.xcstrings"
cp "$root/App/Resources/DiskCapacityHistory.xcstrings" "$work/package/Tests/MonitorPanelIntegrationTests/Resources/DiskCapacityHistory.xcstrings"
cp "$root/App/Resources/NetworkDetails.xcstrings" "$work/package/Tests/MonitorPanelIntegrationTests/Resources/NetworkDetails.xcstrings"

cat > "$work/package/Sources/HelperProtocol/Placeholder.swift" <<'EOF'
/// The menu panel only imports HelperProtocol for the app-shell helper status, which is a
/// stand-in here. An empty module keeps the import compiling without pulling in the helper
/// protocol or its security surface.
public enum HelperProtocolPlaceholder {}
EOF

# The real VolumeCapacityHistory snapshot calls two members of the shared history wrapper. The
# real Storage files are being changed in parallel, so the isolated package supplies the smallest
# surface the snapshot and the settings section need. The test creates a real in-memory GRDB
# database and fills the real table; these stand-ins never open a file or a user database.
cat > "$work/package/Sources/Storage/TestStorageSupport.swift" <<'EOF'
import Foundation
import GRDB

/// Stand-in for the shared history database wrapper. The menu views only need its connection and
/// the whole-hour boundary; the test supplies an in-memory GRDB database.
public struct MetricsHistory: Sendable {
    public let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

public enum HistoryKind: Sendable {
    case minuteSamples
    case seriesSamples
    case processSamples
}

/// The snapshot reads the monitoring clear marker only when a `history_setting` table exists.
/// The isolated in-memory database has no such table, so this is never called; it exists so the
/// unchanged snapshot compiles.
enum HistorySetting {
    static func clearedAt(_ kind: HistoryKind, _ db: Database) throws -> Date? { nil }
}

/// The second `HistorySegments.split` overload is compiled but not exercised here. The chart uses
/// the generic time-based overload; this shape keeps the unchanged file compiling.
public struct SeriesBucket: Sendable {
    public let time: Date
    public let value: Double
    public let lastSampleTime: Date
    public let storedMinuteCount: Int

    public init(time: Date, value: Double, lastSampleTime: Date, storedMinuteCount: Int) {
        self.time = time
        self.value = value
        self.lastSampleTime = lastSampleTime
        self.storedMinuteCount = storedMinuteCount
    }
}

/// Minimal stand-ins for the monitoring-history settings surface. `HistoryManagementSection` is
/// compiled and rendered with these; no real database or user setting is touched.
public enum HistoryRetention: String, CaseIterable, Hashable, Sendable {
    case oneDay, threeDays, sevenDays, fourteenDays, thirtyDays

    public static let `default` = HistoryRetention.sevenDays
}

public struct HistoryDiskUsage: Sendable, Equatable {
    public let totalBytes: Int64

    public init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }
}

public final class HistoryStore {
    public init() throws {}

    public func retention() throws -> HistoryRetention { .default }
    public func isProcessCollectionEnabled() throws -> Bool { false }
    public func isSeriesCollectionEnabled() throws -> Bool { false }
    public func diskUsage() -> HistoryDiskUsage? { HistoryDiskUsage(totalBytes: 0) }
    public func setRetention(_ retention: HistoryRetention) throws {}
    public func setProcessCollectionEnabled(_ enabled: Bool) throws {}
    public func setSeriesCollectionEnabled(_ enabled: Bool) throws {}
    public func clear(_ kind: HistoryKind) throws {}
}
EOF

# Extract the private page sections byte-for-byte. Only the four declarations named below lose
# `private`; the script then reverses those edits and compares against the original blocks. The
# panel file is written with exactly those blocks removed so the module has one copy of each type.
# A second generated file holds render-only variants: `DiskTabRender` is the same view body
# without the `.task`/`.onReceive` lifecycle modifiers (the test drives the model directly), and
# `NetworkTabRender` replaces the live `NetworkDetailsSection()` with a visible boundary stub.
# The generator records and verifies those exact differences so no other line can drift.
python3 - "$root/App/Monitor/MonitorPanel.swift" \
        "$work/package/Sources/MonitorPanelFeature/MonitorPanel.swift" \
        "$work/package/Sources/MonitorPanelFeature/MonitorPanelSections.swift" \
        "$work/package/Sources/MonitorPanelFeature/MonitorPanelRenderSections.swift" <<'PY'
import difflib
import hashlib
import pathlib
import sys

source_path = pathlib.Path(sys.argv[1])
panel_path = pathlib.Path(sys.argv[2])
sections_path = pathlib.Path(sys.argv[3])
render_path = pathlib.Path(sys.argv[4])
source = source_path.read_text()
lines = source.splitlines(keepends=True)

def block(start_index: int):
    depth = 0
    started = False
    collected = []
    for offset, line in enumerate(lines[start_index:]):
        collected.append(line)
        depth += line.count("{") - line.count("}")
        if "{" in line:
            started = True
        if started and depth == 0:
            return "".join(collected), start_index + offset
    raise SystemExit(f"unterminated block starting at line {start_index + 1}")

def find(declaration: str) -> int:
    matches = [i for i, line in enumerate(lines) if line.rstrip("\n") == declaration]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one {declaration!r}, found {len(matches)}")
    return matches[0]

def remove_braced(lines_to_scan, start_index: int):
    depth = 0
    started = False
    for offset, line in enumerate(lines_to_scan[start_index:]):
        depth += line.count("{") - line.count("}")
        if "{" in line:
            started = True
        if started and depth == 0:
            return start_index + offset
    raise SystemExit(f"unterminated braced block at line {start_index + 1}")

series_start = find("private enum Series {") - 1
if lines[series_start].rstrip("\n") != "@MainActor":
    raise SystemExit("Series block does not start with @MainActor")
starts = {
    "Series": series_start,
    "DiskTab": find("private struct DiskTab: View {"),
    "DiskSectionHeader": find("private struct DiskSectionHeader: View {"),
    "NetworkTab": find("private struct NetworkTab: View {"),
}

blocks = {}
ranges = {}
for name, start in starts.items():
    text, end = block(start)
    blocks[name] = text
    ranges[name] = (start, end)

edits = {
    "Series": ("@MainActor\nprivate enum Series {", "@MainActor\nenum Series {"),
    "DiskTab": ("private struct DiskTab: View {", "struct DiskTab: View {"),
    "DiskSectionHeader": ("private struct DiskSectionHeader: View {", "struct DiskSectionHeader: View {"),
    "NetworkTab": ("private struct NetworkTab: View {", "struct NetworkTab: View {"),
}

rendered = {}
for name, original in blocks.items():
    old, new = edits[name]
    if original.count(old) != 1:
        raise SystemExit(f"{name}: expected exactly one visibility edit")
    changed = original.replace(old, new)
    if changed.replace(new, old) != original:
        raise SystemExit(f"{name}: reversing the visibility edit did not reproduce the source")
    rendered[name] = changed

# Render-only DiskTab: same body minus the two lifecycle modifiers.
disk_tab = rendered["DiskTab"]
disk_render = disk_tab.replace("struct DiskTab: View {", "struct DiskTabRender: View {", 1)
if disk_render == disk_tab:
    raise SystemExit("DiskTabRender: name edit did not apply")
disk_lines = disk_render.splitlines(keepends=True)
task_start = next((i for i, line in enumerate(disk_lines) if line == "        .task {\n"), None)
if task_start is None:
    raise SystemExit("DiskTabRender: .task block not found")
task_end = remove_braced(disk_lines, task_start)
on_receive_start = task_end + 1
if not disk_lines[on_receive_start].startswith(
        "        .onReceive(NotificationCenter.default.publisher(for: .monitoringHistoryCleared))"):
    raise SystemExit("DiskTabRender: .onReceive block does not follow .task")
on_receive_end = remove_braced(disk_lines, on_receive_start)
removed = "".join(disk_lines[task_start:on_receive_end + 1])
for marker in (".task {", "selection.connect(reader:", "monitoringHistoryCleared", "selection.historyDidClear()"):
    if marker not in removed:
        raise SystemExit(f"DiskTabRender: removed block is missing {marker!r}")
without_lifecycle = "".join(disk_lines[:task_start] + disk_lines[on_receive_end + 1:])
reconstructed = "".join(disk_lines[:task_start]) + removed + "".join(disk_lines[on_receive_end + 1:])
if reconstructed != disk_render:
    raise SystemExit("DiskTabRender: removing the lifecycle block was not reversible")
if ".task {" in without_lifecycle or ".onReceive(" in without_lifecycle:
    raise SystemExit("DiskTabRender: a lifecycle modifier remains")
disk_render = without_lifecycle

# Render-only NetworkTab: same body with the live section replaced by a boundary stub.
network_tab = rendered["NetworkTab"]
network_render = network_tab.replace("struct NetworkTab: View {",
                                     "struct NetworkTabRender: View {", 1)
live_line = "            NetworkDetailsSection()\n"
boundary_line = "            NetworkDetailsSectionBoundary()\n"
if network_render.count(live_line) != 1:
    raise SystemExit("NetworkTabRender: expected exactly one NetworkDetailsSection() line")
network_render = network_render.replace(live_line, boundary_line, 1)
if network_render.replace(boundary_line, live_line, 1).replace(
        "struct NetworkTabRender: View {", "struct NetworkTab: View {", 1) != network_tab:
    raise SystemExit("NetworkTabRender: reversing the render edits did not reproduce the source")

def unified(original: str, changed: str, label: str) -> str:
    diff = difflib.unified_diff(original.splitlines(keepends=True),
                                changed.splitlines(keepends=True),
                                fromfile=label + " (source)",
                                tofile=label + " (generated)",
                                n=2)
    return "".join(diff)

removed = set()
for start, end in ranges.values():
    removed.update(range(start, end + 1))
panel = "".join(line for index, line in enumerate(lines) if index not in removed)
panel_path.write_text(panel)

common_header = (
    "// Generated by Tests/UI/run-monitor-panel-integration-tests.sh from\n"
    "// App/Monitor/MonitorPanel.swift. The declarations below are copied byte-for-byte from the\n"
    "// production file; only `private` was removed so the test target can construct and render\n"
    "// them. The generator verifies that reversing those edits reproduces the source blocks.\n"
    "// The same declarations are removed from the package's MonitorPanel.swift copy so the module\n"
    "// has one copy of each type; the rest of that file is compiled unchanged.\n"
    "// The imports mirror MonitorPanel.swift; the declarations are not edited.\n\n"
    "import AppKit\n"
    "import Charts\n"
    "import Metrics\n"
    "import Storage\n"
    "import SwiftUI\n\n"
)
sections = common_header + "\n".join(rendered[name] for name in ("Series", "DiskTab", "DiskSectionHeader", "NetworkTab"))
sections_path.write_text(sections)

boundary = '''
/// Test-only boundary for the live network section. `NetworkDetailsSection` owns a default
/// sampler that reads real interfaces; `NetworkTabRender` replaces that one call with this view
/// so the tab's production chrome can be rendered without a system read.
struct NetworkDetailsSectionBoundary: View {
    var body: some View {
        Text("Live network section boundary (not rendered)")
            .font(.mh(size: 10.5))
            .foregroundStyle(Palette.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Palette.inset, in: SurfaceShape(cornerRadius: 8, style: .continuous))
    }
}
'''
render_header = (
    "// Generated by Tests/UI/run-monitor-panel-integration-tests.sh from\n"
    "// App/Monitor/MonitorPanel.swift. These render-only variants exist because `ImageRenderer`\n"
    "// can run SwiftUI lifecycle modifiers in the same process: `DiskTabRender` drops only the\n"
    "// `.task`/`.onReceive` block (the test drives the model directly), and `NetworkTabRender`\n"
    "// replaces only the live `NetworkDetailsSection()` call with a boundary view. Every other\n"
    "// line is the production text. The full `DiskTab`/`NetworkTab` remain compiled in\n"
    "// `MonitorPanelSections.swift` and are used by `MonitorPanel`.\n\n"
    "import AppKit\n"
    "import Charts\n"
    "import Metrics\n"
    "import Storage\n"
    "import SwiftUI\n\n"
)
render_file = render_header + disk_render + "\n" + network_render + "\n" + boundary
render_path.write_text(render_file)

print(f"MonitorPanel.swift sha256: {hashlib.sha256(source.encode()).hexdigest()}")
print(f"MonitorPanelSections.swift sha256: {hashlib.sha256(sections.encode()).hexdigest()}")
print(f"MonitorPanelRenderSections.swift sha256: {hashlib.sha256(render_file.encode()).hexdigest()}")
print(f"panel remainder sha256: {hashlib.sha256(panel.encode()).hexdigest()}")
for name, original in blocks.items():
    start, end = ranges[name]
    print(f"extracted {name}: lines {start + 1}-{end + 1}, {len(original.splitlines())} lines, byte-identical except visibility")
print("--- DiskTabRender differences ---")
print(unified(disk_tab, disk_render, "DiskTab"))
print("--- NetworkTabRender differences ---")
print(unified(network_tab, network_render, "NetworkTab"))
PY

# The production views use the app's shared visual language. These stand-ins keep the surface
# (and therefore the production view bodies) unchanged while replacing ThemeStore, user
# preferences, hardware samplers and app-shell services. The chart's accent is deliberately a
# strong red so the pixel checks count the real marks instead of theme colors.
cat > "$work/package/Sources/MonitorPanelFeature/TestSupport.swift" <<'EOF'
import AppKit
import Metrics
import Observation
import SMCKit
import Storage
import SwiftUI

// MARK: - Design system stand-ins

enum Theme {
    static let blue = Color(red: 0.05, green: 0.6, blue: 0.1)
    static let cyan = Color(red: 0.9, green: 0.05, blue: 0.05)
    static let mint = Color.green
    static let amber = Color.orange
    static let rose = Color(red: 0.1, green: 0.2, blue: 0.9)
    static let violet = Color.purple
    static let orange = Color.orange
    static let slate = Color.gray
    static let accent = Color(red: 0.5, green: 0.0, blue: 0.5)
    static var smallNumeral: Font { .display(13).monospacedDigit() }
    static var label: Font { .mh(size: 11, weight: .medium) }
    static var heading: Font { .display(15) }
    static var numeral: Font { .display(24).monospacedDigit() }
    static var mediumNumeral: Font { .display(19).monospacedDigit() }
}

enum Palette {
    static let base = Color.white
    static let card = Color.white
    static let inset = Color(white: 0.94)
    static let raised = Color(white: 0.98)
    static let stroke = Color(white: 0.8)
    static let hairline = Color(white: 0.85)
    static let text = Color.black
    static let textMuted = Color(white: 0.35)
    static let textFaint = Color(white: 0.55)
}

struct SurfaceShape: InsettableShape {
    var cornerRadius: CGFloat
    var capsule = false
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.cornerRadius = cornerRadius
    }

    init(capsule: Bool) {
        cornerRadius = 0
        self.capsule = capsule
    }

    static var capsule: SurfaceShape { SurfaceShape(capsule: true) }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        if capsule { return Capsule(style: .continuous).path(in: r) }
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> SurfaceShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

extension Font {
    static func mh(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static var mhCaption: Font { .system(size: 11) }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.mh(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: SurfaceShape.capsule)
            .foregroundStyle(color)
    }
}

struct HairlineHeader: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text).font(.mh(size: 11, weight: .semibold)).foregroundStyle(Palette.textMuted)
    }
}

struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }.help(help)
    }
}

struct PixelIcon: View {
    let name: String
    var size: CGFloat = 16
    var label: LocalizedStringKey? = nil

    var body: some View {
        Color.clear.frame(width: size, height: size)
    }
}

struct TabStrip<Value: Hashable>: View {
    let items: [(Value, LocalizedStringKey)]
    var icons: [Value: String] = [:]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.1).onTapGesture { selection = item.0 }
            }
        }
    }
}

enum AppSection: String, CaseIterable, Hashable {
    case optimize, fans, disk, uninstall, startup

    var icon: String { "px.\(rawValue)" }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()
    var logoImage = NSImage(size: NSSize(width: 22, height: 22))
    var isSimple = false
}

enum HelperStatus {
    case enabled
    case disabled
}

final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()
    var status: HelperStatus = .enabled
}

struct UpdateAvailableButton: View {
    var compact = false

    var body: some View { EmptyView() }
}

enum Host {}

enum StatusLevel {
    case good, attention, critical

    var color: Color {
        switch self {
        case .good: Palette.text
        case .attention: Theme.amber
        case .critical: Theme.rose
        }
    }
}

struct Reading {
    let level: StatusLevel
}

enum StatusRules {
    static func temperature(_ celsius: Double?) -> Reading? {
        celsius.map { _ in Reading(level: .good) }
    }
}

struct RingGauge: View {
    let fraction: Double
    let value: String
    let caption: LocalizedStringKey
    var color: Color = Theme.accent
    var size: CGFloat = 84
    var lineWidth: CGFloat = 10

    var body: some View {
        VStack {
            Text(value).font(.display(size * 0.22, weight: .bold))
            Text(caption)
        }
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String
    var dot: Color?
    var valueColor: Color = Palette.text

    var body: some View {
        HStack {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label)
            Spacer()
            Text(value).foregroundStyle(valueColor)
        }
    }
}

struct CoreBars: View, Equatable {
    let values: [Double]
    var kinds: [Bool] = []
    var performance: Color = Theme.blue
    var efficiency: Color = Theme.cyan

    var body: some View { Color.clear }
}

struct PressureGauge: View {
    let level: Double
    let label: String
    var size: CGFloat = 76

    var body: some View { Text(label) }
}

struct SegmentedRing: View {
    let segments: [(Double, Color)]
    let value: String
    var size: CGFloat = 100
    var lineWidth: CGFloat = 12

    var body: some View { Text(value) }
}

struct StackedBar: View {
    let parts: [(Double, Color)]
    var height: CGFloat = 14

    var body: some View { Color.clear.frame(height: height) }
}

struct MirroredHistory: View, Equatable {
    let up: [Double]
    let down: [Double]
    var upColor: Color = Theme.blue
    var downColor: Color = Theme.rose

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let peak = max((up + down).max() ?? 1, 1)
            func draw(_ values: [Double], _ color: Color, above: Bool) {
                guard values.count > 1 else { return }
                let step = size.width / CGFloat(values.count - 1)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: mid))
                for (i, value) in values.enumerated() {
                    let height = mid * CGFloat(value / peak) * 0.95
                    path.addLine(to: CGPoint(x: CGFloat(i) * step, y: above ? mid - height : mid + height))
                }
                path.addLine(to: CGPoint(x: size.width, y: mid))
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            draw(up, upColor, above: true)
            draw(down, downColor, above: false)
        }
    }
}

struct HistoryArea: View, Equatable {
    let values: [Double]
    var maxValue: Double? = 1
    var color: Color = Theme.blue

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let peak = max(maxValue ?? 1, values.max() ?? 1, 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in values.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(i) * step,
                                         y: size.height - size.height * CGFloat(min(max(value / peak, 0), 1))))
            }
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
    }
}

struct SkeletonRows: View {
    var count = 5

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { _ in
                SurfaceShape(cornerRadius: 3).frame(height: 9).foregroundStyle(Palette.inset)
            }
        }
    }
}

extension View {
    func settingsCaption(_ color: Color = Palette.textMuted) -> some View {
        font(.mh(size: 11)).foregroundStyle(color)
    }
}

@MainActor
enum ProcessIcon {
    static func icon(for p: ProcessUsage) -> NSImage { blankIcon }
    static func icon(for p: GPUProcessUsage) -> NSImage { blankIcon }

    private static var blankIcon: NSImage { NSImage(size: NSSize(width: 18, height: 18)) }
}

// MARK: - Store stand-in

struct ChartPoint: Hashable, Sendable {
    let date: Date
    let value: Double
}

enum SeriesKey: String, CaseIterable, Sendable {
    case cpu, cpuP, cpuE, gpu, memory, diskRead, diskWrite, netIn, netOut, battery, temperature, fan, power
}

struct LiveHistory {
    var series: [SeriesKey: [ChartPoint]] = [:]

    subscript(key: SeriesKey) -> [ChartPoint]? {
        series[key]
    }
}

/// The real store owns the hardware samplers, the shared database and the background recording
/// loops. This stand-in exposes only the state the menu panel reads. The tests fill it with
/// synthetic readings and an in-memory history database.
@MainActor
@Observable
final class MonitorStore {
    var cpu: CPUReading?
    var gpu: GPUReading?
    var memory: MemoryReading?
    var disk: DiskReading?
    var network: NetworkReading?
    var temperatures: [TemperatureReading] = []
    var fans: [FanReading] = []
    var power: PowerReading?
    var processes: ProcessSnapshot?
    var gpuProcesses: [GPUProcessUsage]?
    var history = LiveHistory()
    var persistentHistory: MetricsHistory?

    private(set) var watchCalls: [Bool] = []

    init() {}

    var cpuCelsius: Double? {
        MonitorHistorySample.cpuCelsius(temperatures)
    }

    func watchProcesses(_ on: Bool) {
        watchCalls.append(on)
    }
}
EOF

cat > "$work/package/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonitorPanelIsolatedTests",
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
            name: "MonitorPanelIntegrationTests",
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
    xcrun xcstringstool compile "$work/package/Tests/MonitorPanelIntegrationTests/Resources/$catalog.xcstrings" \
        --output-directory "$work/package/Tests/MonitorPanelIntegrationTests/Resources/Localizations"
done

# Keep the isolation property explicit: a remote package would make resolution able to reach the
# network even though the flags below would try to stop it.
if grep -q '\.package(url:' "$work/package/Package.swift"; then
    echo "error: the isolated test manifest must not contain remote package dependencies" >&2
    exit 1
fi

echo "--- source manifest (sha256) ---"
for file in \
    "$root/App/Monitor/MonitorPanel.swift" \
    "$root/App/Monitor/DiskCapacitySelectionModel.swift" \
    "$root/App/Monitor/DiskCapacityHistoryChart.swift" \
    "$root/App/Monitor/NetworkDetailsSection.swift" \
    "$root/App/Monitor/NetworkDetailsContent.swift" \
    "$root/App/Monitor/HistoryManagementSection.swift" \
    "$root/App/Monitor/Formatting.swift" \
    "$volume_history" \
    "$history_segments"; do
    printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "$file"
done
echo "--- end manifest ---"

swift test --package-path "$work/package" \
    --disable-automatic-resolution \
    --filter 'MonitorPanelIntegrationTests'
