#!/usr/bin/env bash
#
# cert.sh - make a throwaway CA/leaf certificate for the wss:// and tls:// tests.
#
#   ./zmrig/tests/net/cert.sh [/path/to/output]
#
# The miner is then run with `--tls-ca <out>/cert.pem`. The certificate is
# self-signed and only valid for localhost/127.0.0.1, which is exactly what the
# local shims need.
set -euo pipefail

OUT="${1:-/tmp/zmrig-test}"
mkdir -p "$OUT"

if [ -f "$OUT/cert.pem" ] && [ -f "$OUT/key.pem" ]; then
    echo "certificate already present in $OUT"

    exit 0
fi

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,DNS:pool.example.invalid,IP:127.0.0.1" 2>/dev/null

echo "wrote $OUT/cert.pem and $OUT/key.pem"
