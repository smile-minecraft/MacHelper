#!/bin/bash
#
# Renders the production sensor-history chart with SwiftUI's ImageRenderer and checks the
# pixels. The checks are `SeriesHistoryChartVisibilityTests` in the MacHelperTests bundle
# (Tests/AppTests), which `make test` runs with the rest; this runs only that suite. The app it
# is hosted in stays inert: it opens no window or database and leaves the preferences alone.
#
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
# shellcheck source=../../scripts/lib/env.sh
. scripts/lib/env.sh
# shellcheck source=../../scripts/lib/app-tests.sh
. scripts/lib/app-tests.sh

scripts/sparkle/fetch.sh >/dev/null
xcodegen generate --quiet
xcodebuild test "${APP_TEST_FLAGS[@]}" -quiet \
    -only-testing:MacHelperTests/SeriesHistoryChartVisibilityTests
