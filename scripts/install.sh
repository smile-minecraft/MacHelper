#!/bin/zsh
# Builds MacHelper (Release), replaces /Applications/MacHelper.app and relaunches it.
# A clean replace matters: ditto over an old bundle merges stale files and breaks the seal.
set -euo pipefail
cd "$(dirname "$0")/.."
XCODE_DEFAULT=/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer
if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_DEFAULT" ]]; then export DEVELOPER_DIR="$XCODE_DEFAULT"; fi
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

if pgrep -x machelper-cli >/dev/null; then
  echo "machelper-cli 還在執行；請先關閉「MacHelper 結束後繼續記錄」，等程序結束再安裝。"
  exit 1
fi
if pgrep -x MacHelper >/dev/null; then
  osascript -e 'quit app "MacHelper"' 2>/dev/null || true
  sleep 1
fi
pkill -x MacHelper 2>/dev/null || true
sleep 1
if pgrep -x MacHelper >/dev/null; then
  echo "MacHelper 還在執行，無法安裝；請先結束 App 再試。"
  exit 1
fi
# Keep the installed app so a bad build can be rolled back without rebuilding.
if [[ -d /Applications/MacHelper.app ]]; then
  PREVIOUS=build/previous
  rm -rf "$PREVIOUS"
  mkdir -p "$PREVIOUS"
  ditto /Applications/MacHelper.app "$PREVIOUS/MacHelper.app"
  echo "previous app backed up to $(pwd)/$PREVIOUS/MacHelper.app"
fi
# Replace the installed app without leaving a partial or missing bundle.
# Stage the new bundle in /Applications, verify it there, then rename the old one aside.
APPLICATIONS=/Applications
INSTALLED="$APPLICATIONS/MacHelper.app"
STAMP="$(date +%Y%m%d%H%M%S)-$$"
NEW_APP="$APPLICATIONS/.MacHelper-new-$STAMP"
OLD_APP="$APPLICATIONS/.MacHelper-old-$STAMP"
NEW_PREFIX="$APPLICATIONS/.MacHelper-new-"
OLD_PREFIX="$APPLICATIONS/.MacHelper-old-"

remove_own_app() {
  local target="$1" prefix="$2"
  if [[ -z "$target" || -z "$prefix" || "$target" != "$prefix"* || "$target" == "$prefix" ]]; then
    echo "拒絕刪除不在預期位置的路徑：$target" >&2
    return 1
  fi
  rm -rf "$target"
}

cleanup_new_app() {
  if [[ -e "$NEW_APP" || -L "$NEW_APP" ]]; then
    remove_own_app "$NEW_APP" "$NEW_PREFIX" || echo "新版暫存留在 $NEW_APP，確認後再刪。"
  fi
}

if [[ -e "$NEW_APP" || -L "$NEW_APP" || -e "$OLD_APP" || -L "$OLD_APP" ]]; then
  echo "暫存名稱已存在（$STAMP），停止；$INSTALLED 沒有動。"
  exit 1
fi

echo "複製新版到暫存位置…"
if ! ditto "$APP" "$NEW_APP"; then
  echo "新版複製失敗；$INSTALLED 沒有動。"
  cleanup_new_app
  exit 1
fi
if ! codesign --verify --deep --strict "$NEW_APP"; then
  echo "新版簽章驗證失敗；$INSTALLED 沒有動。"
  cleanup_new_app
  exit 1
fi

HAD_OLD=0
if [[ -d "$INSTALLED" ]]; then
  HAD_OLD=1
  echo "把目前的 App 改名成備份位置…"
  if ! mv "$INSTALLED" "$OLD_APP"; then
    if [[ -e "$OLD_APP" && ! -e "$INSTALLED" ]]; then
      if mv "$OLD_APP" "$INSTALLED"; then
        echo "已把舊版放回 $INSTALLED。"
      else
        echo "舊版在 $OLD_APP，無法放回 $INSTALLED；新版暫存在 $NEW_APP，先不要刪除，回報這個狀況。"
        exit 1
      fi
    else
      echo "舊版仍在 $INSTALLED。"
    fi
    cleanup_new_app
    exit 1
  fi
  echo "目前的 App 已改名為：$OLD_APP"
fi

echo "把新版放到 $INSTALLED…"
if ! mv "$NEW_APP" "$INSTALLED"; then
  echo "新版放到 $INSTALLED 失敗。"
  if [[ "$HAD_OLD" == 1 && -e "$OLD_APP" && ! -e "$INSTALLED" ]]; then
    if mv "$OLD_APP" "$INSTALLED"; then
      echo "已把舊版放回 $INSTALLED。"
    else
      echo "舊版在 $OLD_APP，無法放回 $INSTALLED；新版在 $NEW_APP，先不要刪除，回報這個狀況。"
      exit 1
    fi
  elif [[ "$HAD_OLD" == 1 ]]; then
    echo "舊版在 $OLD_APP；$INSTALLED 有其他東西，先不要刪除，回報這個狀況。"
    exit 1
  fi
  cleanup_new_app
  exit 1
fi

# The staged bundle was verified before the rename; moving it does not change its contents.
echo VERIFY_OK
if [[ "$HAD_OLD" == 1 ]]; then
  if ! remove_own_app "$OLD_APP" "$OLD_PREFIX"; then
    echo "舊版暫存留在 $OLD_APP，確認新版可用後再刪。"
  fi
fi
[[ "${NO_LAUNCH:-}" == 1 ]] || open "$INSTALLED"
echo "installed build $BUILD_NUMBER"
