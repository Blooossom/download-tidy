#!/bin/zsh
set -eu
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift scripts/build-icon.swift assets/icon-1024.png
mkdir -p assets/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/icon-1024.png --out "assets/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/icon-1024.png --out "assets/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
