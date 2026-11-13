#!/bin/bash
#
# UNSAFE NATIVE PROCEDURE — REFUSED BY DEFAULT.
#
# This script is retained as a record of the manual native procedure used earlier. It is
# not a safe re-runnable test. The app copy's AppDelegate refreshes helper registration,
# starts the heartbeat, the fan switcher and process counters against the fixed mach
# service com.machelper.MacHelper.Helper. A unique bundle id, CFFIXED_USER_HOME and a
# seeded CDHash isolate files, defaults and registration only; they do not stop those XPC
# calls, fan control or network activity. The earlier "Helper running" screenshot is
# evidence of that connection, not proof of isolation.
#
# Safe rerunnable checks:
#   - Tests/UI/MonitorProbeLogTests.sh (parser only)
#   - Tests/UI/SeriesHistoryChartVisibilityTests.sh (Swift Charts ImageRenderer only)
#   - StorageTests filters, for example SeriesHistoryTests
#
# Do not add an environment switch to bypass this refusal. A future native test needs a
# proven no-helper launch mode or a fake XPC host first.
#
# The procedure below is kept for reference: it built the app, seeded seven days of
# history, drove the SwiftUI window through Accessibility with Open Computer Use, and read
# the app's own main-thread stretches over 100 ms and the series commit timeline.
#
# Requirements: Xcode with the macOS SDK, sqlite3, and the `open-computer-use` CLI.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

cat >&2 <<'MSG'
REFUSED: Tests/UI/MonitorRangeSwitchSmoke.sh launches a MacHelper copy whose AppDelegate
connects to the fixed helper mach service com.machelper.MacHelper.Helper, starts the fan
switcher, and asks for process counters. A unique bundle id, CFFIXED_USER_HOME and a
seeded helper CDHash do not isolate those XPC calls or network activity. The script stops
here, before building, writing defaults, seeding a database or launching anything. There
is no bypass switch. Use the parser, chart-renderer and Storage tests until a proven
no-helper host exists.
MSG
exit 78

# ---------------------------------------------------------------------------------------
# The following body is unreachable. It is the manual procedure that produced the earlier
# UI observations; it must not be run without a proven no-helper host.
# ---------------------------------------------------------------------------------------
# shellcheck source=MonitorProbeLog.sh
source "$ROOT/Tests/UI/MonitorProbeLog.sh"

"$ROOT/Tests/UI/MonitorProbeLogTests.sh" >/dev/null \
    || { echo "FAIL: the MHPROBE parser tests failed." >&2; exit 1; }

RUN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')
BUNDLE="com.machelper.monitorsmoke.$RUN_ID"
OUT="$ROOT/build/ui-smoke-monitor/$RUN_ID"
APP_PID=""
SMOKE=""
OWNS_DEFAULTS_DOMAIN=0
# The probe only records stretches of 100 ms or more. The default ceiling is set from the
# measured runs on this Mac (10 cores, load average 4.4–6.4 while other worktrees were
# building): Debug longest 263.4–532.6 ms, Release longest 378.9–496.4 ms, both in the
# rapid sequence; the week→live pass itself was 0–209.6 ms Debug and 0–111.5 ms Release.
# The ceilings keep 1.4–1.7× headroom over those numbers and are far below the pre-fix
# 35 s stall. Override them only with a measured reason.
CONFIGURATION="${MACHELPER_UI_SMOKE_CONFIGURATION:-Debug}"
if [ "$CONFIGURATION" = "Release" ]; then
    DEFAULT_MAX_MAIN_BUSY_MS=700
else
    DEFAULT_MAX_MAIN_BUSY_MS=900
fi
MAX_MAIN_BUSY_MS="${MACHELPER_UI_SMOKE_MAX_MAIN_BUSY_MS:-$DEFAULT_MAX_MAIN_BUSY_MS}"
# Probe-only delay for the cancellation scenario. Zero in the normal run.
SERIES_DELAY_MS="${MACHELPER_UI_SMOKE_SERIES_DELAY_MS:-0}"

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "• $*"; }

DOMAINS=$(defaults domains 2>/dev/null) || fail "Could not inspect defaults domains."
if printf '%s\n' "$DOMAINS" | awk -v domain="$BUNDLE" '
    {
        sub(/^[^:]*:[[:space:]]*/, "")
        count = split($0, names, ",")
        for (i = 1; i <= count; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", names[i])
            if (names[i] == domain) found = 1
        }
    }
    END { exit !found }
'; then
    fail "Generated defaults domain already exists: $BUNDLE"
fi
OWNS_DEFAULTS_DOMAIN=1

cleanup() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    if [ "$OWNS_DEFAULTS_DOMAIN" = "1" ]; then
        defaults delete "$BUNDLE" >/dev/null 2>&1 || true
    fi
    if [ -n "$SMOKE" ]; then rm -rf "$SMOKE"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- toolchain

try_developer_dir() {
    local candidate="$1"
    [ -n "$candidate" ] || return 1
    case "$candidate" in
        *.app) candidate="$candidate/Contents/Developer" ;;
    esac
    [ -d "$candidate" ] || return 1
    export DEVELOPER_DIR="$candidate"
    xcodebuild -version >/dev/null 2>&1
}

if ! xcodebuild -version >/dev/null 2>&1; then
    selected=$(xcode-select -p 2>/dev/null || true)
    try_developer_dir "$selected" || true
    if ! xcodebuild -version >/dev/null 2>&1; then
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            try_developer_dir "$candidate" && break
        done < <(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null)
    fi
    if ! xcodebuild -version >/dev/null 2>&1; then
        for candidate in /Applications/Xcode.app /Applications/Xcode-*.app; do
            [ -d "$candidate" ] || continue
            try_developer_dir "$candidate" && break
        done
    fi
fi
xcodebuild -version >/dev/null 2>&1 \
    || fail "xcodebuild is unavailable (DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo unknown)}). Set DEVELOPER_DIR to an Xcode with the macOS SDK."
note "Using $(xcodebuild -version | head -1); developer directory: ${DEVELOPER_DIR:-$(xcode-select -p)}"

OCU=$(command -v open-computer-use 2>/dev/null || command -v ocu 2>/dev/null || true)
[ -n "$OCU" ] || fail "open-computer-use was not found. Install it and grant Accessibility and Screen Recording."
"$OCU" doctor 2>/dev/null | grep -q "accessibility=granted" \
    || fail "Open Computer Use does not have Accessibility permission; run '$OCU doctor' and grant it."
"$OCU" doctor 2>/dev/null | grep -q "screenRecording=granted" \
    || fail "Open Computer Use does not have Screen Recording permission; run '$OCU doctor' and grant it."

# ---------------------------------------------------------------- build

if [ ! -d MacHelper.xcodeproj ]; then
    command -v xcodegen >/dev/null 2>&1 \
        || fail "MacHelper.xcodeproj is missing and xcodegen is not installed."
    [ -d build/Vendor/Sparkle/Sparkle.xcframework ] || ./scripts/sparkle/fetch.sh
    xcodegen generate --quiet
fi

mkdir -p "$OUT"
if [ "${MACHELPER_UI_SMOKE_SKIP_BUILD:-0}" = "1" ]; then
    BUILD_DIR="${MACHELPER_UI_SMOKE_DERIVED_DATA:-$ROOT/build/UISmokeMonitorDerived}"
else
    BUILD_DIR="$OUT/DerivedData"
fi
if [ "${MACHELPER_UI_SMOKE_SKIP_BUILD:-0}" != "1" ]; then
    note "Building MacHelper ($CONFIGURATION)…"
    if ! xcodebuild -project MacHelper.xcodeproj -scheme MacHelper -configuration "$CONFIGURATION" \
        -derivedDataPath "$BUILD_DIR" -quiet build >"$OUT/build.log" 2>&1; then
        tail -40 "$OUT/build.log" >&2
        fail "xcodebuild failed; full log: $OUT/build.log"
    fi
fi
APP="${MACHELPER_UI_SMOKE_APP:-$BUILD_DIR/Build/Products/$CONFIGURATION/MacHelper.app}"
[ -d "$APP" ] || fail "No $CONFIGURATION app at $APP (run without MACHELPER_UI_SMOKE_SKIP_BUILD=1, or pass MACHELPER_UI_SMOKE_APP)."

# ---------------------------------------------------------------- isolated copy and history

SMOKE=$(mktemp -d "${TMPDIR:-/tmp}/machelper-monitor-range.XXXXXX")
APP_COPY="$SMOKE/MacHelperMonitorSmoke.app"
SMOKE_HOME="$SMOKE/home"
DB="$SMOKE_HOME/Library/Application Support/MacHelper/history.sqlite"
mkdir -p "$SMOKE_HOME/Library/Application Support/MacHelper"

cp -R "$APP" "$APP_COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$APP_COPY/Contents/Info.plist"
# The smoke copy must never check for or install updates. A dead feed and no automatic
# checks keep Sparkle quiet; the installed app and its real feed are untouched.
/usr/libexec/PlistBuddy -c "Set :SUFeedURL http://127.0.0.1:1/appcast.xml" "$APP_COPY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$APP_COPY/Contents/Info.plist"
codesign --force --sign - "$APP_COPY" >/dev/null 2>&1 \
    || fail "Could not ad-hoc sign the smoke copy."
codesign --verify --deep --strict "$APP_COPY" >/dev/null 2>&1 \
    || fail "The smoke copy failed code-signature verification."

# `refreshRegistrationIfNeeded()` only re-registers an ad-hoc app when the stored CDHash
# differs from the bundled helper. Seeding the argument domain makes that check a no-op.
HELPER_HASH=$(codesign -d --verbose=4 "$APP_COPY/Contents/MacOS/MacHelperHelper" 2>&1 \
    | awk -F= '/^CDHash=/{hash=$2} END{print hash}')
[ -n "$HELPER_HASH" ] || fail "Could not read the embedded helper's CDHash."

note "Seeding seven days of minute history in $DB"
sqlite3 "$DB" < "$ROOT/Tests/UI/MonitorHistorySeed.sql"
ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sample; SELECT COUNT(*) FROM series_sample; SELECT COUNT(*) FROM process_sample;" | paste -sd/ -)
[ -n "$ROWS" ] || fail "The seeded history database is empty."
note "Seeded rows (sample/series/process): $ROWS"

# First-launch sheets would cover the page, and a menu-bar-only activation policy can
# leave the window unopened. These keys live only in the temporary home. `monitor.probe`
# turns on the same switch log as --monitor-probe without adding argv (a copy launched
# with extra arguments does not open its SwiftUI window on this macOS).
note "Isolating the smoke copy's defaults…"
for key in "onboarding.fullDiskAccess.shown" "onboarding.helper.shown" "onboarding.agentSkill.asked"; do
    env CFFIXED_USER_HOME="$SMOKE_HOME" defaults write "$BUNDLE" "$key" -bool true
done
env CFFIXED_USER_HOME="$SMOKE_HOME" defaults write "$BUNDLE" dockMode always
env CFFIXED_USER_HOME="$SMOKE_HOME" defaults write "$BUNDLE" monitor.probe -bool true
if [ "$SERIES_DELAY_MS" != "0" ]; then
    env CFFIXED_USER_HOME="$SMOKE_HOME" defaults write "$BUNDLE" monitor.seriesQueryDelayMs -int "$SERIES_DELAY_MS"
fi

# ---------------------------------------------------------------- UI script

cat >"$OUT/check.js" <<'JS'
const fs = require("fs");

const bundle = process.env.SMOKE_BUNDLE;
const out = process.env.SMOKE_OUT;
const seriesDelay = Number(process.env.SMOKE_SERIES_DELAY || "0");
const app = await cua.getApp(bundle, { initialState: false });
const logPath = `${out}/app.log`;

function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

async function state(nodes = 1200) {
    return app.getAXState({ includeScreenshot: false, maxTreeNodes: nodes });
}
function logOffset() {
    try { return fs.statSync(logPath).size; } catch (error) { return 0; }
}
function logSince(offset) {
    try { return fs.readFileSync(logPath, "utf8").slice(offset); } catch (error) { return ""; }
}
async function waitLog(offset, pattern, timeout = 120000) {
    const started = Date.now();
    for (;;) {
        const text = logSince(offset);
        const match = text.match(pattern);
        if (match) return { match, text, elapsed: Date.now() - started };
        if (Date.now() - started > timeout) throw new Error(`Timed out waiting for ${pattern} in app.log.`);
        await sleep(50);
    }
}
// MHPROBE lines are the app's own events; their timestamps are CFAbsoluteTime seconds.
function probeEvents(text) {
    const events = [];
    for (const line of text.split("\n")) {
        const match = line.match(/MHPROBE ([0-9.]+) (\S+)(?: (.*))?$/);
        if (match) events.push({ t: Number(match[1]), event: match[2], detail: match[3] || "" });
    }
    return events;
}
function eventAfter(events, event, detailPattern, after = -Infinity) {
    return events.find(e => e.event === event && e.t >= after && detailPattern.test(e.detail));
}
function msBetween(from, to) {
    return from && to ? Math.round((to.t - from.t) * 1000) : null;
}
function mainBusy(events, after, windowSeconds = 2) {
    const values = events.filter(e => e.event === "main-busy" && e.t >= after && e.t <= after + windowSeconds)
        .map(e => parseFloat(e.detail));
    return { count: values.length, max: values.length ? Math.max(...values) : 0 };
}
// The AX query itself takes tens of milliseconds; measure it separately so the observed
// switch time is not presented as pure main-thread work.
async function measureQueryCost(samples = 5) {
    const values = [];
    for (let i = 0; i < samples; i++) {
        const started = Date.now();
        await state(80);
        values.push(Date.now() - started);
    }
    values.sort((a, b) => a - b);
    return values[Math.floor(values.length / 2)];
}
// Screenshots are supporting evidence; a transient CGWindow miss must not hide the
// functional result. Retry once and record why a shot is missing.
async function capture(name) {
    for (let attempt = 0; attempt < 2; attempt++) {
        try {
            fs.writeFileSync(`${out}/${name}`, await app.getScreenshot({ emit: false }));
            return;
        } catch (error) {
            if (attempt === 1) {
                fs.writeFileSync(`${out}/${name}.error.txt`, String(error && error.message ? error.message : error));
            } else {
                await sleep(500);
            }
        }
    }
}

async function waitForChip(title, timeout = 60000) {
    const start = Date.now();
    for (;;) {
        try {
            const text = await state(80);
            if (new RegExp(`^\\s*\\d+\\s+button\\s+${title}\\s*$`, "m").test(text)) return;
        } catch (error) {
            // The window is still opening.
        }
        if (Date.now() - start > timeout) throw new Error(`The ${title} chip did not appear within ${timeout} ms.`);
        await sleep(500);
    }
}
async function clickChip(title) {
    const text = await state(80);
    const match = text.match(new RegExp(`^\\s*(\\d+)\\s+button\\s+${title}\\s*$`, "m"));
    if (!match) throw new Error(`The ${title} chip is missing.`);
    const started = Date.now();
    try {
        await app.click(match[1], { clickMethod: "accessibility" });
    } catch (error) {
        // The action read-back can fail while the chart re-lays out; the state checks below
        // decide whether the click landed.
    }
    return Date.now() - started;
}
async function waitText(text, timeout = 120000) {
    const start = Date.now();
    for (;;) {
        if ((await app.query({ text, exact: true })).matches.length) return Date.now() - start;
        if (Date.now() - start > timeout) throw new Error(`Timed out waiting for "${text}".`);
        await sleep(25);
    }
}
// The sensor and process sections sit below the scroll fold; a targeted query only sees
// on-screen controls, so these checks read the full (bounded) accessibility tree.
async function waitStateText(text, timeout = 60000) {
    const start = Date.now();
    for (;;) {
        try {
            if ((await state(1600)).includes(text)) return Date.now() - start;
        } catch (error) {
            // The page is re-laying out.
        }
        if (Date.now() - start > timeout) throw new Error(`Timed out waiting for "${text}" in the accessibility tree.`);
        await sleep(500);
    }
}
function check(condition, message) {
    if (!condition) throw new Error(message);
}
function recentMinuteOnScreen(text) {
    // Live charts expose minute ranges such as "Nov 12, 2026 at 00:33:00.000 to ...".
    const now = Date.now();
    const pattern = /([A-Z][a-z]{2} \d{1,2}, \d{4}) at (\d{2}):(\d{2}):(\d{2})/g;
    let match;
    while ((match = pattern.exec(text))) {
        const date = new Date(`${match[1]} ${match[2]}:${match[3]}:${match[4]}`);
        if (!Number.isNaN(date.getTime()) && Math.abs(now - date.getTime()) < 10 * 60 * 1000) return true;
    }
    return false;
}
async function waitRecentMinute(timeout = 30000) {
    const started = Date.now();
    for (;;) {
        const text = await state(1600);
        if (recentMinuteOnScreen(text)) return Date.now() - started;
        if (Date.now() - started > timeout) throw new Error("The live chart never showed a recent minute.");
        await sleep(50);
    }
}
// The week sensor chart is below the main chart, so the check reads the full tree. The
// seed has two recording gaps; the week commit must report at least two segments and the
// header values must be realistic (a forgotten value_count showed 1–2 °C and MB-sized GB
// processes instead).
async function waitWeekSensorState(weekCommit, timeout = 30000) {
    const started = Date.now();
    let text = "";
    for (;;) {
        text = await state(1600);
        if (text.includes("Averages per 30 minutes")) break;
        if (Date.now() - started > timeout) break;
        await sleep(200);
    }
    fs.writeFileSync(`${out}/week-state.txt`, text);
    checkWeekSensorState(text, weekCommit);
}
function checkWeekSensorState(text, weekCommit) {
    check(text.includes("Averages per 30 minutes"), "The 7-day header is missing.");
    check(text.includes("CPU core clusters"), "The 7-day sensor chart is missing.");
    // Swift Charts exposes each week axis slot as a date range; two different days prove
    // the sensor chart is on the week axis, not the live minute axis.
    const days = new Set(text.match(/[A-Z][a-z]{2} \d{1,2}, \d{4}/g) || []);
    check(days.size >= 2, "The 7-day charts do not show a multi-day axis.");
    if (text.includes("Temperature sensors")) {
        const temperature = text.match(/Temperature sensors[\s\S]{0,120}?(-?\d+)°/);
        check(temperature && Number(temperature[1]) >= 30 && Number(temperature[1]) <= 80,
              `The 7-day temperature header is not realistic: ${temperature ? temperature[1] : "missing"}`);
    }
    const cores = text.match(/CPU core clusters[\s\S]{0,120}?(\d+)%/);
    check(cores && Number(cores[1]) >= 5 && Number(cores[1]) <= 90,
          `The 7-day core header is not realistic: ${cores ? cores[1] : "missing"}`);
    const xcode = text.match(/Xcode[\s\S]{0,160}?(\d+(?:\.\d+)?) (GB|MB)/);
    check(xcode && xcode[2] === "GB",
          `The 7-day process memory is not realistic: ${xcode ? xcode[0] : "missing"}`);
    check(weekCommit.match[2] !== "0", "The 7-day sensor commit has no points.");
    check(Number(weekCommit.match[3]) >= 2, "The 7-day sensor chart has no gap segments.");
    const span = Number(weekCommit.match[5]) - Number(weekCommit.match[4]);
    check(span >= 6 * 86400, `The 7-day sensor data spans only ${span} seconds.`);
}

// The copy starts on Overview; ⌘2 opens Monitor, the same page the installed app uses.
for (let attempt = 0; attempt < 40; attempt++) {
    try {
        if ((await state(60)).includes("ID: main")) break;
    } catch (error) {
        // The window is still opening.
    }
    await sleep(500);
}
try {
    await app.pressKey("cmd+2");
} catch (error) {
    // The chip wait below reports a page that never opened.
}
await waitForChip("7 days");
const axQueryCost = await measureQueryCost();

// With a probe-only delay, click 7 days and Live 150 ms later. The week query is still
// running when Live replaces it; it must not commit its samples or range afterwards.
// This runs before the normal passes so the week samples are not cached yet.
let cancellation = null;
if (seriesDelay > 0) {
    const cancelOffset = logOffset();
    await clickChip("7 days");
    await sleep(150);
    await clickChip("Live");
    await waitText("Last 5 minutes, updated live");
    await waitLog(cancelOffset, /series-commit(?:-cache)? range=live /);
    await sleep(seriesDelay + 1500);
    const cancelEvents = probeEvents(logSince(cancelOffset));
    const cancelSets = cancelEvents.filter(e => e.event === "range-set");
    const cancelLive = cancelSets.filter(e => e.detail === "live").pop();
    check(cancelLive, "The cancellation run never selected Live.");
    const stale = cancelEvents.filter(e => /^series-commit/.test(e.event)
        && e.t > cancelLive.t && !/range=live/.test(e.detail));
    check(stale.length === 0,
          `A cancelled query overwrote the new range: ${stale.map(e => e.detail).join("; ")}`);
    const cancelState = await state(1600);
    check(cancelState.includes("Last 5 minutes, updated live"), "The cancellation run did not end on Live.");
    check(recentMinuteOnScreen(cancelState), "The cancellation run does not show live times.");
    await capture("after-cancel.png");
    cancellation = { delayMs: seriesDelay, staleCommits: stale.length };
}

const passes = [];
for (let pass = 0; pass < 3; pass++) {
    const weekOffset = logOffset();
    const weekAction = await clickChip("7 days");
    const weekHeader = await waitText("Averages per 30 minutes");
    const weekCommit = await waitLog(weekOffset,
        /series-commit(?:-cache)? range=week series=(\d+) points=(\d+) segments=(\d+) first=(\d+) last=(\d+)/);
    await waitStateText("Process history");
    await waitStateText("kernel_task");
    await waitWeekSensorState(weekCommit);
    const weekEvents = probeEvents(logSince(weekOffset));
    const weekSet = eventAfter(weekEvents, "range-set", /^week$/);
    const weekChart = eventAfter(weekEvents, "content", /chart=week/, weekSet ? weekSet.t : -Infinity);
    const weekCommitEvent = weekEvents.find(e => /^series-commit/.test(e.event) && /range=week/.test(e.detail));
    const weekOverview = weekEvents.find(e => e.event === "history-load-done" && /^week \d+ points/.test(e.detail));
    check(weekOverview && !/^week 0 points/.test(weekOverview.detail),
          "The 7-day overview query returned no points.");

    const liveOffset = logOffset();
    const liveStarted = Date.now();
    const liveAction = await clickChip("Live");
    const liveHeader = await waitText("Last 5 minutes, updated live");
    await waitLog(liveOffset, /series-commit(?:-cache)? range=live /);
    await waitRecentMinute();
    const liveDataObserved = Date.now() - liveStarted;
    const liveEvents = probeEvents(logSince(liveOffset));
    const liveSet = eventAfter(liveEvents, "range-set", /^live$/);
    const liveChart = eventAfter(liveEvents, "content", /chart=live/, liveSet ? liveSet.t : -Infinity);
    const liveCommitEvent = liveEvents.find(e => /^series-commit/.test(e.event) && /range=live/.test(e.detail));
    const busy = mainBusy(liveEvents, liveSet ? liveSet.t : -Infinity, 2);
    passes.push({
        pass,
        clickMs: { week: weekAction, live: liveAction },
        headerObservedMs: { week: weekHeader, live: liveHeader },
        appChartMs: { week: msBetween(weekSet, weekChart), live: msBetween(liveSet, liveChart) },
        appSeriesMs: { week: msBetween(weekSet, weekCommitEvent), live: msBetween(liveSet, liveCommitEvent) },
        axObservedMs: { liveFromClick: liveDataObserved },
        mainBusy: busy,
        week: {
            points: Number(weekCommit.match[2]),
            segments: Number(weekCommit.match[3]),
            spanSeconds: Number(weekCommit.match[5]) - Number(weekCommit.match[4]),
        },
    });
    await sleep(1000);
}

// Each history range loads and shows its own bucket caption before the rapid pass.
await clickChip("1 hour");
await waitText("Averages per 1 minute");
await clickChip("24 hours");
await waitText("Averages per 5 minutes");
await clickChip("7 days");
await waitText("Averages per 30 minutes");
await clickChip("Live");
await waitText("Last 5 minutes, updated live");

// Rapid switching must end on the last selected range, and the live chart must show
// recent times rather than stale week data. No replaced range may commit after the final
// Live selection.
const rapidOffset = logOffset();
for (const title of ["7 days", "Live", "24 hours", "Live", "1 hour", "7 days", "Live"]) {
    await clickChip(title);
    await sleep(250);
}
await waitText("Last 5 minutes, updated live");
await sleep(2000);
const finalState = await state(1600);
check(finalState.includes("Last 5 minutes, updated live"), "The final range is not Live.");
check(!finalState.includes("Averages per 30 minutes"), "The final screen still shows the 7-day header.");
check(recentMinuteOnScreen(finalState), "The live chart does not show times from the last 10 minutes; it may still draw week-old samples.");
const rapidEvents = probeEvents(logSince(rapidOffset));
const rapidSets = rapidEvents.filter(e => e.event === "range-set");
const finalSet = rapidSets[rapidSets.length - 1];
check(finalSet && finalSet.detail === "live", "The final range-set is not Live.");
const lateCommits = rapidEvents.filter(e => /^series-commit/.test(e.event)
    && e.t > finalSet.t && !/range=live/.test(e.detail));
check(lateCommits.length === 0,
      `A replaced range committed after the final Live: ${lateCommits.map(e => e.detail).join("; ")}`);

await capture("after-rapid-live.png");
const screenshotWeekOffset = logOffset();
await clickChip("7 days");
await waitText("Averages per 30 minutes");
await waitLog(screenshotWeekOffset, /series-commit(?:-cache)? range=week /);
await sleep(500);
await capture("after-week.png");
await clickChip("Live");
await waitText("Last 5 minutes, updated live");
await capture("after-live.png");

fs.writeFileSync(`${out}/result.json`,
    JSON.stringify({ passes, axQueryCostMs: axQueryCost, cancellation, final: "LIVE" }, null, 2));
const summary = passes.map(p => `pass ${p.pass}: click week/live ${p.clickMs.week}/${p.clickMs.live} ms, ` +
    `app chart ${p.appChartMs.week}/${p.appChartMs.live} ms, ` +
    `app series ${p.appSeriesMs.week}/${p.appSeriesMs.live} ms, ` +
    `live AX-observed ${p.axObservedMs.liveFromClick} ms, ` +
    `main-busy max ${p.mainBusy.max} ms (${p.mainBusy.count}), ` +
    `week ${p.week.points} pts / ${p.week.segments} segments`).join("\n");
nodeRepl.write(`PASS: final Live; AX query cost ${axQueryCost} ms\n${summary}` +
    (cancellation ? `\ncancellation: ${cancellation.delayMs} ms delay, ${cancellation.staleCommits} stale commits` : ""));
JS

note "Launching the isolated app…"
# Only the three single-dash arguments the app already reads: an extra argv entry keeps
# this macOS from opening the copy's SwiftUI window. The probe switch lives in the
# temporary defaults domain instead.
env CFFIXED_USER_HOME="$SMOKE_HOME" "$APP_COPY/Contents/MacOS/MacHelper" \
    -AppleLanguages '(en)' -AppleLocale en_US \
    -helper.registeredCDHash "$HELPER_HASH" >"$OUT/app.log" 2>&1 &
APP_PID=$!
sleep 2

if ! env SMOKE_BUNDLE="$BUNDLE" SMOKE_OUT="$OUT" SMOKE_SERIES_DELAY="$SERIES_DELAY_MS" \
    "$OCU" js --timeout 320000 --file "$OUT/check.js" >"$OUT/check.log" 2>&1; then
    tail -30 "$OUT/check.log" >&2
    fail "UI check failed (full log: $OUT/check.log)"
fi
grep '^PASS:' "$OUT/check.log"

kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

# ---------------------------------------------------------------- main-thread evidence

note "Parsing the monitor probe with the shared parser…"
if ! BUSY_SUMMARY=$(monitor_probe_busy_summary "$OUT/app.log"); then
    fail "Could not parse the monitor probe log; a parse failure is not zero busy time."
fi
BUSY_COUNT=${BUSY_SUMMARY%% *}
MAX_BUSY=${BUSY_SUMMARY#* }
if [ "$BUSY_COUNT" -eq 0 ]; then
    note "No main-thread stretch reached the 100 ms probe threshold."
else
    note "Main-thread stretches over 100 ms: ${BUSY_COUNT}; longest ${MAX_BUSY} ms (ceiling ${MAX_MAIN_BUSY_MS} ms)"
fi
awk -v max="$MAX_BUSY" -v ceiling="$MAX_MAIN_BUSY_MS" 'BEGIN { exit !(max <= ceiling) }' \
    || fail "The main thread stalled for ${MAX_BUSY} ms; ceiling is ${MAX_MAIN_BUSY_MS} ms."

WEEK_COMMIT=$(grep -E 'MHPROBE [0-9.]+ series-commit(-cache)? range=week ' "$OUT/app.log" | tail -1)
[ -n "$WEEK_COMMIT" ] || fail "The 7-day sensor history never committed."
WEEK_POINTS=$(printf '%s\n' "$WEEK_COMMIT" | sed -n 's/.* points=\([0-9]*\) .*/\1/p')
WEEK_SEGMENTS=$(printf '%s\n' "$WEEK_COMMIT" | sed -n 's/.* segments=\([0-9]*\) .*/\1/p')
[ -n "$WEEK_POINTS" ] && [ "$WEEK_POINTS" -gt 0 ] \
    || fail "The 7-day sensor commit has no points; a zero-point week is not a loaded week."
note "7-day sensor history: ${WEEK_POINTS} points per series, ${WEEK_SEGMENTS} segments"
[ "$WEEK_POINTS" -lt 2000 ] \
    || fail "The 7-day sensor chart still draws $WEEK_POINTS points per series; it should be bucketed."
[ "${WEEK_SEGMENTS:-0}" -ge 2 ] \
    || fail "The 7-day sensor chart has no gap segments; the seeded recording gaps were averaged away."

grep -qE 'MHPROBE [0-9.]+ history-load-done week [1-9][0-9]* points' "$OUT/app.log" \
    || fail "The 7-day overview query returned no points."
grep -qE 'MHPROBE [0-9.]+ series-commit(-cache)? range=live ' "$OUT/app.log" \
    || fail "The live sensor history never committed."

echo "Monitor range smoke passed. Screenshots: $OUT/after-week.png, $OUT/after-rapid-live.png, $OUT/after-live.png; sensor week state: $OUT/week-state.txt"
