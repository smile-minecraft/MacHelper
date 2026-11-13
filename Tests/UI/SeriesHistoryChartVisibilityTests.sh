#!/bin/bash
#
# Renders the production sensor-history chart with SwiftUI's ImageRenderer and checks the
# pixels. The chart content is compiled from App/Monitor/SeriesHistoryView.swift with
# -D MACHELPER_CHART_TEST; the test does not copy the chart code. Only Storage's
# Foundation-only source files are compiled in, so this never opens a database or an app.
#
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-*.app; do
        [ -d "$candidate" ] || continue
        export DEVELOPER_DIR="$candidate/Contents/Developer"
        xcrun --find swiftc >/dev/null 2>&1 && break
    done
fi
xcrun --find swiftc >/dev/null 2>&1 \
    || { echo "FAIL: swiftc is unavailable; set DEVELOPER_DIR to an Xcode with the macOS SDK." >&2; exit 1; }

OUT=$(mktemp -d "${TMPDIR:-/tmp}/machelper-chart-visibility.XXXXXX")
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc -parse-as-library -D MACHELPER_CHART_TEST \
    "$ROOT/Sources/Storage/FinishedMinute.swift" \
    "$ROOT/Sources/Storage/SeriesHistory.swift" \
    "$ROOT/Sources/Storage/HistorySegments.swift" \
    "$ROOT/App/Monitor/SeriesHistoryView.swift" \
    "$ROOT/Tests/UI/SeriesHistoryChartVisibilityTests.swift" \
    -framework SwiftUI -framework Charts -framework AppKit \
    -o "$OUT/chart-visibility"
"$OUT/chart-visibility"
