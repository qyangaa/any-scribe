#!/bin/bash
# Create a local self-signed code-signing certificate so AnyScribe.app keeps a STABLE
# identity across rebuilds — macOS TCC (Microphone, Screen Recording) grants then persist
# instead of needing a re-grant after every `package-app.sh`.
#
# Run this ONCE. package-app.sh auto-detects and uses the cert if present.
# Re-running it is safe and will (re)authorize codesign to stop keychain prompts.
set -euo pipefail

CERT_NAME="Any Scribe Self-Signed"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-certificate -c "${CERT_NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
    echo "✓ Signing certificate already exists: \"${CERT_NAME}\""
else
    echo "▶ Generating self-signed code-signing certificate \"${CERT_NAME}\"…"
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP}"' EXIT

    cat > "${TMP}/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${CERT_NAME}
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG

    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" -config "${TMP}/cert.cfg"

    openssl pkcs12 -export -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
        -out "${TMP}/identity.p12" -name "${CERT_NAME}" -passout pass:anyscribe

    # -A lets codesign use the private key without a keychain ACL prompt (local dev convenience).
    security import "${TMP}/identity.p12" -k "${KEYCHAIN}" -P anyscribe -A
    echo "✓ Created \"${CERT_NAME}\" in your login keychain."
fi

# Permanently authorize codesign to use the key without repeated "allow access" prompts.
# This needs your LOGIN PASSWORD (typed by you; never stored). Skip with Ctrl-C if you'd rather
# just click "Always Allow" on the prompt.
echo ""
echo "▶ Authorizing codesign to use the key (enter your macOS login password)…"
if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "${KEYCHAIN}" >/dev/null 2>&1; then
    echo "✓ Authorized (no password needed)."
else
    read -rs -p "  login password: " PW; echo ""
    if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${PW}" "${KEYCHAIN}" >/dev/null 2>&1; then
        echo "✓ codesign authorized — no more keychain prompts."
    else
        echo "⚠ Could not set partition list. You can still click \"Always Allow\" on the codesign prompt instead."
    fi
    unset PW
fi

echo ""
echo "Next: ./package-app.sh   (signs with this identity; grants persist across rebuilds)"
