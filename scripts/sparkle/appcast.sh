#!/bin/bash
# Generates a Sparkle appcast for one MacHelper release. Opt-in helper for
# scripts/release.sh; only `pages` pushes, and nothing here creates keys.
#
#   scripts/sparkle/appcast.sh check
#   scripts/sparkle/appcast.sh appcast <version>
#   scripts/sparkle/appcast.sh verify <appcast.xml>
#   scripts/sparkle/appcast.sh pages <version>     copy the appcast and notes to gh-pages and push
#
# Release notes: English comes from CHANGELOG.md (notes.md of the release); every other app
# language comes from docs/release-notes/<version>/<lang>.md and is linked with xml:lang, so
# Sparkle shows the notes in the language the app runs in.
#
# Sparkle tools are found by, in order:
#   1. $SPARKLE_BIN
#   2. build/Vendor/Sparkle/bin (scripts/sparkle/fetch.sh)
#   3. build/SourcePackages/artifacts/sparkle/Sparkle/bin (SPM artifacts)
#   4. bin
# Signing keys stay in the release machine's Keychain. This script never
# calls generate_keys and never writes private-key files.
set -euo pipefail
cd "$(dirname "$0")/../.."

REPO_URL="https://github.com/smile-minecraft/MacHelper"
PAGES_URL="https://smile-minecraft.github.io/MacHelper"
# App languages besides English; each needs docs/release-notes/<version>/<lang>.md.
NOTE_LANGS=(zh-Hant zh-Hans ja ko es)

die() { echo "✗ $*" >&2; exit 1; }

usage() {
  echo "usage: scripts/sparkle/appcast.sh check|appcast <version>|verify <appcast.xml>"
  exit 64
}

# Finds the directory holding the Sparkle tools and prints it.
find_sparkle_bin() {
  if [[ -n "${SPARKLE_BIN:-}" ]]; then
    printf '%s\n' "$SPARKLE_BIN"
  elif [[ -d "build/Vendor/Sparkle/bin" ]]; then
    printf '%s\n' "build/Vendor/Sparkle/bin"
  elif [[ -d "build/SourcePackages/artifacts/sparkle/Sparkle/bin" ]]; then
    printf '%s\n' "build/SourcePackages/artifacts/sparkle/Sparkle/bin"
  elif [[ -d "bin" ]]; then
    printf '%s\n' "bin"
  else
    return 1
  fi
}

# Resolves the tools directory into BIN_DIR and fails when any tool is missing.
resolve_sparkle_bin() {
  if ! BIN_DIR="$(find_sparkle_bin)"; then
    die "找不到 Sparkle 工具：SPARKLE_BIN 未設定，build/SourcePackages/artifacts/sparkle/Sparkle/bin 與 bin 也不存在。請先建置專案取得 SPM artifacts，或設定 SPARKLE_BIN。"
  fi
  local missing=0 tool
  for tool in generate_keys sign_update generate_appcast; do
    if [[ ! -x "$BIN_DIR/$tool" ]]; then
      echo "✗ 缺少 ${tool}（在 ${BIN_DIR}）" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Sparkle 工具不完整：generate_keys、sign_update、generate_appcast 三個都要存在。"
}

do_check() {
  resolve_sparkle_bin
  echo "Sparkle 工具路徑：$BIN_DIR"
  local tool
  for tool in generate_keys sign_update generate_appcast; do
    echo "  $tool: $BIN_DIR/$tool"
  done
  local version_line
  version_line="$("$BIN_DIR/generate_appcast" --help 2>&1 | grep -m 1 . || true)"
  echo "版本：$version_line"
  echo "檢查通過：三個 Sparkle 工具都存在。"
}

do_appcast() {
  [[ $# -eq 1 ]] || usage
  local version="${1#v}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "版本格式不對：${1}（請用 1.2.3 或 1.2.3-beta.1）"
  resolve_sparkle_bin

  local rel="build/release/v$version"
  local dmg="$rel/MacHelper-$version.dmg"
  local zip="$rel/MacHelper-$version.zip"
  local notes="$rel/notes.md"
  local sums=""
  [[ -f "$dmg" ]] || die "找不到 DMG：${dmg}（請先跑 scripts/release.sh prepare ${version}）"
  [[ -f "$zip" ]] || die "找不到 ZIP：${zip}（請先跑 scripts/release.sh prepare ${version}）"
  [[ -f "$notes" ]] || die "找不到 release notes：$notes"
  local lang
  for lang in "${NOTE_LANGS[@]}"; do
    [[ -s "docs/release-notes/$version/$lang.md" ]] || die "缺少 ${lang} 的更新說明：docs/release-notes/$version/$lang.md"
  done
  if [[ -f "$rel/SHA256SUMS.txt" ]]; then
    sums="$rel/SHA256SUMS.txt"
  elif [[ -f "$rel/SHA256SUMS" ]]; then
    sums="$rel/SHA256SUMS"
  else
    die "找不到 SHA256SUMS：$rel/SHA256SUMS.txt 或 $rel/SHA256SUMS"
  fi

  (cd "$rel" && shasum -a 256 -c "$(basename "$sums")") \
    || die "SHA256SUMS 驗證失敗，檔案在 prepare 之後改過了：$rel"

  local stage="build/appcast/v$version"
  local output="$stage/appcast.xml"
  # Rebuild the staging folder from scratch so a previous run cannot leave stale archives.
  case "$stage" in
    build/appcast/v*) rm -rf "$stage" ;;
    *) die "拒絕清理不在預期位置的路徑：$stage" ;;
  esac
  mkdir -p "$stage"
  # Sparkle accepts one archive per bundle version. Use the zip for the appcast;
  # the DMG stays in the GitHub release for a normal first install.
  cp "$zip" "$stage/"
  # Sparkle only picks up notes named like the archive; notes.md alone is ignored.
  local zip_base
  zip_base="$(basename "$zip" .zip)"
  cp "$notes" "$stage/$zip_base.md"

  local prefix="$REPO_URL/releases/download/v$version/"
  echo "→ 用 $(basename "$BIN_DIR")/generate_appcast 產生 appcast（下載 URL 前綴：${prefix}）"
  if ! "$BIN_DIR/generate_appcast" --download-url-prefix "$prefix" -o "$output" "$stage"; then
    die "generate_appcast 失敗；staging 留在 ${stage}，確認簽章金鑰（Keychain 帳號 ed25519）後重跑。"
  fi
  [[ -f "$output" ]] || die "generate_appcast 沒產生預期的 appcast：$output"
  command -v xmllint >/dev/null 2>&1 \
    || die "找不到 xmllint，無法驗證 appcast 是否合法：$output"
  xmllint --noout "$output" || die "產生的 appcast 不是合法 XML：$output"

  # One release-notes link per language next to the English default.
  local localized=""
  for lang in "${NOTE_LANGS[@]}"; do
    cp "docs/release-notes/$version/$lang.md" "$stage/$zip_base.$lang.md"
    localized+="            <sparkle:releaseNotesLink xml:lang=\"$lang\">$PAGES_URL/$zip_base.$lang.md</sparkle:releaseNotesLink>"$'\n'
  done
  LOCALIZED="$localized" perl -0pi -e 's{(\s*<sparkle:releaseNotesLink>[^<]*</sparkle:releaseNotesLink>\n)}{$1$ENV{LOCALIZED}}' "$output"
  [[ "$(grep -c 'xml:lang=' "$output")" -eq "${#NOTE_LANGS[@]}" ]] || die "無法在 appcast 加入各語言的更新說明連結：$output"
  xmllint --noout "$output" || die "加入語言連結後的 appcast 不是合法 XML：$output"
  echo "appcast 已產生：$output"
  echo "appcast 已準備好，下一步手動檢查與推送（此腳本不會自動 push appcast 或 gh-pages）"
}

# Copies the appcast and every release-notes file to the gh-pages worktree, commits and pushes.
do_pages() {
  [[ $# -eq 1 ]] || usage
  local version="${1#v}"
  local stage="build/appcast/v$version"
  [[ -f "$stage/appcast.xml" ]] || die "找不到 $stage/appcast.xml，請先跑 appcast $version"
  do_verify "$stage/appcast.xml"
  local pages="build/gh-pages-worktree"
  if [[ ! -d "$pages/.git" && ! -f "$pages/.git" ]]; then
    git fetch -q origin gh-pages
    git worktree add -q "$pages" gh-pages
  fi
  [[ -z "$(git -C "$pages" status --porcelain)" ]] || die "$pages 有未提交的變更"
  git -C "$pages" pull -q --ff-only
  cp "$stage/appcast.xml" "$stage"/*.md "$pages/"
  (cd "$pages" && git add appcast.xml ./*.md)
  git -C "$pages" commit -q -m "docs: publish appcast for $version"
  git -C "$pages" push -q origin HEAD
  echo "✓ appcast 已推送到 gh-pages：$PAGES_URL/appcast.xml"
}

do_verify() {
  [[ $# -eq 1 ]] || usage
  local file="$1"
  [[ -f "$file" ]] || die "找不到 appcast 檔案：$file"
  command -v xmllint >/dev/null 2>&1 \
    || die "找不到 xmllint，無法驗證 appcast 是否合法：$file"
  xmllint --noout "$file" || die "不是合法 XML：$file"
  local enclosures
  enclosures="$(xmllint --format "$file" | grep -o '<enclosure[^>]*>' || true)"
  [[ -n "$enclosures" ]] || die "appcast 沒有任何 <enclosure>：$file"
  local failed=0 line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      *'sparkle:edSignature="'*) ;;
      *) echo "✗ enclosure 缺少 sparkle:edSignature：$line" >&2; failed=1 ;;
    esac
    case "$line" in
      *'length="'*) ;;
      *) echo "✗ enclosure 缺少 length：$line" >&2; failed=1 ;;
    esac
    case "$line" in
      *'url="'*) ;;
      *) echo "✗ enclosure 缺少 url：$line" >&2; failed=1 ;;
    esac
  done <<< "$enclosures"
  [[ "$failed" -eq 0 ]] || die "appcast 驗證失敗：$file"
  echo "✓ appcast 驗證通過：$file"
}

[[ $# -ge 1 ]] || usage
CMD="$1"; shift
case "$CMD" in
  check) do_check ;;
  appcast) do_appcast "$@" ;;
  verify) do_verify "$@" ;;
  pages) do_pages "$@" ;;
  *) usage ;;
esac
