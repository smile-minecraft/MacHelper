#!/bin/bash
#
# UNSAFE RELEASE MEASUREMENT — REFUSED BY DEFAULT.
#
# This wrapper would build and launch a MacHelper copy, so it reaches the same fixed helper
# mach service, fan switcher, heartbeat and process counters as MonitorRangeSwitchSmoke.sh.
# A unique bundle id, an empty CFFIXED_USER_HOME and a seeded CDHash do not isolate those
# XPC calls. The earlier Release numbers came from manual runs before this limitation was
# established; they are observations, not a safe re-runnable test.
#
# Do not add a bypass switch. Use the parser, chart-renderer and Storage tests until a
# proven no-helper launch mode or fake XPC host exists.
#
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

cat >&2 <<'MSG'
REFUSED: Tests/UI/MonitorReleaseMeasure.sh builds and launches a MacHelper copy whose
AppDelegate connects to the fixed helper mach service. Unique bundle ids and temporary
homes do not isolate helper, fan or process-counter XPC calls. The script stops before
building or launching anything. There is no bypass switch.
MSG
exit 78

if ! xcodebuild -version >/dev/null 2>&1; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-*.app; do
        [ -d "$candidate" ] || continue
        export DEVELOPER_DIR="$candidate/Contents/Developer"
        xcodebuild -version >/dev/null 2>&1 && break
    done
fi
xcodebuild -version >/dev/null 2>&1 \
    || { echo "FAIL: xcodebuild is unavailable; set DEVELOPER_DIR to an Xcode with the macOS SDK." >&2; exit 1; }

DERIVED="$ROOT/build/ReleaseMeasureDerived"
echo "• Building MacHelper (Release, ad-hoc local copy)…"
xcodebuild -project MacHelper.xcodeproj -scheme MacHelper -configuration Release \
    -derivedDataPath "$DERIVED" ENABLE_HARDENED_RUNTIME=NO -quiet build \
    || { echo "FAIL: Release build failed." >&2; exit 1; }

MACHELPER_UI_SMOKE_SKIP_BUILD=1 \
MACHELPER_UI_SMOKE_CONFIGURATION=Release \
MACHELPER_UI_SMOKE_APP="$DERIVED/Build/Products/Release/MacHelper.app" \
    "$ROOT/Tests/UI/MonitorRangeSwitchSmoke.sh"
