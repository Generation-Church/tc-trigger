#!/bin/bash
# Builds "TC Trigger.app" into ./build (Release, Apple Silicon, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Generating Xcode project"
xcodegen generate --quiet

echo "▸ Building (this takes a minute the first time)"
# Update-signing public key (created once by scripts/setup-updates.sh). Without it the app
# builds fine but can't check for updates.
KEY_FILE="config/sparkle-public-key.txt"
SPARKLE_PUBLIC_KEY=""
if [ -f "$KEY_FILE" ]; then SPARKLE_PUBLIC_KEY=$(tr -d '[:space:]' < "$KEY_FILE"); fi
[ -n "$SPARKLE_PUBLIC_KEY" ] || echo "  (no $KEY_FILE — this build won't check for updates; see scripts/setup-updates.sh)"

xcodebuild -project "TC Trigger.xcodeproj" -scheme "TC Trigger" -configuration Release \
  -derivedDataPath build/DerivedData -destination "platform=macOS,arch=arm64" \
  SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"} \
  ${CURRENT_PROJECT_VERSION:+CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION"} \
  -quiet build

APP="build/TC Trigger.app"
rm -rf "$APP"
cp -R "build/DerivedData/Build/Products/Release/TC Trigger.app" "$APP"

IDENTITY="TC Trigger Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "▸ Signing with \"$IDENTITY\" (permissions survive updates)"
  codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "▸ Signing ad-hoc. Run scripts/make-signing-cert.sh once so campus Macs keep"
  echo "  their audio permission across updates."
  codesign --force --deep --sign - "$APP"
fi
codesign --verify "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo
echo "✓ Built $APP (version $VERSION)"
echo "  Run it with:  open \"$APP\""
echo "  Make a zip to install on campus Macs:  ./scripts/package.sh"
