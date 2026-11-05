#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
app=".build/Click Bridge.app"

iconset=".build/ClickBridge.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
swiftc Sources/ClickBridge/BikeGlyph.swift scripts/RenderAppIcon.swift -o .build/render-app-icon
.build/render-app-icon "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/ClickBridge.icns"
cp Info.plist "$app/Contents/Info.plist"
cp "$bin_dir/ClickBridge" "$app/Contents/MacOS/ClickBridge"
codesign --force --sign "${CLICK_BRIDGE_SIGN_IDENTITY:--}" "$app"
# Finder uses the bundle timestamp to notice changes to the icon and Info.plist.
touch "$app"
printf 'Built %s\n' "$app"
