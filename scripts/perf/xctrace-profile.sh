#!/bin/bash
# Profile MacHelper with Apple's xctrace. No third-party tools are needed.
#
# Examples:
#   scripts/perf/xctrace-profile.sh --template time-profiler --duration 20
#   scripts/perf/xctrace-profile.sh --template points-of-interest --duration 10
#   scripts/perf/xctrace-profile.sh --template allocations --attach 12345
#
# The signposts added under Sources/Telemetry/PerfSignpost.swift show up in the
# "Points of Interest" template as the sampling, storage, diskScan and ui categories.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="time-profiler"
APP="$ROOT/build/Build/Products/Debug/MacHelper.app"
DURATION=15
OUTPUT_DIR="$ROOT/build/perf/traces"
ATTACH=""
ALLOW_PRODUCTION=0

usage() {
    cat <<'EOF'
Usage: xctrace-profile.sh [options]

Options:
  --template NAME       time-profiler (default), allocations, or points-of-interest
  --app PATH            Debug .app to launch (default: build/Build/Products/Debug/MacHelper.app)
  --duration SECONDS    Recording limit in seconds (default: 15)
  --output-dir DIR      Where .trace bundles are written (default: build/perf/traces)
  --attach PID          Profile an existing process instead of launching the Debug app
  --allow-production    Permit --attach to a process inside /Applications or the root Helper
  -h, --help            Show this help

Safety:
  * Launch mode refuses to start a second copy while any MacHelper is already running, because
    two instances share the same settings and history database.
  * Attach mode refuses to target the installed /Applications app or the privileged Helper
    unless --allow-production is passed explicitly.
  * Nothing here installs, signs, replaces or updates an app. Traces stay in build/perf/traces/.

The script needs Xcode's command line tools (xcrun xctrace) and no other dependencies.
EOF
}

die() { printf 'xctrace-profile: %s\n' "$*" >&2; exit "${2:-64}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --template)       [[ $# -ge 2 ]] || die "--template needs a value"; TEMPLATE="$2"; shift 2 ;;
        --app)            [[ $# -ge 2 ]] || die "--app needs a value"; APP="$2"; shift 2 ;;
        --duration)       [[ $# -ge 2 ]] || die "--duration needs a value"; DURATION="$2"; shift 2 ;;
        --output-dir)     [[ $# -ge 2 ]] || die "--output-dir needs a value"; OUTPUT_DIR="$2"; shift 2 ;;
        --attach)         [[ $# -ge 2 ]] || die "--attach needs a value"; ATTACH="$2"; shift 2 ;;
        --allow-production) ALLOW_PRODUCTION=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown option: $1" ;;
    esac
done

case "$TEMPLATE" in
    time-profiler)       XC_TEMPLATE="Time Profiler" ;;
    allocations)         XC_TEMPLATE="Allocations" ;;
    points-of-interest)  XC_TEMPLATE="Points of Interest" ;;
    *) die "unknown template '$TEMPLATE' (use time-profiler, allocations or points-of-interest)" ;;
esac
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || die "--duration must be a positive whole number of seconds"
[[ "$ATTACH" == "" || "$ATTACH" =~ ^[0-9]+$ ]] || die "--attach must be a process id"

command -v xcrun >/dev/null 2>&1 || die "xcrun not found. Install Xcode and run sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" 69
xcrun xctrace version >/dev/null 2>&1 || die "xcrun xctrace is unavailable; install Xcode's command line tools" 69

if [[ -n "$ATTACH" ]]; then
    command_name="$(ps -p "$ATTACH" -o comm= 2>/dev/null || true)"
    [[ -n "$command_name" ]] || die "no process with pid $ATTACH" 66
    if [[ "$ALLOW_PRODUCTION" -ne 1 ]] && [[ "$command_name" == *"/Applications/MacHelper.app/"* \
        || "$command_name" == *"com.machelper.MacHelper.Helper"* \
        || "$command_name" == *"MacHelperHelper"* ]]; then
        die "refusing to attach to the production app or root Helper ($command_name); pass --allow-production only if you know what you are doing" 77
    fi
else
    if pgrep -x MacHelper >/dev/null 2>&1; then
        die "a MacHelper process is already running; quit it first or use --attach <pid>" 77
    fi
    if [[ "$ALLOW_PRODUCTION" -ne 1 ]] && pgrep -f "com.machelper.MacHelper.Helper" >/dev/null 2>&1; then
        die "the privileged Helper is running; pass --allow-production to profile this setup" 77
    fi
    [[ -d "$APP" ]] || die "Debug app not found at $APP; run 'make build' first" 66
fi

mkdir -p "$OUTPUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
TRACE="$OUTPUT_DIR/${TEMPLATE}-${STAMP}.trace"

printf 'Template: %s\n' "$XC_TEMPLATE"
printf 'Output:   %s\n' "$TRACE"
if [[ -n "$ATTACH" ]]; then
    xcrun xctrace record --template "$XC_TEMPLATE" --output "$TRACE" \
        --time-limit "${DURATION}s" --attach "$ATTACH"
else
    xcrun xctrace record --template "$XC_TEMPLATE" --output "$TRACE" \
        --time-limit "${DURATION}s" --launch -- "$APP/Contents/MacOS/MacHelper"
fi

# Export both a table-of-contents summary and the full trace data for later inspection.
TOC="$OUTPUT_DIR/${TEMPLATE}-${STAMP}-toc.xml"
xcrun xctrace export --input "$TRACE" --toc > "$TOC"
EXPORT_DIR="$OUTPUT_DIR/${TEMPLATE}-${STAMP}-export"
xcrun xctrace export --input "$TRACE" --output "$EXPORT_DIR"

printf '\nSummary (from xctrace export --toc):\n'
grep -E '<(run|table|process)[^>]*>' "$TOC" | head -25 || true
printf '\nFull export: %s\n' "$EXPORT_DIR"
