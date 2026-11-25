#!/bin/sh
# Builds Ghost.app into build/. Add --install to copy it into /Applications and open it.
set -e
cd "$(dirname "$0")"
APP="build/Ghost.app"
VERSION="1.0"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos14.0 main.swift -o "$APP/Contents/MacOS/Ghost"

# App icon from icon/icon-1024.png
ICONSET=build/AppIcon.iconset && mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon-1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon/icon-1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns" && rm -rf $ICONSET

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Ghost</string>
  <key>CFBundleIdentifier</key><string>io.github.o1ie12.ghost</string>
  <key>CFBundleExecutable</key><string>Ghost</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  pkill -f "/Applications/Ghost.app/Contents/MacOS/Ghost" 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Ghost.app
  cp -R "$APP" /Applications/
  open /Applications/Ghost.app
  echo "Installed /Applications/Ghost.app"
fi
