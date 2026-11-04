#!/bin/zsh
# Renders Design/Pixel/*.grid with mc-asset into App/Resources/Assets.xcassets:
#   px.<name>   16×16 icons  → imagesets at 1×/2×/3× (16, 32, 48 px), pixel-exact upscales
#   px.<art>    32×32 art    → imagesets at 1×/2×/3× of 64 pt (64, 128, 192 px)
#   AppIcon     32×32        → AppIcon.appiconset (16 … 1024 px; 16 px via pixel-aware downscale)
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/pixel/generate.py >/dev/null
CAT=App/Resources/Assets.xcassets
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$CAT"
[[ -f "$CAT/Contents.json" ]] || echo '{"info":{"author":"xcode","version":1}}' > "$CAT/Contents.json"

imageset() {  # name base_png base_scale(px per pt at 1x)
  local name=$1 src=$2 base=$3 dir="$CAT/$1.imageset"
  rm -rf "$dir"; mkdir -p "$dir"
  local images=""
  for s in 1 2 3; do
    local f="$name@${s}x.png"
    mc-asset preview "$src" --scale $((base * s)) --output "$dir/$f" --force >/dev/null
    images+="{\"idiom\":\"universal\",\"filename\":\"$f\",\"scale\":\"${s}x\"},"
  done
  echo "{\"images\":[${images%,}],\"info\":{\"author\":\"xcode\",\"version\":1},\"properties\":{\"preserves-vector-representation\":false,\"template-rendering-intent\":\"original\"}}" > "$dir/Contents.json"
}

for g in Design/Pixel/*.grid; do
  name=$(basename "$g" .grid)
  mc-asset render "$g" --output "$TMP/$name.png" --force >/dev/null
  case $name in
    AppIcon) ;;
    px.mascot|px.empty.*) imageset "$name" "$TMP/$name.png" 2 ;;
    *) imageset "$name" "$TMP/$name.png" 1 ;;
  esac
done

# App icon.
ICON="$CAT/AppIcon.appiconset"
rm -rf "$ICON"; mkdir -p "$ICON"
mc-asset transform "$TMP/AppIcon.png" --resize 16x16 --resize-mode pixel-aware --output "$ICON/icon_16.png" --force >/dev/null
for px in 32 64 128 256 512 1024; do
  mc-asset preview "$TMP/AppIcon.png" --scale $((px / 32)) --output "$ICON/icon_$px.png" --force >/dev/null
done
cat > "$ICON/Contents.json" <<JSON
{"images":[
 {"idiom":"mac","size":"16x16","scale":"1x","filename":"icon_16.png"},
 {"idiom":"mac","size":"16x16","scale":"2x","filename":"icon_32.png"},
 {"idiom":"mac","size":"32x32","scale":"1x","filename":"icon_32.png"},
 {"idiom":"mac","size":"32x32","scale":"2x","filename":"icon_64.png"},
 {"idiom":"mac","size":"128x128","scale":"1x","filename":"icon_128.png"},
 {"idiom":"mac","size":"128x128","scale":"2x","filename":"icon_256.png"},
 {"idiom":"mac","size":"256x256","scale":"1x","filename":"icon_256.png"},
 {"idiom":"mac","size":"256x256","scale":"2x","filename":"icon_512.png"},
 {"idiom":"mac","size":"512x512","scale":"1x","filename":"icon_512.png"},
 {"idiom":"mac","size":"512x512","scale":"2x","filename":"icon_1024.png"}
],"info":{"author":"xcode","version":1}}
JSON
echo "assets -> $CAT"
