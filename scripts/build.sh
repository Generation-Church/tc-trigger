#!/bin/bash
# Builds "TC Trigger.app" into ./build (Release, Apple Silicon, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Generating Xcode project"
xcodegen generate --quiet

echo "▸ Building (this takes a minute the first time)"
xcodebuild -project "TC Trigger.xcodeproj" -scheme "TC Trigger" -configuration Release \
  -derivedDataPath build/DerivedData -destination "platform=macOS,arch=arm64" \
  -quiet build

APP="build/TC Trigger.app"
rm -rf "$APP"
cp -R "build/DerivedData/Build/Products/Release/TC Trigger.app" "$APP"

IDENTITY="TC Trigger Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "▸ Signing with \"$IDENTITY\" (permissions survive updates)"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "▸ Signing ad-hoc. Run scripts/make-signing-cert.sh once so campus Macs keep"
  echo "  their audio permission across updates."
  codesign --force --sign - "$APP"
fi
codesign --verify "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo
echo "✓ Built $APP (version $VERSION)"
echo "  Run it with:  open \"$APP\""
echo "  Make a zip to install on campus Macs:  ./scripts/package.sh"
