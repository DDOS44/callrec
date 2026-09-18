#!/usr/bin/env bash
# Builds callrec.app from the SwiftPM binaries. Works with Command Line Tools
# only - no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
OUT=${OUT:-build}
# Assemble in a scratch directory: if the repo lives in an iCloud-synced folder,
# Finder keeps re-adding extended attributes that codesign refuses.
STAGE=$(mktemp -d)
APP="$STAGE/callrec.app"
FINAL="$OUT/callrec.app"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product CallrecApp
swift build -c "$CONFIG" --product callrec

BIN=".build/$CONFIG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/CallrecApp" "$APP/Contents/MacOS/callrec-app"
cp "$BIN/callrec" "$APP/Contents/MacOS/callrec"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.blaxify.callrec.app</string>
  <key>CFBundleName</key><string>callrec</string>
  <key>CFBundleDisplayName</key><string>callrec</string>
  <key>CFBundleExecutable</key><string>callrec-app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>0.2.0</string>
  <key>CFBundleIconFile</key><string>callrec</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>callrec records your phone calls so you can review and transcribe them.</string>
  <key>NSMicrophoneUsageDescription</key><string>callrec records your side of the call.</string>
</dict>
</plist>
PLIST

# Icon: drawn here rather than shipped as a binary asset.
if command -v iconutil >/dev/null 2>&1; then
  ICONSET=$(mktemp -d)/callrec.iconset
  mkdir -p "$ICONSET"
  if swift scripts/make-icon.swift "$ICONSET" >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/callrec.icns" || true
  fi
fi
[ -f "$APP/Contents/Resources/callrec.icns" ] || /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true

# macOS keeps re-adding com.apple.provenance, which codesign rejects, so strip
# and sign in a short retry loop.
signed=0
for _ in 1 2 3 4 5; do
  xattr -cr "$APP" 2>/dev/null || true
  # Finder adds these to the bundle directory itself and codesign refuses them.
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -d "com.apple.fileprovider.fpfs#P" "$APP" 2>/dev/null || true
  sleep 0.3
  if codesign -s - --deep -f "$APP" >/dev/null 2>&1; then signed=1; break; fi
done
[ "$signed" = 1 ] || echo "note: ad-hoc signing failed, the app will still run locally"

mkdir -p "$OUT"
rm -rf "$FINAL"
mv "$APP" "$FINAL"
rm -rf "$STAGE"
echo "Built $FINAL"
