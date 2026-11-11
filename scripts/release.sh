#!/bin/bash
# Publish a new version of TC Trigger to GitHub, where every installed copy finds it via
# "Check for Updates…".
#
#   ./scripts/release.sh 1.1.0 "Offset can be typed in; Check for Updates."
#   DRY_RUN=1 ./scripts/release.sh 1.1.0 "test"     (build + sign + appcast only; publishes nothing)
#
# Needs (one time): scripts/make-signing-cert.sh and scripts/setup-updates.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
NOTES=${2:-}
DRY=${DRY_RUN:-0}
REPO="Generation-Church/tc-trigger"
TOOLS=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
die() { echo "✗ $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Usage: ./scripts/release.sh 1.2.3 \"What changed\""
[ -n "$NOTES" ] || die "Add release notes in quotes after the version."
[ -s config/sparkle-public-key.txt ] || die "No update key yet. Run ./scripts/setup-updates.sh first."
if [ "$DRY" != "1" ]; then
  [[ "$(security find-identity -p codesigning)" == *'"TC Trigger Signing"'* ]] \
    || die "No signing certificate. Run ./scripts/make-signing-cert.sh first (updates must be signed by it)."
  [ -z "$(git status --porcelain)" ] || die "Commit or discard your changes first (git status)."
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "Release from the main branch."
  git fetch -q origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main isn't in sync with GitHub (git pull / git push)."
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "v$VERSION already exists."
  gh auth status >/dev/null 2>&1 || die "Log in to GitHub first: gh auth login"
fi

# Build number must go up with every release (Sparkle compares it). Commit count + 1 = the count
# after the release commit below.
BUILD=$(( $(git rev-list --count HEAD) + 1 ))
echo "▸ Releasing TC Trigger $VERSION (build $BUILD)"
cp project.yml dist.project.yml.bak 2>/dev/null || true
restore_project() { [ -f dist.project.yml.bak ] && mv dist.project.yml.bak project.yml; }
[ "$DRY" = "1" ] && trap restore_project EXIT
sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]*\"/\1\"$VERSION\"/; s/(CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$BUILD\"/" project.yml
MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD ./scripts/build.sh

APP="build/TC Trigger.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist")" = "$(tr -d '[:space:]' < config/sparkle-public-key.txt)" ] \
  || die "The build doesn't contain the update key."
mkdir -p dist
ZIP="dist/TC-Trigger-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

echo "▸ Signing the update"
if [ "$DRY" = "1" ] && ! "$TOOLS/generate_keys" --account tc-trigger -p >/dev/null 2>&1; then
  SIGATTRS='sparkle:edSignature="DRY-RUN" length="'$(stat -f%z "$ZIP")'"'
else
  SIGATTRS=$("$TOOLS/sign_update" --account tc-trigger "$ZIP")
fi

URL="https://github.com/$REPO/releases/download/v$VERSION/TC-Trigger-$VERSION.zip"
NOTES_HTML=$(printf '%s' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | awk 'BEGIN{ORS=""} {print (NR>1?"<br>":"") $0}')
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TC Trigger</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>TC Trigger $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<h3>TC Trigger $VERSION</h3><p>$NOTES_HTML</p>]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIGATTRS />
    </item>
  </channel>
</rss>
XML
xmllint --noout dist/appcast.xml

if [ "$DRY" = "1" ]; then
  echo; echo "✓ Dry run done: $ZIP and dist/appcast.xml (nothing committed or published)."
  exit 0
fi

echo "▸ Publishing"
rm -f dist.project.yml.bak
git add project.yml
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "TC Trigger $VERSION"
git push -q origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" dist/appcast.xml --repo "$REPO" \
  --title "TC Trigger $VERSION" --notes "$NOTES"
echo
echo "✓ Released https://github.com/$REPO/releases/tag/v$VERSION"
echo "  Installed copies will see it under Check for Updates… (and in their next daily check)."
