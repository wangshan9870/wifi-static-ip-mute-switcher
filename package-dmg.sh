#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
app='build/Wi-Fi 固定 IP 与静音切换器.app'
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
staging=$(mktemp -d build/dmg-stage.XXXXXX)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"
cp README.md "$staging/README.md"
name="Wi-Fi-IP-Mute-Switcher-v${version}-macOS-universal.dmg"
hdiutil create -volname 'Wi-Fi IP Mute Switcher' -srcfolder "$staging" -format UDZO -ov "build/$name"
hdiutil verify "build/$name"
(cd build && shasum -a 256 "$name" > SHA256SUMS.txt)
echo "Packaged: $PWD/build/$name"
