#!/bin/bash
# One-time setup on the Mac you publish releases from.
#
# Creates the key that signs every TC Trigger update. The private half stays in your login
# keychain (account "tc-trigger"); the public half is saved to config/sparkle-public-key.txt and
# built into the app, so campus Macs only accept updates signed by you.
#
# Running it again is safe: an existing key is reused, never replaced.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLS=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
if [ ! -x "$TOOLS/generate_keys" ]; then
  echo "Fetching the update tools (first build)…"
  ./scripts/build.sh >/dev/null
fi

echo "Creating (or finding) the update-signing key. macOS may ask to allow keychain access: click Allow."
"$TOOLS/generate_keys" --account tc-trigger >/dev/null
PUB=$("$TOOLS/generate_keys" --account tc-trigger -p)
mkdir -p config
echo "$PUB" > config/sparkle-public-key.txt
echo "✓ Public key saved to config/sparkle-public-key.txt"
echo
echo "IMPORTANT: back up the private key somewhere safe (e.g. your password manager)."
echo "If it's lost, installed copies can't accept updates and must be reinstalled by hand."
read -r -p "Export a backup copy to ~/Desktop/tc-trigger-update-key.txt now? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  "$TOOLS/generate_keys" --account tc-trigger -x "$HOME/Desktop/tc-trigger-update-key.txt"
  echo "✓ Saved. Put it in your password manager, then delete it from the Desktop."
fi
echo
echo "Next: commit config/sparkle-public-key.txt, then publish with ./scripts/release.sh <version> \"notes\""
