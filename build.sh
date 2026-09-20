#!/bin/bash
# Builds build/OctopusMenuBar.app (a menu-bar-only app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/OctopusMenuBar.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/OctopusMenuBar" *.swift

# Notifications take their icon from the bundle, so render the app icon into an .icns.
mkdir -p "$APP/Contents/Resources" build/AppIcon.iconset
"$APP/Contents/MacOS/OctopusMenuBar" --iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" || echo "warning: could not build AppIcon.icns; notifications will use a generic icon"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Octopus Menu Bar</string>
  <key>CFBundleIdentifier</key><string>com.ajw.OctopusMenuBar</string>
  <key>CFBundleExecutable</key><string>OctopusMenuBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
