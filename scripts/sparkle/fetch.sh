#!/bin/bash
# Downloads the official Sparkle release used by the app and the appcast tools.
#
# Xcode 27.2 hangs while resolving Sparkle's Swift Package binary target on this
# project (waitForRemoteSourcePackagesToFinishLoading), even when the artifact is
# already cached. The release archive contains the same Sparkle.xcframework and
# bin tools that SPM would install, so we vendor that archive under build/Vendor.
# The archive is not committed; run this before xcodegen/build.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="2.10.1"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-for-Swift-Package-Manager.zip"
SHA256="4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
DEST="build/Vendor/Sparkle"
ZIP="build/Vendor/Sparkle-${VERSION}.zip"

if [[ -d "$DEST/Sparkle.xcframework" && -x "$DEST/bin/generate_appcast" ]]; then
  echo "Sparkle ${VERSION} already present: ${DEST}"
  exit 0
fi

mkdir -p build/Vendor
echo "→ Downloading Sparkle ${VERSION}"
curl -fL --retry 3 --connect-timeout 15 -o "$ZIP" "$URL"
echo "${SHA256}  ${ZIP}" | shasum -a 256 -c -
case "$DEST" in
  build/Vendor/Sparkle) rm -rf "$DEST" ;;
  *) echo "✗ refusing to clean unexpected path: ${DEST}" >&2; exit 1 ;;
esac
mkdir -p "$DEST"
ditto -x -k "$ZIP" "$DEST"
[[ -d "$DEST/Sparkle.xcframework" ]] || { echo "✗ Sparkle.xcframework missing after extraction" >&2; exit 1; }
[[ -x "$DEST/bin/generate_appcast" ]] || { echo "✗ Sparkle command line tools missing after extraction" >&2; exit 1; }
rm -f "$ZIP"
echo "Sparkle ${VERSION} ready: ${DEST}"
