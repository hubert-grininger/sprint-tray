#!/bin/bash
# Builds SprintTray.app and SprintTray.dmg. Run on macOS 13+ with Xcode Command Line Tools
# (install with: xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SprintTray.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

# Universal binary (Apple Silicon + Intel)
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13.0" Sources/main.swift -o "build/SprintTray-$arch"
done
lipo -create build/SprintTray-arm64 build/SprintTray-x86_64 -output "$APP/Contents/MacOS/SprintTray"
rm build/SprintTray-arm64 build/SprintTray-x86_64
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature (required to run on Apple Silicon; not notarized)
codesign --force --deep --sign - "$APP"

# DMG with the app, an Applications shortcut and the README
STAGE=build/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp README.md "$STAGE/README.md"
hdiutil create -volname SprintTray -srcfolder "$STAGE" -ov -format UDZO build/SprintTray.dmg
rm -rf "$STAGE"

echo "Done: $(pwd)/build/SprintTray.dmg"
