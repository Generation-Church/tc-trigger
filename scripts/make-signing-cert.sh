#!/bin/bash
# One-time setup on the Mac that builds TC Trigger.
#
# Creates a self-signed code-signing certificate called "TC Trigger Signing" in your login
# keychain. scripts/build.sh signs every build with it. macOS remembers permissions (like audio
# input) per signing certificate, so campus Macs keep their permission when you install updates.
#
# It is NOT an Apple Developer ID: Gatekeeper still asks once per download (see README).
# Keep this Mac's login keychain backed up. If the certificate is lost, a new one works fine,
# but each campus Mac will ask for audio input permission once more.
set -euo pipefail
NAME="TC Trigger Signing"

if [[ "$(security find-identity -p codesigning)" == *"\"$NAME\""* ]]; then
  echo "✓ \"$NAME\" already exists in your keychain. Nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Generation Church
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/cert.p12" -passout "pass:$PASS" 2>/dev/null

echo "Adding \"$NAME\" to your login keychain (macOS may ask for your password)…"
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign

echo
echo "✓ Done. Run ./scripts/build.sh. The first build may ask to let codesign use the key:"
echo "  click \"Always Allow\"."
