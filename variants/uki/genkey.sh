#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="$SCRIPT_DIR/addon.key"
CERT="$SCRIPT_DIR/addon.crt"
DER_CERT="$SCRIPT_DIR/addon.cer"

if [[ -e "$KEY" || -e "$CERT" || -e "$DER_CERT" ]]; then
    echo "Refusing to overwrite existing addon signing material." >&2
    echo "Move addon.key, addon.crt, and addon.cer aside explicitly first." >&2
    exit 1
fi

umask 077
openssl req \
    -new \
    -x509 \
    -newkey rsa:3072 \
    -sha256 \
    -nodes \
    -days 365 \
    -subj '/CN=TDX CVM UKI Addon Development/' \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=codeSigning' \
    -keyout "$KEY" \
    -out "$CERT"

openssl x509 -in "$CERT" -outform DER -out "$DER_CERT"

chmod 600 "$KEY"
chmod 644 "$CERT" "$DER_CERT"

echo "Created development-only addon signing material:"
echo "  $KEY"
echo "  $CERT"
echo "  $DER_CERT"
openssl x509 -in "$CERT" -noout -fingerprint -sha256
