#!/bin/zsh
# Builds "Sezgir Island.app" into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Sezgir Island.app"
swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/SezgirIsland" "$APP/Contents/MacOS/SezgirIsland"
cp Bridge/run.pl "$APP/Contents/Resources/run.pl"
clang -fobjc-arc -dynamiclib -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -framework Foundation -framework AppKit Bridge/bridge.m -o "$APP/Contents/Resources/libbridge.dylib"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sezgir Island</string>
  <key>CFBundleDisplayName</key><string>Sezgir Island</string>
  <key>CFBundleIdentifier</key><string>kz.sezgir.island</string>
  <key>CFBundleExecutable</key><string>SezgirIsland</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>Чтобы показать время намаза для вашего населённого пункта.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Чтобы показать время намаза для вашего населённого пункта.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x SezgirIsland 2>/dev/null || true
  pkill -x DynamicIsland 2>/dev/null || true   # old name
  rm -rf "/Applications/Dynamic Island.app" "/Applications/Sezgir Island.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Sezgir Island.app"
fi
