#!/usr/bin/env bash
#
# make-icons.sh, regenerate every app-icon asset for macOS / iOS / tvOS from a
# single 1024+ square master, using only `sips` (ships with macOS, no installs).
#
#   Master:  assets/GMPlayerIcon.png   (square, sRGB, no alpha, 1024x1024 or larger)
#   Output:  Resources/{macOS,iOS,tvOS}/Assets.xcassets/...
#
# Run via `make icons`. Idempotent: it wipes and rebuilds the three catalogs.
#
# macOS / iOS use the modern flow (full mac set; single-size 1024 for iOS).
# tvOS needs rectangular, layered Brand Assets; we cover-crop the square master
# to each rect size (the icon's built-in padding is what gets trimmed, so the
# subject stays centered and full-bleed). Single content layer per image stack
#, valid and builds clean. Drop in separated Front/Back layers later if you
# want real parallax depth.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/assets/GMPlayerIcon.png"
RES="$ROOT/Resources"

[ -f "$MASTER" ] || { echo "error: master not found: $MASTER" >&2; exit 1; }

# sips resample (square, exact size, master is square so no distortion)
sq() { # sq <size> <out>
  sips -s format png "$MASTER" -z "$1" "$1" --out "$2" >/dev/null
}
# cover-crop to W x H (scale to width, center-crop height). For wide targets W>H.
cover() { # cover <W> <H> <out>
  sips -s format png "$MASTER" --resampleWidth "$1" --cropToHeightWidth "$2" "$1" --out "$3" >/dev/null
}

# A reusable fully-transparent PNG seed (1x1), resized per-call. sips keeps alpha.
TRANSPARENT_SEED="$(mktemp -t transp).png"
base64 --decode > "$TRANSPARENT_SEED" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=
B64
clear_png() { # clear_png <W> <H> <out> , transparent image of the given size
  sips -s format png "$TRANSPARENT_SEED" -z "$2" "$1" --out "$3" >/dev/null
}
trap 'rm -f "$TRANSPARENT_SEED"' EXIT

CATALOG_INFO='  "info" : { "author" : "xcode", "version" : 1 }'

# ---------------------------------------------------------------- reset
rm -rf "$RES/macOS/Assets.xcassets" "$RES/iOS/Assets.xcassets" "$RES/tvOS/Assets.xcassets"
mkdir -p "$RES/macOS/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$RES/iOS/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$RES/tvOS/Assets.xcassets"

for p in macOS iOS tvOS; do
  printf '{\n%s\n}\n' "$CATALOG_INFO" > "$RES/$p/Assets.xcassets/Contents.json"
done

# ================================================================ iOS
# Single-size: one 1024 image, the system derives the rest at build time.
echo "iOS  → AppIcon (single size 1024)"
IOS="$RES/iOS/Assets.xcassets/AppIcon.appiconset"
sq 1024 "$IOS/icon-1024.png"
cat > "$IOS/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
$CATALOG_INFO
}
JSON

# ================================================================ macOS
echo "mac  → AppIcon (16…1024)"
MAC="$RES/macOS/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 64 128 256 512 1024; do sq "$s" "$MAC/mac_$s.png"; done
cat > "$MAC/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "mac_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "mac_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "mac_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "mac_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "mac_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "mac_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "mac_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "mac_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "mac_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "mac_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
$CATALOG_INFO
}
JSON

# ================================================================ tvOS
echo "tvOS → Brand Assets (App Icon + Top Shelf)"
TV="$RES/tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
mkdir -p "$TV"

# tvOS image stacks need >= 2 layers (that's the parallax depth). We emit a
# transparent Front layer over the art Back layer: builds + validates, gives a
# subtle depth pop on focus. Swap the Front PNGs for a cut-out of the subject
# later to get real parallax separation.
#
# layers are listed front-to-back in Contents.json.

# stack_1x <stackdir> <w> <h>            (App Store icon: one scale)
stack_1x() {
  local dir="$1" w="$2" h="$3"
  local front="$dir/Front.imagestacklayer" back="$dir/Back.imagestacklayer"
  mkdir -p "$front/Content.imageset" "$back/Content.imageset"
  cat > "$dir/Contents.json" <<JSON
{
$CATALOG_INFO,
  "layers" : [
    { "filename" : "Front.imagestacklayer" },
    { "filename" : "Back.imagestacklayer" }
  ]
}
JSON
  printf '{\n%s\n}\n' "$CATALOG_INFO" > "$front/Contents.json"
  printf '{\n%s\n}\n' "$CATALOG_INFO" > "$back/Contents.json"
  clear_png "$w" "$h" "$front/Content.imageset/icon.png"
  cover     "$w" "$h" "$back/Content.imageset/icon.png"
  for L in "$front" "$back"; do
    cat > "$L/Content.imageset/Contents.json" <<JSON
{
  "images" : [ { "filename" : "icon.png", "idiom" : "tv", "scale" : "1x" } ],
$CATALOG_INFO
}
JSON
  done
}
# stack_2x <stackdir> <w1> <h1> <w2> <h2>   (Home icon: 1x + 2x)
stack_2x() {
  local dir="$1" w1="$2" h1="$3" w2="$4" h2="$5"
  local front="$dir/Front.imagestacklayer" back="$dir/Back.imagestacklayer"
  mkdir -p "$front/Content.imageset" "$back/Content.imageset"
  cat > "$dir/Contents.json" <<JSON
{
$CATALOG_INFO,
  "layers" : [
    { "filename" : "Front.imagestacklayer" },
    { "filename" : "Back.imagestacklayer" }
  ]
}
JSON
  printf '{\n%s\n}\n' "$CATALOG_INFO" > "$front/Contents.json"
  printf '{\n%s\n}\n' "$CATALOG_INFO" > "$back/Contents.json"
  clear_png "$w1" "$h1" "$front/Content.imageset/icon-1x.png"
  clear_png "$w2" "$h2" "$front/Content.imageset/icon-2x.png"
  cover     "$w1" "$h1" "$back/Content.imageset/icon-1x.png"
  cover     "$w2" "$h2" "$back/Content.imageset/icon-2x.png"
  for L in "$front" "$back"; do
    cat > "$L/Content.imageset/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "icon-1x.png", "idiom" : "tv", "scale" : "1x" },
    { "filename" : "icon-2x.png", "idiom" : "tv", "scale" : "2x" }
  ],
$CATALOG_INFO
}
JSON
  done
}
# top-shelf imageset <dir> <w1> <h1> <w2> <h2>
topshelf() {
  local dir="$1"; mkdir -p "$dir"
  cover "$2" "$3" "$dir/ts-1x.png"
  cover "$4" "$5" "$dir/ts-2x.png"
  cat > "$dir/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "ts-1x.png", "idiom" : "tv", "scale" : "1x" },
    { "filename" : "ts-2x.png", "idiom" : "tv", "scale" : "2x" }
  ],
$CATALOG_INFO
}
JSON
}

stack_1x "$TV/App Icon - App Store.imagestack" 1280 768
stack_2x "$TV/App Icon.imagestack"             400 240 800 480
topshelf "$TV/Top Shelf Image.imageset"        1920 720 3840 1440
topshelf "$TV/Top Shelf Image Wide.imageset"   2320 720 4640 1440

cat > "$TV/Contents.json" <<JSON
{
  "assets" : [
    { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
    { "filename" : "App Icon.imagestack",             "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
    { "filename" : "Top Shelf Image Wide.imageset",   "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" },
    { "filename" : "Top Shelf Image.imageset",        "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" }
  ],
$CATALOG_INFO
}
JSON

echo "done. icons written under Resources/{macOS,iOS,tvOS}/Assets.xcassets"
