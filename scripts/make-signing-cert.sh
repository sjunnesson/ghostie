#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity so macOS keeps the
# Microphone / Screen-Recording permission across rebuilds.
#
# Why: with no Apple Developer account, build-app.sh falls back to *ad-hoc*
# signing. macOS TCC then keys the privacy grant to the binary's exact code
# hash, which changes on every rebuild — so it re-prompts forever. A reused
# self-signed certificate gives a stable signing identity, so the grant sticks.
#
#   ./scripts/make-signing-cert.sh                # create (idempotent)
#   ./scripts/make-signing-cert.sh --delete       # remove it again
#
# One-time only. It is created in your LOGIN keychain and you'll be asked to
# authorize trusting it for code signing (one macOS password prompt). No sudo,
# no Apple account. If the scripted path misbehaves, the GUI fallback in the
# README (Keychain Access ▸ Certificate Assistant) is equivalent.
set -euo pipefail

CN="Ghostie Self-Signed"
LOGIN_KC="$(security default-keychain | tr -d ' "')"

if [ "${1:-}" = "--delete" ]; then
  # Remove every identity/cert with our CN from the login keychain.
  while security find-certificate -c "$CN" "$LOGIN_KC" >/dev/null 2>&1; do
    security delete-identity -c "$CN" "$LOGIN_KC" >/dev/null 2>&1 \
      || security delete-certificate -c "$CN" "$LOGIN_KC" >/dev/null 2>&1 || break
  done
  echo "Removed '$CN' from $LOGIN_KC (if it was present)."
  echo "Rebuild with ./scripts/build-app.sh — it will fall back to ad-hoc."
  exit 0
fi

if security find-identity -v -p codesigning | grep -q "$CN"; then
  echo "✓ '$CN' already exists and is a valid codesigning identity."
  echo "  Build with ./scripts/build-app.sh (it will use it automatically)."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CN
[v3]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

# Use the system openssl (LibreSSL); Homebrew's OpenSSL 3 writes PKCS#12 with
# a MAC macOS can't read ("MAC verification failed"). We also avoid PKCS#12
# entirely and import the key + cert as PEM, which sidesteps that whole class
# of incompatibility regardless of which openssl is first on PATH.
OPENSSL=/usr/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=openssl

echo "==> Generating self-signed code-signing certificate (10 years)…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1

echo "==> Importing into login keychain ($LOGIN_KC)…"
# Key and cert imported separately as PEM — no .p12, no MAC mismatch. The
# keychain pairs them into a code-signing identity.
security import "$TMP/key.pem"  -k "$LOGIN_KC" -A -T /usr/bin/codesign >/dev/null
security import "$TMP/cert.pem" -k "$LOGIN_KC" -A -T /usr/bin/codesign >/dev/null

echo "==> Trusting it for code signing (a keychain prompt may appear)…"
# User trust domain — no sudo/admin. Non-fatal: a freshly imported self-signed
# code-signing cert is often already a *valid* identity without an explicit
# trust override (and on a locked-down managed Mac this prompt may be denied).
# The find-identity check below is the real source of truth.
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$LOGIN_KC" "$TMP/cert.pem" >/dev/null 2>&1 \
  || echo "   (trust step skipped/denied — checking validity anyway)"

if security find-identity -v -p codesigning | grep -q "$CN"; then
  echo
  echo "✓ Done. '$CN' is now a stable codesigning identity."
  echo
  echo "Next:"
  echo "  1. ./scripts/build-app.sh --reset-perms   # rebuild signed + clear old grants"
  echo "  2. Launch Ghostie, approve Microphone + Screen Recording ONCE."
  echo "     Future rebuilds keep the permission (no Apple account involved)."
else
  echo "!! Imported but not showing as a valid codesigning identity."
  echo "   This usually means the trust prompt was denied (managed Mac)."
  echo "   Fallback: Keychain Access ▸ Certificate Assistant ▸ Create a"
  echo "   Certificate — name '$CN', Identity Type 'Self Signed Root',"
  echo "   Certificate Type 'Code Signing'. Then: ./scripts/build-app.sh --reset-perms"
  exit 1
fi
