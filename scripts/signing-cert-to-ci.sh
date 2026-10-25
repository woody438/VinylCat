#!/usr/bin/env bash
# Puts the "VinylCat Local Signing" certificate where GitHub Actions can sign with it, so the
# builds CI publishes are the same app to macOS as the one you build here — which is what makes
# the updater work and what keeps Camera, Microphone and Speech permissions across an update.
#
# First export the certificate by hand, so exactly one goes out:
#
#   1. Keychain Access → login → My Certificates → "VinylCat Local Signing"
#   2. Right-click → Export… → Personal Information Exchange (.p12) → save it somewhere temporary
#   3. Give it a password when asked (that password becomes SIGNING_CERT_PASSWORD)
#
# Then:
#
#   scripts/signing-cert-to-ci.sh ~/Desktop/VinylCat.p12
#
# It checks the file really holds the signing identity, then copies it to the clipboard base64'd
# and tells you which two secrets to paste it into. Delete the .p12 afterwards — the clipboard and
# GitHub are the only places it needs to be. Keep a copy of the password in your password manager:
# a replacement certificate later means every installed copy has to allow Camera, Microphone and
# Speech once more, and can't auto-update to the first build signed with it.
#
# Anyone with these two secrets can sign something macOS would take for VinylCat. Treat them as
# you would any key.
set -euo pipefail
P12="${1:-}"
NAME="${VINYLCAT_CERT_NAME:-VinylCat Local Signing}"

if [[ -z "$P12" ]]; then
  echo "usage: scripts/signing-cert-to-ci.sh EXPORTED.p12   (see the comments at the top for the export)" >&2
  exit 1
fi
if [[ ! -f "$P12" ]]; then
  # Keychain Access names its export "Certificates.p12" by default, which is the usual reason we're here.
  echo "No such file: $P12" >&2
  # || true: one of the globs usually matches nothing, and `set -e` would otherwise stop us here.
  FOUND=$(ls -t ~/Desktop/*.p12 ~/Downloads/*.p12 2>/dev/null | head -3 || true)
  if [[ -n "$FOUND" ]]; then
    echo "Did you mean one of these?" >&2
    # Quoted with %q: a name holding a space, a backtick or a quote is unusable pasted back bare.
    while IFS= read -r line; do printf '  %q\n' "$line" >&2; done <<<"$FOUND"
  else
    echo "Export it first: Keychain Access → login → My Certificates → \"$NAME\" → right-click → Export…" >&2
  fi
  exit 1
fi

read -r -s -p "Password you set when exporting $P12: " PASS
echo

# Import into a throwaway keychain to prove it carries the identity CI will ask for by name.
KC="${TMPDIR:-/tmp}/vinylcat-cert-check.keychain-db"
KCPASS=$(/usr/bin/openssl rand -hex 16)
trap 'security delete-keychain "$KC" 2>/dev/null || true' EXIT
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
if ! security import "$P12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null 2>&1; then
  echo "That password didn't open $P12." >&2
  exit 1
fi

FOUND=$(security find-identity -p codesigning "$KC" || true)
if ! grep -q "$NAME" <<<"$FOUND"; then
  echo "$P12 has no code-signing identity called \"$NAME\". It holds:" >&2
  echo "$FOUND" >&2
  echo "Export \"$NAME\" from Keychain Access → My Certificates (the certificate, which carries its key)." >&2
  exit 1
fi
COUNT=$(grep -c ')' <<<"$FOUND" || true)
[[ "$COUNT" -gt 1 ]] && echo "note: $P12 carries $COUNT identities; CI picks \"$NAME\" by name, but export just the one if you can."

base64 -i "$P12" | tr -d '\n' | pbcopy
cat <<EOF

Checked: "$NAME" is in there, and it's on the clipboard base64'd.

On GitHub → woody438/VinylCat → Settings → Secrets and variables → Actions → New repository secret:

  SIGNING_CERT_P12        paste (⌘V)
  SIGNING_CERT_PASSWORD   the password you just typed

Then delete $P12.

Until both secrets are there, CI builds are signed ad hoc — they install by hand, but no copy will
auto-update to them, by design.
EOF
