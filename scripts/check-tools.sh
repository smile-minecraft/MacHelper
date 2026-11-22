#!/bin/bash
# Checks that this Mac can build MacHelper and says how to fix what's missing.
# Run by `make setup`; safe to run any time (it changes nothing).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/env.sh || exit 1

MIN_XCODE=26
ok=1
say() { printf '%s\n' "$*"; }

# Read the whole output first: piping into `head -1` closes the pipe early, and with pipefail the
# SIGPIPE xcodebuild then gets reads as "Xcode not found" (it did on the CI runner).
if ! version_output="$(xcodebuild -version 2>/dev/null)"; then
    say "✗ Xcode not found. Install Xcode $MIN_XCODE or later from the App Store, then run:"
    say "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    say "  (The Command Line Tools alone can't build the app.) To use another Xcode for this"
    say "  project only, put DEVELOPER_DIR=… in Config/Local.env."
    ok=0
else
    version="${version_output%%$'\n'*}"
    major="$(sed -E 's/^Xcode ([0-9]+).*/\1/' <<< "$version")"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major < MIN_XCODE )); then
        say "✗ $version is too old: the app uses the macOS 26 SDK (Liquid Glass). Install Xcode $MIN_XCODE or later."
        ok=0
    else
        say "✓ $version ($(xcode-select -p 2>/dev/null)${DEVELOPER_DIR:+, DEVELOPER_DIR=$DEVELOPER_DIR})"
    fi
fi

if command -v xcodegen >/dev/null 2>&1; then
    say "✓ XcodeGen $(xcodegen --version 2>/dev/null | sed 's/^Version: //')"
else
    say "✗ XcodeGen not found. Install it with: brew install xcodegen"
    ok=0
fi

for tool in curl shasum unzip; do
    command -v "$tool" >/dev/null 2>&1 || { say "✗ $tool not found"; ok=0; }
done

if [[ "$(uname -m)" != "arm64" ]]; then
    say "! This Mac isn't Apple Silicon. The app builds, but its sensors and fan control only work on Apple Silicon."
fi

(( ok )) || exit 1
