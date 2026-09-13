#!/bin/zsh
# Release build → output/VinylCat_vN_YYYY-MM-DD.dmg, ready to send to someone else.
# The image opens as a window with VinylCat.app, an Applications folder to drag it onto, and "Read me first.txt"
# (Resources/Read me first.txt: the recipient's install steps — the app is signed locally, not notarised, so macOS 15
# blocks the first launch until they click Open Anyway in Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release >/dev/null

# The number is unique across output/ AND the site's downloads folder: a DMG moved out of output/ must not free
# its number, or the next build overwrites the one already published under it (it happened, 0.2.0 vs 0.2.2).
DATE=$(date +%F); N=1
while [[ -e "output/VinylCat_v${N}_${DATE}.dmg" || -e "site-b/downloads/VinylCat_v${N}_${DATE}.dmg" ]]; do N=$((N+1)); done
DMG="output/VinylCat_v${N}_${DATE}.dmg"
mkdir -p output

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/VinylCat.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Read me first.txt" "$STAGE/"

hdiutil create -volname "VinylCat" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$DMG"
echo "$DMG  ($(du -h "$DMG" | cut -f1))"
