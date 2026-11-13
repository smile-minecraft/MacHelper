#!/bin/bash
#
# Rerunnable tests for the MHPROBE parser used by the native UI smoke and the release
# measurement. Each fixture is a real-shaped app log, not a copy of the parser.
#
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=MonitorProbeLog.sh
source "$ROOT/Tests/UI/MonitorProbeLog.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/machelper-probe-parse.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. A real 125 ms line must parse as one event, and a 100 ms ceiling must fail.
cat >"$TMP/real.log" <<'LOG'
2026-11-12 01:18:25.504 MacHelper[38335:7720576] MHPROBE 816110305.504 probe-start 
2026-11-12 01:18:25.504 MacHelper[38335:7720576] MHPROBE 816110305.504 main-busy 125.0 ms
LOG
summary=$(monitor_probe_busy_summary "$TMP/real.log")
[ "$summary" = "1 125.0" ] || fail "125 ms line parsed as '$summary'"
if monitor_probe_busy_check "$TMP/real.log" 100 >/dev/null 2>&1; then
    fail "a 125 ms stretch passed a 100 ms ceiling"
fi
echo "PASS: real 125 ms line parses and fails a 100 ms ceiling"

# 2. No main-busy line is a real "none", not a parse error.
cat >"$TMP/none.log" <<'LOG'
2026-11-12 01:18:25.504 MacHelper[38335:7720576] MHPROBE 816110305.504 probe-start 
2026-11-12 01:18:26.504 MacHelper[38335:7720576] MHPROBE 816110306.504 content range=live chart=live samples=4
LOG
summary=$(monitor_probe_busy_summary "$TMP/none.log")
[ "$summary" = "0 0.0" ] || fail "no-event log parsed as '$summary'"
monitor_probe_busy_check "$TMP/none.log" 100 >/dev/null || fail "no-event log failed the check"
echo "PASS: a log without main-busy lines is reported as no stretch"

# 3. The format the old awk assumed must be a parse failure, not zero.
cat >"$TMP/old-format.log" <<'LOG'
2026-11-12 01:18:25.504 MacHelper[38335:7720576] MHPROBE 816110305.504 probe-start 
2026-11-12 01:18:26.504 MacHelper[38335:7720576] MHPROBE main-busy 868.0 ms
LOG
if monitor_probe_busy_summary "$TMP/old-format.log" >/dev/null 2>&1; then
    fail "the old MHPROBE main-busy format was accepted"
fi
echo "PASS: the old assumed format is a parse failure"

# 4. A token without a numeric value must fail, not count as zero.
cat >"$TMP/malformed.log" <<'LOG'
2026-11-12 01:18:25.504 MacHelper[38335:7720576] MHPROBE 816110305.504 probe-start 
2026-11-12 01:18:26.504 MacHelper[38335:7720576] MHPROBE 816110306.504 main-busy unknown ms
LOG
if monitor_probe_busy_summary "$TMP/malformed.log" >/dev/null 2>&1; then
    fail "a main-busy line without a number was accepted"
fi
echo "PASS: a malformed main-busy line is a parse failure"

# 5. Several events keep the maximum; an over-ceiling event fails.
cat >"$TMP/many.log" <<'LOG'
2026-11-12 01:18:25.504 MacHelper[38335:7720576] MHPROBE 816110305.504 probe-start 
2026-11-12 01:18:26.504 MacHelper[38335:7720576] MHPROBE 816110306.504 main-busy 112.1 ms
2026-11-12 01:18:27.504 MacHelper[38335:7720576] MHPROBE 816110307.504 main-busy 868.0 ms
2026-11-12 01:18:28.504 MacHelper[38335:7720576] MHPROBE 816110308.504 main-busy 106.4 ms
LOG
summary=$(monitor_probe_busy_summary "$TMP/many.log")
[ "$summary" = "3 868.0" ] || fail "three events parsed as '$summary'"
if monitor_probe_busy_check "$TMP/many.log" 500 >/dev/null 2>&1; then
    fail "an 868 ms stretch passed a 500 ms ceiling"
fi
echo "PASS: the parser keeps the maximum and fails an over-ceiling event"

# 6. A log from a run where the probe never started cannot be read as "none".
cat >"$TMP/no-probe.log" <<'LOG'
2026-11-12 01:18:25.504 MacHelper[38335:7720576] MHPROBE 816110305.504 main-busy 125.0 ms
LOG
if monitor_probe_busy_summary "$TMP/no-probe.log" >/dev/null 2>&1; then
    fail "a log without probe-start was accepted"
fi
echo "PASS: a missing probe-start is a parse failure"

echo "Monitor probe parser tests passed."
