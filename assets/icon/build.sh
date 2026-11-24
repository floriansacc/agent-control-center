#!/bin/sh
# Regenerates the app icon from AppIcon.svg: AppIcon-1024.png, AppIcon.iconset, AppIcon.icns and the compiled
# asset catalog (compiled/Assets.car). install.sh copies AppIcon.icns and Assets.car into the app bundle.
#
# Needs macOS's qlmanage (renders the SVG), sips, iconutil and, for the asset catalog, Xcode's actool.
# The artwork must be full bleed (fill the 1024 canvas): macOS applies the rounded mask itself.
set -eu
cd "$(dirname "$0")"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/appicon.XXXXXX")
qlmanage -t -s 1024 -o "$tmp" AppIcon.svg >/dev/null 2>&1
cp "$tmp/AppIcon.svg.png" AppIcon-1024.png

mkdir -p AppIcon.iconset AppIcon.xcassets/AppIcon.appiconset compiled
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" AppIcon-1024.png --out "AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" AppIcon-1024.png --out "AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns

cp AppIcon.iconset/*.png AppIcon.xcassets/AppIcon.appiconset/
cat > AppIcon.xcassets/Contents.json <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
{
  printf '{\n  "images" : [\n'
  first=1
  for size in 16 32 128 256 512; do
    for scale in 1 2; do
      suffix=$([ "$scale" = 2 ] && echo "@2x" || echo "")
      [ $first = 1 ] || printf ',\n'
      first=0
      printf '    { "idiom" : "mac", "size" : "%sx%s", "scale" : "%sx", "filename" : "icon_%sx%s%s.png" }' \
        "$size" "$size" "$scale" "$size" "$size" "$suffix"
    done
  done
  printf '\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n'
} > AppIcon.xcassets/AppIcon.appiconset/Contents.json

if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool AppIcon.xcassets --compile compiled --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$tmp/partial.plist" >/dev/null
  echo "Built AppIcon.icns and compiled/Assets.car"
else
  echo "Built AppIcon.icns (actool not found: install Xcode to rebuild compiled/Assets.car)"
fi
