#!/bin/zsh
# Builds MacHelper (Release), replaces /Applications/MacHelper.app and relaunches it.
# A clean replace matters: ditto over an old bundle merges stale files and breaks the seal.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer}"
export DEVELOPER_DIR
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

xcodegen generate --quiet
LOG=build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project MacHelper.xcodeproj -scheme MacHelper -configuration Release -derivedDataPath build \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -30
  echo "BUILD FAILED (full log: $LOG)"
  exit 1
fi
grep -E "warning:" "$LOG" | grep -v "appintentsmetadataprocessor" | sort -u | head -20 || true
echo "** BUILD SUCCEEDED **"
APP=build/Build/Products/Release/MacHelper.app

osascript -e 'quit app "MacHelper"' 2>/dev/null || true
sleep 1
pkill -x MacHelper 2>/dev/null || true
rm -rf /Applications/MacHelper.app
ditto "$APP" /Applications/MacHelper.app
codesign --verify --deep --strict /Applications/MacHelper.app && echo VERIFY_OK
[[ "${NO_LAUNCH:-}" == 1 ]] || open /Applications/MacHelper.app
echo "installed build $BUILD_NUMBER"
