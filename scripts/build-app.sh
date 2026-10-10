#!/bin/bash
# Builds a universal (Apple silicon + Intel) InlineDSP.app and a zipped release artifact.
#
#   scripts/build-app.sh            -> dist/InlineDSP.app, dist/InlineDSP-<version>-macos.zip (+ .sha256)
#
# The app is ad-hoc signed (no Apple Developer ID), so a downloaded copy is quarantined by
# Gatekeeper; see the README for how to open it.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Sources/InlineDSP/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")
MIC_USAGE=$(/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$PLIST")
APP=dist/InlineDSP.app
ZIP=dist/InlineDSP-$VERSION-macos.zip

echo "==> Building inline-dsp $VERSION (universal)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/inline-dsp"

echo "==> Assembling $APP"
rm -rf "$APP" "$ZIP" "$ZIP.sha256"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/inline-dsp"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>inline-dsp</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>InlineDSP</string>
	<key>CFBundleDisplayName</key>
	<string>InlineDSP</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>$MIC_USAGE</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad hoc)"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> Packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
cat "$ZIP.sha256"
lipo -archs "$APP/Contents/MacOS/inline-dsp"
