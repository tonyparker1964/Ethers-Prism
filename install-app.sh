#!/bin/sh
# Builds Ethers Prism and puts "Ethers Prism.app" in your Applications folder,
# so you can open it from Launchpad, Spotlight or the Dock without Xcode.
# Run it again after pulling updates to install the new version.
set -e
cd "$(dirname "$0")"

echo "Building Ethers Prism (release). The first build takes a few minutes…"
swift build -c release --product EthersPrism
BIN="$(swift build -c release --show-bin-path)/EthersPrism"

STAGE="$(mktemp -d)"
APP="$STAGE/Ethers Prism.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EthersPrism"
cp Support/Info.plist "$APP/Contents/Info.plist"
ditto "$(dirname "$BIN")/EthersPrism_EthersPrism.bundle" "$APP/EthersPrism_EthersPrism.bundle"

# App icon: every size macOS asks for, made from Support/AppIcon.png.
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Support/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Support/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# A local signature so macOS runs it without complaint on this Mac.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

DEST="/Applications/Ethers Prism.app"
if pgrep -x EthersPrism >/dev/null; then
  echo "Closing the running Ethers Prism…"
  osascript -e 'quit app "Ethers Prism"' >/dev/null 2>&1 || pkill -x EthersPrism || true
  sleep 1
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
rm -rf "$STAGE"
touch "$DEST"

echo "Installed: $DEST"
open "$DEST"
