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
# Releases are signed with the "Developer ID Application" certificate in the login keychain and
# notarized by Apple, so they open without a Gatekeeper warning. One-time setup:
#   1. Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#   2. xcrun notarytool store-credentials machelper-notary --apple-id <Apple ID> --team-id <team>
#      (with an app-specific password from account.apple.com)
# NOTARY_PROFILE picks another keychain profile; NOTARIZE=0 skips notarization for a trial build.
# SPARKLE_APPCAST=1 additionally runs scripts/sparkle/appcast.sh after prepare succeeds;
# by default it does nothing, and the appcast is never pushed automatically.
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

NOTARY_PROFILE="${NOTARY_PROFILE:-machelper-notary}"
NOTARIZE="${NOTARIZE:-1}"

fail() { echo "✗ $*" >&2; exit 1; }

# The Developer ID Application identity and its team, from the login keychain.
signing_identity() {
  local identities
  identities="$(security find-identity -v -p codesigning)"
  SIGN_IDENTITY="$(sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' <<< "$identities" | sed -n '1p')"
  [[ -n "$SIGN_IDENTITY" ]] || fail "No Developer ID Application certificate in the keychain (Xcode → Settings → Accounts → Manage Certificates)."
  SIGN_TEAM="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<< "$SIGN_IDENTITY")"
  [[ -n "$SIGN_TEAM" ]] || fail "Couldn't read the team ID from \"$SIGN_IDENTITY\"."
}

# Sends a file to Apple's notary service, waits for the verdict and prints the log when rejected.
notarize() {
  local file="$1" result="$OUT/notary-$(basename "$1").json"
  echo "  notarizing $(basename "$file") (usually a few minutes)"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result" \
    || { cat "$result" 2>/dev/null; fail "notarytool failed; check the keychain profile \"$NOTARY_PROFILE\"."; }
  local verdict id
  verdict="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  if [[ "$verdict" != Accepted ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    fail "Notarization of $(basename "$file") ended with: ${verdict:-unknown}."
  fi
}

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

  depends_on macos: :sonoma

  app "MacHelper.app"
  binary "#{appdir}/MacHelper.app/Contents/MacOS/machelper-cli", target: "machelper"

  uninstall launchctl: [
              "com.machelper.MacHelper.AutoClean",
              "com.machelper.MacHelper.MonitorAgent",
            ],
            quit:      "com.machelper.MacHelper"

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

# Puts this release's cask into the Homebrew tap (smile-minecraft/homebrew-tap) and pushes it.
# Uses the tapped checkout, or TAP_DIR for another clone.
update_tap() {
  local tap="${TAP_DIR:-$(brew --repository smile-minecraft/tap 2>/dev/null || true)}"
  if [[ -z "$tap" || ! -d "$tap/.git" ]]; then
    echo "Homebrew tap not found; run \`brew tap smile-minecraft/tap\` and then copy $CASK to Casks/machelper.rb there."
    return
  fi
  echo "→ Updating the Homebrew tap"
  [[ -z "$(git -C "$tap" status --porcelain)" ]] || { echo "  $tap has uncommitted changes; copy $CASK by hand."; return; }
  git -C "$tap" pull -q --ff-only
  mkdir -p "$tap/Casks"
  cp "$CASK" "$tap/Casks/machelper.rb"
  if ! grep -q "machelper" "$tap/README.md" 2>/dev/null; then
    cat >> "$tap/README.md" <<'TAPREADME'

## MacHelper

A menu bar system monitor, fan control and cleanup utility for macOS 14 and later.

```sh
brew install --cask smile-minecraft/tap/machelper
```
TAPREADME
  fi
  # Releases are notarized now; drop the old "open it once, then Open Anyway" line.
  sed -i '' '/isn.t notarized yet/d' "$tap/README.md"
  HOMEBREW_NO_AUTO_UPDATE=1 brew style --cask smile-minecraft/tap/machelper >/dev/null 2>&1 || echo "  brew style reported problems: brew style --cask smile-minecraft/tap/machelper"
  git -C "$tap" add Casks/machelper.rb README.md
  git -C "$tap" commit -q -m "chore: pin machelper to the $TAG release asset"
  git -C "$tap" push -q origin HEAD
  echo "  brew install --cask smile-minecraft/tap/machelper now installs $VERSION"
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

  signing_identity
  echo "  signing as: $SIGN_IDENTITY"
  if [[ "$NOTARIZE" == 1 ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
      || fail "No notary credentials under \"$NOTARY_PROFILE\": xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $SIGN_TEAM"
  elif [[ "$ACTION" != build ]]; then
    fail "NOTARIZE=0 is only for trial builds."
  fi

  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
  echo "→ Building $VERSION ($BUILD_NUMBER)"
  rm -rf "$OUT"
  mkdir -p "$OUT"
  scripts/sparkle/fetch.sh
  xcodegen generate --quiet
  local log="$OUT/xcodebuild.log"
  # A clean build in its own folder, signed with Developer ID and a secure timestamp (both needed
  # for notarization); no debugger entitlement (get-task-allow) in a shipped app.
  if ! xcodebuild -project MacHelper.xcodeproj -scheme MacHelper -configuration Release \
      -derivedDataPath build/release/DerivedData \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$SIGN_TEAM" \
      PROVISIONING_PROFILE_SPECIFIER="" OTHER_CODE_SIGN_FLAGS="--timestamp" \
      clean build > "$log" 2>&1; then
    grep -E "error:" "$log" | sort -u | sed -n '1,30p'
    restore_version
    fail "Build failed (log: $log)."
  fi
  local app=build/release/DerivedData/Build/Products/Release/MacHelper.app

  echo "→ Checking the app"
  codesign --verify --deep --strict "$app" || fail "Signature check failed."
  [[ "$(defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)" == "$VERSION" ]] || fail "The app's version isn't $VERSION."
  local entitlements target
  for target in "$app" "$app/Contents/MacOS/MacHelperHelper" "$app/Contents/MacOS/machelper-cli"; do
    entitlements="$(codesign -d --entitlements - --xml "$target" 2>/dev/null || true)"
    if grep -q "get-task-allow" <<< "$entitlements"; then fail "$(basename "$target") still has get-task-allow."; fi
  done
  for exe in MacHelper MacHelperHelper machelper-cli; do
    [[ -x "$app/Contents/MacOS/$exe" ]] || fail "Missing $exe in the app."
  done
  [[ "$("$app/Contents/MacOS/machelper-cli" --version)" == "$VERSION ($BUILD_NUMBER)" ]] || fail "The bundled CLI doesn't report $VERSION ($BUILD_NUMBER)."
  local exe_path signer info gatekeeper
  for exe_path in "$app" "$app/Contents/MacOS/MacHelperHelper" "$app/Contents/MacOS/machelper-cli"; do
    info="$(codesign -dv --verbose=2 "$exe_path" 2>&1)"
    signer="$(sed -n 's/^Authority=//p' <<< "$info" | sed -n '1p')"
    [[ "$signer" == "$SIGN_IDENTITY" ]] || fail "$(basename "$exe_path") is signed by \"${signer:-ad-hoc}\", not $SIGN_IDENTITY."
    info="$(codesign -dv "$exe_path" 2>&1)"
    grep -q "flags=.*runtime" <<< "$info" || fail "$(basename "$exe_path") lacks the hardened runtime."
    grep -q "^Timestamp=" <<< "$info" || fail "$(basename "$exe_path") has no secure timestamp."
  done

  if [[ "$NOTARIZE" == 1 ]]; then
    echo "→ Notarizing the app"
    local upload="$OUT/notarize-app.zip"
    ditto -c -k --keepParent "$app" "$upload"
    notarize "$upload"
    rm -f "$upload"
    xcrun stapler staple -q "$app" || fail "Couldn't staple the app."
    gatekeeper="$(spctl -a -t exec -vv "$app" 2>&1)" || fail "Gatekeeper doesn't accept the app."
    grep -q "Notarized Developer ID" <<< "$gatekeeper" || fail "Gatekeeper doesn't accept the app."
  fi

  echo "→ Packaging"
  ditto -c -k --keepParent "$app" "$ZIP"
  local stage="$OUT/dmg"
  mkdir -p "$stage"
  ditto "$app" "$stage/MacHelper.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "MacHelper $VERSION" -srcfolder "$stage" -fs APFS -format UDZO "$DMG"
  rm -rf "$stage"
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG" || fail "Couldn't sign the DMG."
  if [[ "$NOTARIZE" == 1 ]]; then
    echo "→ Notarizing the DMG"
    notarize "$DMG"
    xcrun stapler staple -q "$DMG" || fail "Couldn't staple the DMG."
    gatekeeper="$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1)" \
      || fail "Gatekeeper doesn't accept the DMG."
    grep -q "Notarized Developer ID" <<< "$gatekeeper" || fail "Gatekeeper doesn't accept the DMG."
  fi
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

  if [[ "${SPARKLE_APPCAST:-}" == "1" ]]; then
    echo
    echo "→ Generating the Sparkle appcast"
    scripts/sparkle/appcast.sh appcast "$VERSION"
    echo
    echo "appcast 已準備好，下一步手動檢查與推送"
  fi
}

publish() {
  command -v gh >/dev/null || fail "GitHub CLI (gh) isn't installed: brew install gh"
  [[ -f "$DMG" && -f "$ZIP" && -f "$SUMS" && -f "$NOTES" && -f "$CASK" ]] || fail "No release files in $OUT; run prepare $VERSION first."
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Tag $TAG doesn't exist; run prepare $VERSION first."
  [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || fail "$TAG isn't the current commit; prepare again or check out the tag."
  (cd "$OUT" && shasum -a 256 -c "$(basename "$SUMS")" >/dev/null) || fail "The files changed since prepare."
  gh release view "$TAG" >/dev/null 2>&1 && fail "GitHub release $TAG already exists."

  echo "→ Pushing main and $TAG"
  git push origin main "$TAG"
  echo "→ Creating the GitHub release"
  # Every MacHelper release is a stable release; never mark a 0.x or beta version as prerelease.
  gh release create "$TAG" "$DMG" "$ZIP" "$SUMS" --title "MacHelper $VERSION" --notes-file "$NOTES" --verify-tag
  update_tap
}

case "$ACTION" in
  build|prepare) prepare ;;
  publish) publish ;;
  *) usage ;;
esac
