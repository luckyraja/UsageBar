#!/bin/sh
# Builds UsageBar.app next to this script. Pass --install to copy it to /Applications.
set -e
cd "$(dirname "$0")"

APP=UsageBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"  # made with ~/.local/bin/make-app-icon

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/UsageBar"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.usagebar</string>
  <key>CFBundleName</key><string>UsageBar</string>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  mkdir -p /Applications
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/$APP"
fi
