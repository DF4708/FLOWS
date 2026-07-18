#!/bin/bash
# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------

# Create (once) a stable local code-signing identity "FLOWS Local Dev".
#
# WHY: ad-hoc signatures change on every rebuild, and macOS TCC keys privacy
# grants (Location!) to the code-signing identity — so every reinstall
# re-prompted for location. A stable self-signed identity keeps the grant.
# Idempotent: exits quietly if the identity already exists.
set -euo pipefail

NAME="FLOWS Local Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "identity '$NAME' already present"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null

# Legacy PBE/MAC algorithms: OpenSSL 3 defaults produce p12 files the macOS
# keychain importer rejects ("MAC verification failed").
openssl pkcs12 -export -out "$TMP/flows.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -passout pass:flowslocal \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -legacy 2>/dev/null \
|| openssl pkcs12 -export -out "$TMP/flows.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -passout pass:flowslocal \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

security import "$TMP/flows.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P flowslocal -T /usr/bin/codesign

# Mark the cert trusted for code signing (user domain — no sudo).
security add-trusted-cert -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem" || true

echo "created identity '$NAME'"
security find-identity -v -p codesigning | grep "$NAME" || true
