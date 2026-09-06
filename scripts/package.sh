#!/bin/zsh
# Release build → output/VinylCat_vN_YYYY-MM-DD.zip, ready to send to someone else.
# Recipient: macOS 15+, unzip, right-click VinylCat.app → Open (first launch only; the app is not notarised).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release >/dev/null
DATE=$(date +%F); N=1
while [[ -e "output/VinylCat_v${N}_${DATE}.zip" ]]; do N=$((N+1)); done
mkdir -p output
ditto -c -k --keepParent build/VinylCat.app "output/VinylCat_v${N}_${DATE}.zip"
echo "output/VinylCat_v${N}_${DATE}.zip  ($(du -h "output/VinylCat_v${N}_${DATE}.zip" | cut -f1))"
