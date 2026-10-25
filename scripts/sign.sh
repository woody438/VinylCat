#!/usr/bin/env bash
# Signs a built VinylCat.app with the project's certificate in place of the ad-hoc signature,
# so every build macOS sees is the same app: its designated requirement names the certificate,
# not the build. That is what lets the updater install a new build (it checks the download
# against this app's own requirement) and what keeps Camera, Microphone and Speech permissions
# across an update.
#
#   scripts/sign.sh build/VinylCat.app cert.p12 PASSWORD
#
# The certificate goes into a keychain of its own, made for this and deleted after; the login
# keychain is never touched. Used by .github/workflows/build.yml with the SIGNING_CERT_P12 and
# SIGNING_CERT_PASSWORD secrets (scripts/signing-cert-to-ci.sh puts them there).
set -euo pipefail
APP="$1"
P12="$2"
PASS="$3"
NAME="${VINYLCAT_CERT_NAME:-VinylCat Local Signing}"

KC="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vinylcat-signing.keychain-db"
KCPASS=$(/usr/bin/openssl rand -hex 16)
SEARCH=$(security list-keychains -d user | tr -d '"')
cleanup() {
  # shellcheck disable=SC2086
  security list-keychains -d user -s $SEARCH
  security delete-keychain "$KC" 2>/dev/null || true
}
trap cleanup EXIT

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$P12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
# shellcheck disable=SC2086
security list-keychains -d user -s "$KC" $SEARCH

# By name, not "the first one": a .p12 exported from the login keychain can carry more than one
# identity, and signing with the wrong certificate would break every installed copy's update path.
# Self-signed, so it is never "valid" (nothing vouches for it), but codesign signs with it.
ID=$(security find-identity -p codesigning "$KC" | awk -v n="$NAME" '$0 ~ n { gsub(/"/, "", $2); print $2; exit }')
if [ -z "$ID" ]; then
  echo "sign.sh: no code-signing identity called \"$NAME\" in $P12. It holds:" >&2
  security find-identity -p codesigning "$KC" >&2
  exit 1
fi

codesign --force --deep --sign "$ID" --keychain "$KC" --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
REQ=$(codesign -d -r- "$APP" 2>&1)
echo "$REQ" | grep "designated"
if ! echo "$REQ" | grep -q "certificate"; then
  echo "sign.sh: $APP isn't signed with the certificate — the updater would refuse it" >&2
  exit 1
fi
