#!/usr/bin/env bash
# Makes an Apple distribution signing certificate without a Mac.
#
# Keychain Access normally does step 1 and step 3; OpenSSL does the same
# job, so the only Apple-side work is two browser clicks in between.
# Run from Git Bash on Windows:
#
#   bash tools/appledev/signing-cert.sh csr      # then upload the .csr
#   bash tools/appledev/signing-cert.sh p12      # after downloading .cer
#
# Everything lands in tools/appledev/out/, which is gitignored — the
# private key must never be committed.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out"
KEY="$DIR/distribution.key"
CSR="$DIR/distribution.csr"
CER="$DIR/distribution.cer"
P12="$DIR/distribution.p12"
mkdir -p "$DIR"

case "${1:-}" in
csr)
  if [ -f "$KEY" ]; then
    echo "A private key already exists at $KEY."
    echo "Delete it only if you also revoke the matching certificate."
    exit 1
  fi
  read -rp "Email for the certificate request: " EMAIL
  read -rp "Your name (or any label): " NAME
  openssl genrsa -out "$KEY" 2048
  openssl req -new -key "$KEY" -out "$CSR" \
    -subj "/emailAddress=$EMAIL/CN=$NAME/C=US"
  chmod 600 "$KEY"
  echo
  echo "Created $CSR"
  echo
  echo "Next, in a browser:"
  echo "  1. developer.apple.com/account/resources/certificates/list"
  echo "  2. + -> Apple Distribution -> Continue"
  echo "  3. Upload $CSR"
  echo "  4. Download the .cer and save it as:"
  echo "     $CER"
  echo "  5. Run: bash tools/appledev/signing-cert.sh p12"
  ;;

p12)
  [ -f "$KEY" ] || { echo "Missing $KEY — run 'csr' first."; exit 1; }
  [ -f "$CER" ] || { echo "Missing $CER — download it from Apple first."; exit 1; }
  read -rsp "Choose a password for the .p12 (you will need it again): " PW
  echo
  # Apple hands back DER; PKCS#12 wants PEM.
  openssl x509 -inform DER -in "$CER" -out "$DIR/distribution.pem"
  # macOS `security import` is happiest with the legacy PKCS#12 ciphers;
  # OpenSSL 3 defaults to AES and needs the legacy provider for them, so
  # fall back if this build of OpenSSL does not have it.
  openssl pkcs12 -export -legacy \
    -inkey "$KEY" -in "$DIR/distribution.pem" \
    -out "$P12" -passout "pass:$PW" \
    -name "Apple Distribution: Theseus" 2>/dev/null \
  || openssl pkcs12 -export \
    -inkey "$KEY" -in "$DIR/distribution.pem" \
    -out "$P12" -passout "pass:$PW" \
    -name "Apple Distribution: Theseus"
  base64 -w0 "$P12" > "$DIR/distribution.p12.base64" 2>/dev/null \
    || base64 "$P12" | tr -d '\n' > "$DIR/distribution.p12.base64"
  echo
  echo "Created $P12"
  echo
  echo "GitHub secrets to set (repo -> Settings -> Secrets and variables"
  echo "-> Actions -> New repository secret):"
  echo "  SIGNING_CERT_P12       = contents of $DIR/distribution.p12.base64"
  echo "  SIGNING_CERT_PASSWORD  = the password you just chose"
  ;;

*)
  echo "usage: $0 {csr|p12}"
  exit 2
  ;;
esac
