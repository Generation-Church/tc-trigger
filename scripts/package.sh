#!/bin/bash
# Builds TC Trigger and zips it for installing on campus Macs: dist/TC-Trigger-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
APP="build/TC Trigger.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/TC-Trigger-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo
echo "✓ $ZIP is ready. Copy it to each campus Mac and follow \"Install on a campus Mac\" in README.md."
open -R "$ZIP"
