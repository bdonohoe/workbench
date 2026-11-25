#!/bin/sh
# Renders a preview of every app icon for the icon pickers on the Mac and the
# iPhone, and for the iPhone welcome, which shows one at 120 points. Run it
# again after changing any .icon file.
set -e
cd "$(dirname "$0")/.."

ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
OUT=BenchKit/Sources/BenchKit/Resources/IconPreviews
mkdir -p "$OUT"

render() {
    "$ICTOOL" "$1" --export-image --output-file "$OUT/$2.png" \
        --platform iOS --rendition Default --width 128 --height 128 --scale 3 > /dev/null
    # ictool writes 16-bit PNGs; 8 bits per channel is plenty for a preview.
    magick "$OUT/$2.png" -strip -depth 8 -define png:compression-level=9 "$OUT/$2.png"
    echo "$OUT/$2.png"
}

render bench-icon.icon bench-icon
for icon in AppIcons/*.icon; do
    render "$icon" "$(basename "$icon" .icon)"
done
