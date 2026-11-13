#!/bin/bash
#
# Shared parser for the app's MHPROBE timing lines. Source this file; do not run it.
#
# The app writes, for example:
#   2026-11-12 01:18:25.504 MacHelper[38335:7720576] MHPROBE 816110305.504 main-busy 125.3 ms
#
# The old smoke used `/MHPROBE main-busy/`, which never matched the timestamp between
# "MHPROBE" and the event, so 38 real stretches (max 868 ms) were reported as 0 ms.
# This parser matches the real format, returns "0 0.0" only when the log really has no
# main-busy line, and fails when a line has the token but not a numeric value.

# Prints "<count> <max_ms>" on stdout. Returns 2 when the probe did not run or a line
# cannot be parsed, so a parse failure is never mistaken for "no stretch over 100 ms".
monitor_probe_busy_summary() {
    local log="$1"
    if [ ! -f "$log" ]; then
        echo "probe log not found: $log" >&2
        return 2
    fi
    if ! grep -qE 'MHPROBE [0-9.]+ probe-start' "$log"; then
        echo "probe-start line missing; the monitor probe did not run" >&2
        return 2
    fi

    local token_lines summary token parsed max
    token_lines=$(grep -c 'main-busy' "$log" 2>/dev/null || true)
    token_lines=${token_lines:-0}
    summary=$(awk '
        function numeric(s) { return s ~ /^[0-9]+(\.[0-9]+)?$/ }
        /MHPROBE [0-9.]+ main-busy/ {
            token++
            for (i = 1; i <= NF; i++) {
                if ($i == "main-busy") {
                    if (i + 1 <= NF) {
                        v = $(i + 1)
                        sub(/ms$/, "", v)
                        if (numeric(v)) { parsed++; if (v + 0 > max) max = v + 0 }
                    }
                    break
                }
            }
        }
        END { printf "%d %d %.1f\n", token + 0, parsed + 0, max + 0 }
    ' "$log")
    token=${summary%% *}
    summary=${summary#* }
    parsed=${summary%% *}
    max=${summary#* }

    if [ "$token_lines" -ne "$token" ]; then
        echo "main-busy parse failure: $token_lines line(s) contain the token, $token match the MHPROBE <timestamp> main-busy format" >&2
        return 2
    fi
    if [ "$token" -ne "$parsed" ]; then
        echo "main-busy parse failure: $token line(s) match the prefix, only $parsed have a numeric value" >&2
        return 2
    fi
    printf '%d %s\n' "$parsed" "$max"
}

# Prints a one-line summary and fails when the longest stretch exceeds the ceiling.
# "0 0.0" is a pass: the probe only logs stretches of 100 ms or more.
monitor_probe_busy_check() {
    local log="$1" ceiling="$2"
    local summary count max
    if ! summary=$(monitor_probe_busy_summary "$log"); then
        return 2
    fi
    count=${summary%% *}
    max=${summary#* }
    if [ "$count" -eq 0 ]; then
        echo "no main-thread stretch reached 100 ms"
        return 0
    fi
    echo "main-thread stretches: $count, longest ${max} ms"
    if ! awk -v max="$max" -v ceiling="$ceiling" 'BEGIN { exit !(max <= ceiling) }'; then
        echo "main thread stalled for ${max} ms; ceiling is ${ceiling} ms" >&2
        return 1
    fi
}
