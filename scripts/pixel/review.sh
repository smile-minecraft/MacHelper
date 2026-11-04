#!/bin/zsh
# Renders every Design/Pixel grid with mc-asset into a scratch folder and makes review sheets.
set -e
cd "$(dirname "$0")/../.."
OUT=${1:-/tmp/machelper-pixel-review}
mkdir -p "$OUT"
python3 scripts/pixel/generate.py
for g in Design/Pixel/*.grid; do mc-asset render "$g" --output "$OUT/$(basename $g .grid).png" --force >/dev/null; done
swift scripts/pixel/sheet.swift "$OUT/icons.png" 8 light "$OUT"/px.{overview,monitor,fans,optimize,disk,uninstall,startup,settings}.png
swift scripts/pixel/sheet.swift "$OUT/art.png" 8 dark "$OUT"/AppIcon.png "$OUT"/px.mascot.png "$OUT"/px.empty.clean.png "$OUT"/px.empty.scan.png "$OUT"/px.empty.box.png
echo "$OUT"
