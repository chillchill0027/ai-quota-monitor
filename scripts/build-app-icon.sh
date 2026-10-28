#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep the selected artwork intact; resize only to the standard macOS icon sizes.
icon_dir="$(mktemp -d)"
trap 'rm -rf "$icon_dir"' EXIT
iconset="$icon_dir/AppIcon.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" Resources/AppIcon.png \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o Resources/AppIcon.icns
