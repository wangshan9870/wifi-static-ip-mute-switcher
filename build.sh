#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app='build/Wi-Fi 固定 IP 与静音切换器.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" \
    Sources/Policy.swift Sources/NetworkMonitor.swift Sources/UpdateChecker.swift Sources/SpeakerAudio.swift Sources/SettingsUI.swift Sources/main.swift \
    -o "build/HomeIP-$arch" \
    -framework AppKit -framework SystemConfiguration -framework ServiceManagement -framework CoreAudio
done
lipo -create build/HomeIP-arm64 build/HomeIP-x86_64 -output "$app/Contents/MacOS/HomeIP"
rm build/HomeIP-arm64 build/HomeIP-x86_64
cp Resources/* "$app/Contents/Resources/"
iconset=$(mktemp -d build/AppIcon.XXXXXX)
mv "$iconset" "$iconset.iconset"
iconset="$iconset.iconset"
trap 'rm -rf "$iconset"' EXIT
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/app-icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" assets/app-icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HomeIP</string>
<key>CFBundleIdentifier</key><string>cn.wangshan.home-ip</string>
<key>CFBundleName</key><string>Wi-Fi IP Mute</string>
<key>CFBundleDisplayName</key><string>Wi-Fi 固定 IP 与静音切换器</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>1.5.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
plutil -lint "$app/Contents/Info.plist"
echo "Built: $PWD/$app"
