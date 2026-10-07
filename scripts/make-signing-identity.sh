#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity, "callrec local signing", in the login keychain.
#
# Why: ad-hoc signatures (`codesign -s -`) bind to the binary's hash, so every rebuild is a
# "different app" to macOS and the Microphone / System Audio / Full Disk Access grants can reset
# on every update. A signature from one fixed certificate keeps the same designated requirement
# across builds, so the grants should survive.
#
# Idempotent: does nothing if the identity already exists. Needs no sudo. If macOS wants a
# keychain password or a click, this stops and says exactly what to run.
set -euo pipefail
NAME="${CALLREC_SIGNING_NAME:-callrec local signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "identity '$NAME' already exists"; exit 0
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=$(openssl rand -hex 16)
cat > "$work/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/openssl.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
# macOS `security import` cannot read OpenSSL 3's default AES-256 PKCS#12; use the older ciphers.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout "pass:$pass" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

security import "$work/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
echo "imported '$NAME' into the login keychain"

# Prove codesign can use the key without a prompt.
probe="$work/probe"; cp /usr/bin/true "$probe"
if ! codesign -s "$NAME" -f "$probe" >/dev/null 2>&1; then
  cat >&2 <<MSG

STOP: the identity was imported, but codesign cannot use its key without a keychain prompt.
Run this once in Terminal (it asks for your login password, which this script must not handle):

  security set-key-partition-list -S apple-tool:,apple: -s -k '<your login password>' "$KEYCHAIN"

Then run scripts/make-signing-identity.sh again to confirm.
MSG
  exit 3
fi
echo "ok: codesign can sign with '$NAME'"
