#!/bin/bash
# Creates a stable self-signed code-signing identity called "Sofa Self-Signed"
# in the login keychain, so every build.sh signs Sofa with the *same* identity.
#
# Why: ad-hoc signing changes the app's code hash on every rebuild, which makes
# macOS treat each build as a new app and forget granted permissions
# (Accessibility, Automation) — so it re-prompts forever. A stable signing
# identity keeps the "designated requirement" constant, so grants persist.
#
# Run once. Safe to re-run (it recreates the identity).
set -euo pipefail
NAME="Sofa Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Sofa Self-Signed
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.pem" -out "$TMP/c.pem" \
  -days 3650 -nodes -config "$TMP/cert.conf" >/dev/null 2>&1

# -legacy: macOS's Security framework can't read OpenSSL 3's default PKCS12 MAC.
openssl pkcs12 -export -legacy -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
  -out "$TMP/id.p12" -passout pass:sofa -name "$NAME" >/dev/null 2>&1

# -T /usr/bin/codesign lets codesign use the key without a keychain prompt.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P sofa -T /usr/bin/codesign

echo "✓ Created signing identity: $NAME"
echo "  (CSSMERR_TP_NOT_TRUSTED is expected — self-signed certs sign fine, they"
echo "   just aren't trusted for verification, which we don't need.)"
