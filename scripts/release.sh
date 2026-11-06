#!/bin/zsh
# Builds a MacHelper release and publishes it on GitHub.
#
#   scripts/release.sh build 0.2.0      test, build and package only (a trial run: no commit, no tag)
#   scripts/release.sh prepare 0.2.0    the same, then commit the version and tag v0.2.0 (local only)
#   scripts/release.sh publish 0.2.0    push main and the tag, create the GitHub release with the files
#
# prepare never pushes; publish only uploads what prepare built. Release notes come from the
# "## [0.2.0]" section of CHANGELOG.md, which must exist before prepare.
#
# Signing follows Config/Signing.xcconfig and the git-ignored Config/Local.xcconfig, like install.sh.
# Releases are not notarized (that needs a paid Developer ID), so people open the app once with
# System Settings → Privacy & Security → Open Anyway (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

XCODE_DEFAULT=/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer
if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_DEFAULT" ]]; then export DEVELOPER_DIR="$XCODE_DEFAULT"; fi

usage() { echo "usage: scripts/release.sh build|prepare|publish <version>   (e.g. prepare 0.2.0)"; exit 64; }
[[ $# -eq 2 ]] || usage
ACTION="$1"
VERSION="${2#v}"
TAG="v$VERSION"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]] || { echo "Not a version: $2 (use 1.2.3 or 1.2.3-beta.1)"; exit 64; }

OUT="build/release/$TAG"
DMG="$OUT/MacHelper-$VERSION.dmg"
ZIP="$OUT/MacHelper-$VERSION.zip"
NOTES="$OUT/notes.md"
SUMS="$OUT/SHA256SUMS.txt"

CASK="$OUT/machelper.rb"
REPO_URL="https://github.com/smile-minecraft/MacHelper"

fail() { echo "✗ $*" >&2; exit 1; }

# The Homebrew cask for this release, for a tap repository (homebrew-tap/Casks/machelper.rb).
write_cask() {
  cat <<CASK
cask "machelper" do
  version "$VERSION"
  sha256 "$1"

  url "$REPO_URL/releases/download/v#{version}/MacHelper-#{version}.dmg"
  name "MacHelper"
  desc "Menu bar system monitor, fan control and cleanup utility"
  homepage "$REPO_URL"

  depends_on macos: ">= :sonoma"

  app "MacHelper.app"
  binary "#{appdir}/MacHelper.app/Contents/MacOS/machelper-cli", target: "machelper"

  uninstall quit:      "com.machelper.MacHelper",
            launchctl: [
              "com.machelper.MacHelper.AutoClean",
              "com.machelper.MacHelper.MonitorAgent",
            ]

  zap trash: [
    "~/Library/Application Support/MacHelper",
    "~/Library/Caches/com.machelper.MacHelper",
    "~/Library/HTTPStorages/com.machelper.MacHelper",
    "~/Library/Logs/MacHelper",
    "~/Library/Preferences/com.machelper.MacHelper.plist",
    "~/Library/Saved Application State/com.machelper.MacHelper.savedState",
  ]
end
CASK
}

# The "## [x.y.z]" section of CHANGELOG.md, without its heading.
release_notes() {
  awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    on { print }
  ' CHANGELOG.md | sed -e '/./,$!d'
}

prepare() {
  if [[ "$ACTION" == prepare ]]; then
    [[ "$(git branch --show-current)" == main ]] || fail "Switch to main first."
    [[ -z "$(git status --porcelain)" ]] || fail "The working tree has uncommitted changes; commit or stash them first."
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "Tag $TAG already exists."
  fi
  [[ -n "$(release_notes)" ]] || fail "CHANGELOG.md has no \"## [$VERSION]\" section."

  # Put project.yml back as it was when the build fails, and after a trial build.
  typeset -g SAVED_PROJECT
  SAVED_PROJECT="$(mktemp)"
  cp project.yml "$SAVED_PROJECT"
  restore_version() { cp "$SAVED_PROJECT" project.yml; }
  [[ "$ACTION" == build ]] && trap restore_version EXIT
  echo "→ Setting version $VERSION"
  sed -i '' -E "s/^( *MARKETING_VERSION: )\"[^\"]*\"/\1\"$VERSION\"/" project.yml
  grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || fail "Couldn't set MARKETING_VERSION in project.yml."

  echo "→ Running tests"
  swift test --quiet > build/release-tests.log 2>&1 || { tail -30 build/release-tests.log; restore_version; fail "Tests failed (log: build/release-tests.log)."; }

  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
  echo "→ Building $VERSION ($BUILD_NUMBER)"
  rm -rf "$OUT"
  mkdir -p "$OUT"
  xcodegen generate --quiet
  local log="$OUT/xcodebuild.log"
  # A clean build in its own folder; no debugger entitlement (get-task-allow) in a shipped app.
  if ! xcodebuild -project MacHelper.xcodeproj -scheme MacHelper -configuration Release \
      -derivedDataPath build/release/DerivedData -allowProvisioningUpdates \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
      clean build > "$log" 2>&1; then
    grep -E "error:" "$log" | sort -u | head -30
    restore_version
    fail "Build failed (log: $log)."
  fi
  local app=build/release/DerivedData/Build/Products/Release/MacHelper.app

  echo "→ Checking the app"
  codesign --verify --deep --strict "$app" || fail "Signature check failed."
  [[ "$(defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)" == "$VERSION" ]] || fail "The app's version isn't $VERSION."
  if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "get-task-allow"; then fail "The app still has get-task-allow."; fi
  for exe in MacHelper MacHelperHelper machelper-cli; do
    [[ -x "$app/Contents/MacOS/$exe" ]] || fail "Missing $exe in the app."
  done
  [[ "$("$app/Contents/MacOS/machelper-cli" --version)" == "$VERSION ($BUILD_NUMBER)" ]] || fail "The bundled CLI doesn't report $VERSION ($BUILD_NUMBER)."
  local signer
  signer="$(codesign -dv --verbose=2 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  echo "  signed by: ${signer:-ad-hoc}"

  echo "→ Packaging"
  ditto -c -k --keepParent "$app" "$ZIP"
  local stage="$OUT/dmg"
  mkdir -p "$stage"
  ditto "$app" "$stage/MacHelper.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "MacHelper $VERSION" -srcfolder "$stage" -fs APFS -format UDZO "$DMG"
  rm -rf "$stage"
  (cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > "$(basename "$SUMS")")
  release_notes > "$NOTES"
  write_cask "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" > "$CASK"

  if [[ "$ACTION" == build ]]; then
    echo
    echo "Trial build: $OUT"
    ls -lh "$DMG" "$ZIP" | awk '{print "  " $5 "  " $NF}'
    return
  fi

  echo "→ Committing and tagging $TAG"
  if ! git diff --quiet project.yml; then
    git add project.yml
    git commit -q -m "chore(release): $TAG"
  fi
  git tag -a "$TAG" -m "MacHelper $VERSION"

  echo
  echo "Ready: $OUT"
  ls -lh "$DMG" "$ZIP" | awk '{print "  " $5 "  " $NF}'
  echo "Try the DMG, then publish with: scripts/release.sh publish $VERSION"
}

publish() {
  command -v gh >/dev/null || fail "GitHub CLI (gh) isn't installed: brew install gh"
  [[ -f "$DMG" && -f "$ZIP" && -f "$SUMS" && -f "$NOTES" && -f "$CASK" ]] || fail "No release files in $OUT; run prepare $VERSION first."
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Tag $TAG doesn't exist; run prepare $VERSION first."
  [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || fail "$TAG isn't the current commit; prepare again or check out the tag."
  (cd "$OUT" && shasum -a 256 -c "$(basename "$SUMS")" >/dev/null) || fail "The files changed since prepare."
  gh release view "$TAG" >/dev/null 2>&1 && fail "GitHub release $TAG already exists."

  local pre=()
  [[ "$VERSION" == 0.* || "$VERSION" == *-* ]] && pre=(--prerelease)
  echo "→ Pushing main and $TAG"
  git push origin main "$TAG"
  echo "→ Creating the GitHub release"
  gh release create "$TAG" "$DMG" "$ZIP" "$SUMS" --title "MacHelper $VERSION" --notes-file "$NOTES" --verify-tag "${pre[@]}"
  echo
  echo "Homebrew: copy $CASK to Casks/machelper.rb in your tap repository and push it."
}

case "$ACTION" in
  build|prepare) prepare ;;
  publish) publish ;;
  *) usage ;;
esac
