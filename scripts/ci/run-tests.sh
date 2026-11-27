#!/bin/bash
# Runs every unit test: the Swift packages (`swift test`), then the app's MacHelperTests bundle
# (`xcodebuild test`), which is hosted in MacHelper.app. `make test` and CI both call this.
#
# Around the run it checks that the person's preferences stayed untouched: the
# `com.machelper.MacHelper` domain must export the same before and after, and the throwaway
# domain the test host uses must be gone. When a MacHelper that is not one of this checkout's
# test builds is running, that app writes its own settings, so the comparison is skipped with a
# warning (CI always compares).
#
# On GitHub Actions a failed test is rerun once, alone. A test that passes on the rerun is
# reported as flaky (a warning; the run still succeeds); one that fails again fails the run.
# Every failed or flaky test is listed in the job summary. Locally nothing is rerun.
#
# Environment:
#   MACHELPER_TEST_DERIVED_DATA  where xcodebuild builds (default: build/, or a folder on the
#                                startup disk when the checkout is on another volume; see
#                                scripts/lib/app-tests.sh)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../lib/env.sh
. scripts/lib/env.sh

ON_CI=false
[ "${GITHUB_ACTIONS:-}" = "true" ] && ON_CI=true

DOMAIN="com.machelper.MacHelper"
TEST_DOMAIN_PLIST="$HOME/Library/Preferences/com.machelper.MacHelper.unit-tests.plist"
RESULTS="build/TestResults"
APP_RESULT="$RESULTS/app.xcresult"
APP_RERUN_RESULT="$RESULTS/app-rerun.xcresult"
PARSER="scripts/ci/test_failures.py"

# shellcheck source=../lib/app-tests.sh
. scripts/lib/app-tests.sh
DERIVED="$APP_TEST_DERIVED_DATA"
[ "$DERIVED" = "build" ] || echo "note: the checkout is not on the startup disk; the app tests build in $DERIVED"

mkdir -p "$RESULTS"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/machelper-tests.XXXXXX")"
trap 'rm -rf "$LOGS"' EXIT

failed=0
flaky_rows=()
failed_rows=()
error_lines=()

# MARK: - Preferences guard

export_domain() {
    defaults export "$DOMAIN" - 2>/dev/null || true
}

# A MacHelper process that is not one of this checkout's builds is the person's own app.
foreign_app_running() {
    local pid path
    for pid in $(pgrep -x MacHelper 2>/dev/null); do
        path="$(ps -o comm= -p "$pid" 2>/dev/null)"
        [ -n "$path" ] || continue
        case "$path" in
            "$ROOT"/build/*|"$DERIVED"/*|build/*|./build/*) ;;
            *) return 0 ;;
        esac
    done
    return 1
}

compare_defaults=true
if ! $ON_CI && foreign_app_running; then
    echo "warning: 使用者的 App 正在執行，它會自行寫入設定，跳過比對 (MacHelper is running and writes its own settings; skipping the $DOMAIN comparison)"
    compare_defaults=false
fi
defaults_before="$(export_domain)"

# MARK: - Reporting

summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
    return 0
}

# Escapes a value for a workflow command (`::error ...::message`).
escape_data() {
    local text="$1"
    text="${text//'%'/'%25'}"
    text="${text//$'\r'/'%0D'}"
    text="${text//$'\n'/'%0A'}"
    printf '%s' "$text"
}

escape_property() {
    local text
    text="$(escape_data "$1")"
    text="${text//:/%3A}"
    text="${text//,/%2C}"
    printf '%s' "$text"
}

markdown_cell() {
    local text="${1//|/\\|}"
    printf '%s' "${text:0:300}"
}

location_of() {
    local file="$1" line="$2"
    if [ -n "$file" ] && [ -n "$line" ]; then printf '%s:%s' "$file" "$line"
    elif [ -n "$file" ]; then printf '%s' "$file"
    else printf '—'; fi
}

report_flaky() {
    local name="$1" file="$2" line="$3"
    echo "::warning title=Flaky test::$(escape_data "$name")"
    flaky_rows+=("| \`$(markdown_cell "$name")\` | $(markdown_cell "$(location_of "$file" "$line")") | flaky |")
}

report_failed() {
    local name="$1" file="$2" line="$3" message="$4"
    local props=""
    if [ -n "$file" ]; then
        props=" file=$(escape_property "$file")"
        [ -n "$line" ] && props="$props,line=$line"
    fi
    echo "::error${props}::$(escape_data "$name: $message")"
    failed_rows+=("| \`$(markdown_cell "$name")\` | $(markdown_cell "$(location_of "$file" "$line")") | failed: $(markdown_cell "$message") |")
}

report_unattributed() {
    local phase="$1" log="$2" line
    echo "::error title=$(escape_property "$phase")::$(escape_data "$phase failed before every failure could be tied to a test; nothing was rerun.")"
    error_lines+=("**$phase** failed before every failure could be tied to a test; nothing was rerun.")
    error_lines+=('```')
    while IFS= read -r line; do
        error_lines+=("$line")
    done < <(python3 "$PARSER" summary-errors "$log")
    error_lines+=('```')
}

# Reports every first-run failure as flaky or failed after its single rerun. Arguments: the
# first-run failures and the rerun failures (parser output; the second may be empty), the tests the
# rerun showed passing (one per line), and which column of the failure list names a test in that
# list (1: the filter, for app tests; 2: the display name, for package tests).
#
# A test is flaky only when the rerun shows it passing and does not list it as failed again. The
# rerun's exit status proves nothing: a filter that matches no test (a failure inside a helper
# function, a test with a display name) runs nothing and still exits 0.
classify() {
    local first="$1" again="$2" passed="$3" column="$4"
    local filter name file line message key
    while IFS=$'\t' read -r filter name file line message; do
        [ -n "$filter" ] || continue
        if [ "$column" -eq 1 ]; then key="$filter"; else key="$name"; fi
        if grep -qxF -- "$key" "$passed" && ! cut -f1 "$again" | grep -qxF -- "$filter"; then
            report_flaky "$name" "$file" "$line"
        else
            report_failed "$name" "$file" "$line" "$message"
        fi
    done < "$first"
}

report_local_failures() {
    local list="$1" filter name file line message
    [ -s "$list" ] || return 0
    echo "Failed tests:"
    while IFS=$'\t' read -r filter name file line message; do
        echo "  ✘ $name  $(location_of "$file" "$line")  $message"
    done < "$list"
}

# MARK: - Swift packages

echo "==> swift test"
swift_log="$LOGS/swift-test.log"
swift test 2>&1 | tee "$swift_log"
swift_status=${PIPESTATUS[0]}

if [ "$swift_status" -ne 0 ]; then
    swift_failures="$LOGS/swift-failures.tsv"
    python3 "$PARSER" swift-log "$swift_log" > "$swift_failures"
    parse_status=$?
    if ! $ON_CI; then
        report_local_failures "$swift_failures"
        failed=1
    elif [ "$parse_status" -ne 0 ]; then
        report_unattributed "swift test" "$swift_log"
        failed=1
    else
        pattern="$(cut -f1 "$swift_failures" | paste -sd'|' -)"
        echo "==> swift test: rerunning $(wc -l < "$swift_failures" | tr -d ' ') failed test(s) once"
        rerun_log="$LOGS/swift-rerun.log"
        swift test --filter "$pattern" 2>&1 | tee "$rerun_log"
        rerun_status=${PIPESTATUS[0]}
        rerun_failures="$LOGS/swift-rerun-failures.tsv"
        : > "$rerun_failures"
        if [ "$rerun_status" -ne 0 ]; then
            python3 "$PARSER" swift-log "$rerun_log" > "$rerun_failures" || true
        fi
        rerun_passed="$LOGS/swift-rerun-passed.txt"
        python3 "$PARSER" swift-passed "$rerun_log" > "$rerun_passed" || : > "$rerun_passed"
        before=${#failed_rows[@]}
        classify "$swift_failures" "$rerun_failures" "$rerun_passed" 2
        [ "${#failed_rows[@]}" -gt "$before" ] && failed=1
    fi
fi

# MARK: - App tests

echo "==> xcodebuild test (MacHelperTests)"
# The test bundle and any new test file reach the project only through a regenerated project.
scripts/sparkle/fetch.sh >/dev/null || { echo "error: could not fetch Sparkle" >&2; exit 1; }
xcodegen generate --quiet || { echo "error: xcodegen failed" >&2; exit 1; }

xcode_flags=("${APP_TEST_FLAGS[@]}")
rm -rf "$APP_RESULT" "$APP_RERUN_RESULT"
app_log="$LOGS/xcodebuild-test.log"
xcodebuild test "${xcode_flags[@]}" -resultBundlePath "$APP_RESULT" 2>&1 | tee "$app_log"
app_status=${PIPESTATUS[0]}

if [ "$app_status" -ne 0 ]; then
    app_failures="$LOGS/app-failures.tsv"
    python3 "$PARSER" xcresult "$APP_RESULT" > "$app_failures"
    parse_status=$?
    if ! $ON_CI; then
        report_local_failures "$app_failures"
        failed=1
    elif [ "$parse_status" -ne 0 ]; then
        report_unattributed "xcodebuild test" "$app_log"
        failed=1
    else
        only=()
        while IFS=$'\t' read -r filter _; do
            [ -n "$filter" ] && only+=("-only-testing:$filter")
        done < "$app_failures"
        echo "==> xcodebuild test: rerunning ${#only[@]} failed test(s) once"
        xcodebuild test-without-building "${xcode_flags[@]}" -resultBundlePath "$APP_RERUN_RESULT" \
            "${only[@]}" 2>&1 | tee "$LOGS/xcodebuild-rerun.log"
        rerun_status=${PIPESTATUS[0]}
        rerun_failures="$LOGS/app-rerun-failures.tsv"
        : > "$rerun_failures"
        if [ "$rerun_status" -ne 0 ]; then
            python3 "$PARSER" xcresult "$APP_RERUN_RESULT" > "$rerun_failures" || true
        fi
        rerun_passed="$LOGS/app-rerun-passed.txt"
        python3 "$PARSER" xcresult-passed "$APP_RERUN_RESULT" > "$rerun_passed" || : > "$rerun_passed"
        before=${#failed_rows[@]}
        classify "$app_failures" "$rerun_failures" "$rerun_passed" 1
        [ "${#failed_rows[@]}" -gt "$before" ] && failed=1
    fi
fi

# MARK: - Preferences guard

defaults_after="$(export_domain)"
if $compare_defaults && ! $ON_CI && foreign_app_running; then
    echo "warning: 使用者的 App 正在執行，它會自行寫入設定，跳過比對 (MacHelper started during the run; skipping the $DOMAIN comparison)"
    compare_defaults=false
fi
if $compare_defaults && [ "$defaults_before" != "$defaults_after" ]; then
    echo "error: the tests changed the $DOMAIN preferences:" >&2
    diff <(printf '%s\n' "$defaults_before") <(printf '%s\n' "$defaults_after") >&2
    echo "::error title=Preferences changed::The tests changed the $DOMAIN preferences."
    error_lines+=("**Preferences:** the tests changed the \`$DOMAIN\` domain.")
    failed=1
fi
if [ -e "$TEST_DOMAIN_PLIST" ]; then
    echo "error: the test host left $TEST_DOMAIN_PLIST behind" >&2
    echo "::error title=Preferences left behind::The test host left $(escape_data "$TEST_DOMAIN_PLIST") behind."
    error_lines+=("**Preferences:** the test host left \`$TEST_DOMAIN_PLIST\` behind.")
    failed=1
fi

# MARK: - Summary

if [ "${#flaky_rows[@]}" -gt 0 ] || [ "${#failed_rows[@]}" -gt 0 ] || [ "${#error_lines[@]}" -gt 0 ]; then
    summary "## Unit tests" ""
    if [ "${#flaky_rows[@]}" -gt 0 ] || [ "${#failed_rows[@]}" -gt 0 ]; then
        summary "| Test | Location | Result |" "| --- | --- | --- |"
        [ "${#failed_rows[@]}" -gt 0 ] && summary "${failed_rows[@]}"
        [ "${#flaky_rows[@]}" -gt 0 ] && summary "${flaky_rows[@]}"
        summary ""
    fi
    [ "${#error_lines[@]}" -gt 0 ] && summary "${error_lines[@]}"
fi

if [ "$failed" -ne 0 ]; then
    echo "Tests failed."
    exit 1
fi
if [ "${#flaky_rows[@]}" -gt 0 ]; then
    echo "Tests passed; ${#flaky_rows[@]} passed only on the rerun (flaky)."
else
    echo "All tests passed."
fi
