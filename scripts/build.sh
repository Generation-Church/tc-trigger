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

echo "▸ Signing (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo
echo "✓ Built $APP (version $VERSION)"
echo "  Run it with:  open \"$APP\""
