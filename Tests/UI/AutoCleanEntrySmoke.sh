#!/bin/bash
#
# Native UI smoke for the Auto Clean entry on the Optimize start screen.
#
# The app target has no XCTest target, so this check builds the real app and drives its
# SwiftUI window through macOS Accessibility with Open Computer Use. It verifies the parts
# a compile cannot:
#   - the start screen shows a labeled Auto Clean entry and its Off/On state,
#   - the entry and the existing toolbar button open the existing settings sheet,
#   - closing the sheet returns to the start screen,
#   - neither opening nor closing writes autoclean.json or runs a clean.
#
# Everything the app writes goes to a temporary home (CFFIXED_USER_HOME). The launch copy
# gets a fresh bundle id and defaults domain after the script confirms that domain is absent.
# The helper registration check uses the copied helper's CDHash, so the app does not register
# or unregister a system service. Cleanup removes only this run's domain and temporary home.
#
# Requirements: Xcode with the macOS SDK (set DEVELOPER_DIR if xcode-select points at
# Command Line Tools) and the `open-computer-use` CLI with Accessibility and Screen
# Recording permission (`open-computer-use doctor`). Each run saves screenshots and logs to
# its own build/ui-smoke/<run-id>/ directory.
#
# Usage:
#   Tests/UI/AutoCleanEntrySmoke.sh
#   MACHELPER_UI_SMOKE_SKIP_BUILD=1 Tests/UI/AutoCleanEntrySmoke.sh
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

RUN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
BUNDLE="com.machelper.MacHelper.UISmoke.$RUN_ID"
OUT="$ROOT/build/ui-smoke/$RUN_ID"
if [ "${MACHELPER_UI_SMOKE_SKIP_BUILD:-0}" = "1" ]; then
    BUILD_DIR="${MACHELPER_UI_SMOKE_DERIVED_DATA:-$ROOT/build/UISmokeDerived}"
else
    BUILD_DIR="$OUT/DerivedData"
fi
CONFIG_REL="Library/Application Support/MacHelper/autoclean.json"
APP_PID=""
APP_LOG_STATE=""
SMOKE=""
OWNS_DEFAULTS_DOMAIN=0

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "• $*"; }

# A fresh bundle id isolates the copied app's defaults from the installed app and prior runs.
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

# ---------------------------------------------------------------- localization guard

python3 - "$ROOT/App/Resources/Localizable.xcstrings" <<'PY'
import json, sys

path = sys.argv[1]
catalog = json.load(open(path, encoding="utf-8"))["strings"]
languages = {"es", "ja", "ko", "zh-Hans", "zh-Hant"}
keys = [
    "Auto Clean: Off",
    "Auto Clean: On",
    "A schedule is set to clean low-risk items automatically.",
    "Opens the Auto Clean schedule settings.",
    "Set a schedule to clean low-risk items automatically.",
    "On",
    "Off",
]
missing = []
for key in keys:
    localizations = catalog.get(key, {}).get("localizations", {})
    for language in sorted(languages):
        if not localizations.get(language, {}).get("stringUnit", {}).get("value"):
            missing.append(f"{key} [{language}]")
if missing:
    raise SystemExit("Missing translations: " + ", ".join(missing))
print(f"Localization ok: {len(keys)} keys translated in {len(languages)} languages")
PY

# ---------------------------------------------------------------- build

mkdir -p "$OUT"
if [ "${MACHELPER_UI_SMOKE_SKIP_BUILD:-0}" != "1" ]; then
    note "Building MacHelper (Debug)…"
    if ! xcodebuild -project MacHelper.xcodeproj -scheme MacHelper -configuration Debug \
        -derivedDataPath "$BUILD_DIR" -quiet build >"$OUT/build.log" 2>&1; then
        tail -40 "$OUT/build.log" >&2
        fail "xcodebuild failed; full log: $OUT/build.log"
    fi
fi
APP="$BUILD_DIR/Build/Products/Debug/MacHelper.app"
[ -d "$APP" ] || fail "No debug app at $APP (run without MACHELPER_UI_SMOKE_SKIP_BUILD=1)."

# ---------------------------------------------------------------- isolated copy

SMOKE=$(mktemp -d "${TMPDIR:-/tmp}/machelper-autoclean-entry.XXXXXX")
APP_COPY="$SMOKE/MacHelperUISmoke.app"
SMOKE_HOME="$SMOKE/home"
CONFIG="$SMOKE_HOME/$CONFIG_REL"
mkdir -p "$SMOKE_HOME/Library/Application Support/MacHelper"

cp -R "$APP" "$APP_COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$APP_COPY/Contents/Info.plist"
codesign --force --sign - "$APP_COPY" >/dev/null 2>&1 \
    || fail "Could not ad-hoc sign the smoke copy."
codesign --verify --deep --strict "$APP_COPY" >/dev/null 2>&1 \
    || fail "The smoke copy failed code-signature verification."

# `refreshRegistrationIfNeeded()` only re-registers an ad-hoc app when the stored CDHash
# differs from the bundled helper. Seeding the argument domain makes that check a no-op.
HELPER_HASH=$(codesign -d --verbose=4 "$APP_COPY/Contents/MacOS/MacHelperHelper" 2>&1 \
    | awk -F= '/^CDHash=/{hash=$2} END{print hash}')
[ -n "$HELPER_HASH" ] || fail "Could not read the embedded helper's CDHash."

write_config() {
    local enabled="$1" frequency="$2" item_count="$3"
    cat >"$CONFIG" <<JSON
{
  "enabled" : $enabled,
  "frequency" : "$frequency",
  "permanent" : false,
  "trashInstead" : false,
  "maintenanceTasks" : [],
  "lastRun" : "2026-11-10T09:00:00Z",
  "lastTrashedBytes" : 1048576,
  "lastFreedBytes" : 2097152,
  "lastItemCount" : $item_count,
  "lastError" : null,
  "lastTasks" : []
}
JSON
}

launch_app() {
    env CFFIXED_USER_HOME="$SMOKE_HOME" "$APP_COPY/Contents/MacOS/MacHelper" \
        --snapshot-section optimize \
        -AppleLanguages '(en)' -AppleLocale en_US \
        -helper.registeredCDHash "$HELPER_HASH" \
        >"$OUT/app-$APP_LOG_STATE.log" 2>&1 &
    APP_PID=$!
}

stop_app() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
}

# ---------------------------------------------------------------- UI script

cat >"$OUT/check.js" <<'JS'
const fs = require("fs");

const bundle = process.env.SMOKE_BUNDLE;
const out = process.env.SMOKE_OUT;
const expected = process.env.SMOKE_EXPECT;   // "Off" or "On"
const expectedCount = process.env.SMOKE_EXPECT_COUNT;
const interact = process.env.SMOKE_INTERACT === "1";

function check(condition, message) {
    if (!condition) throw new Error(message);
}

async function waitForApp() {
    for (let attempt = 0; attempt < 30; attempt++) {
        try {
            const app = await cua.getApp(bundle, { initialState: false });
            const state = await app.getAXState({ includeScreenshot: false });
            if (state.includes("ID: optimize.autoClean.entry")) return { app, state };
        } catch (error) {
            // The window is still opening; try again.
        }
        await new Promise(resolve => setTimeout(resolve, 1000));
    }
    throw new Error("The Optimize page did not expose the Auto Clean entry within 30 s.");
}

const { app, state: initial } = await waitForApp();
check(initial.includes("ID: optimize.autoClean.entry"), "Auto Clean entry is missing");
check(
    new RegExp(`ID: optimize\\.autoClean\\.entry, Value: ${expected}\\b`).test(initial),
    `Auto Clean entry does not report ${expected}`
);
fs.writeFileSync(`${out}/optimize-${expected.toLowerCase()}.png`, await app.getScreenshot({ emit: false }));

if (interact) {
    const entry = initial.match(/^\s*(\d+)\s+.*ID: optimize\.autoClean\.entry/m);
    check(entry, "Auto Clean entry has no accessibility index");
    await app.click(entry[1], { clickMethod: "accessibility" });

    const sheet = await app.getAXState({ includeScreenshot: false });
    check(sheet.includes("Enable Auto Clean"), "The settings sheet did not open");
    check(
        sheet.includes(`${expectedCount} items`),
        `The settings sheet did not read the complete ${expected} config`
    );
    fs.writeFileSync(`${out}/sheet-${expected.toLowerCase()}.png`, await app.getScreenshot({ emit: false }));

    const done = sheet.match(/^\s*(\d+)\s+button\s+Done\b/m);
    check(done, "The settings sheet has no Done button");
    await app.click(done[1], { clickMethod: "accessibility" });

    const closed = await app.getAXState({ includeScreenshot: false });
    check(closed.includes("ID: optimize.autoClean.entry"), "Closing the sheet did not return to the start screen");

    // The toolbar button is the original entry; it must keep working next to the new one.
    const toolbar = closed.match(/^\s*(\d+)\s+button\s+Auto Clean: (?:Off|On)\b/m);
    check(toolbar, "The toolbar Auto Clean button is missing");
    await app.click(toolbar[1], { clickMethod: "accessibility" });

    const toolbarSheet = await app.getAXState({ includeScreenshot: false });
    check(toolbarSheet.includes("Enable Auto Clean"), "The toolbar button did not open the settings sheet");
    const toolbarDone = toolbarSheet.match(/^\s*(\d+)\s+button\s+Done\b/m);
    check(toolbarDone, "The toolbar-opened sheet has no Done button");
    await app.click(toolbarDone[1], { clickMethod: "accessibility" });

    const afterToolbar = await app.getAXState({ includeScreenshot: false });
    check(afterToolbar.includes("ID: optimize.autoClean.entry"), "Closing the toolbar-opened sheet did not return to the start screen");
}

nodeRepl.write(`PASS: entry ${expected}${interact ? ", entry and toolbar opened the sheet and closed" : ""}`);
JS

run_check() {
    local expected="$1" expected_count="$2" interact="$3"
    if ! env SMOKE_BUNDLE="$BUNDLE" SMOKE_OUT="$OUT" SMOKE_EXPECT="$expected" \
        SMOKE_EXPECT_COUNT="$expected_count" SMOKE_INTERACT="$interact" \
        "$OCU" js --file "$OUT/check.js" >"$OUT/check-$expected.log" 2>&1; then
        tail -20 "$OUT/check-$expected.log" >&2
        fail "UI check failed for the $expected state (full log: $OUT/check-$expected.log)"
    fi
    grep '^PASS:' "$OUT/check-$expected.log"
}

# ---------------------------------------------------------------- Off state

note "Checking the Off state and the settings sheet…"
write_config false weekly 4
BEFORE=$(shasum -a 256 "$CONFIG" | awk '{print $1}')
APP_LOG_STATE=off
launch_app
run_check Off 4 1
stop_app
AFTER=$(shasum -a 256 "$CONFIG" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail "Opening and closing the sheet changed autoclean.json."
[ ! -e "$SMOKE_HOME/Library/Logs/MacHelper/operations.jsonl" ] \
    || fail "The UI check wrote an operations log; something ran a clean."

# ---------------------------------------------------------------- On state

note "Checking the On state and the settings sheet…"
write_config true daily 9
BEFORE=$(shasum -a 256 "$CONFIG" | awk '{print $1}')
APP_LOG_STATE=on
launch_app
run_check On 9 1
stop_app
AFTER=$(shasum -a 256 "$CONFIG" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail "Opening and closing the sheet changed autoclean.json."
[ ! -e "$SMOKE_HOME/Library/Logs/MacHelper/operations.jsonl" ] \
    || fail "The UI check wrote an operations log; something ran a clean."

echo "UI smoke passed. Screenshots: $OUT/optimize-off.png, $OUT/sheet-off.png, $OUT/optimize-on.png, $OUT/sheet-on.png"
