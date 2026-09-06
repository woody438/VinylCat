#!/bin/zsh
# Build VinylCat with SwiftPM and assemble a launchable .app bundle (no Xcode needed).
# Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"; shift || true
RUN=0; [[ "${1:-}" == "--run" ]] && RUN=1

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/VinylCat"
APP="build/VinylCat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VinylCat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Bundle any resources SwiftPM produced (sounds, fonts) next to the binary.
BUNDLE_DIR="$(dirname "$BIN")/VinylCat_VinylCat.bundle"
[[ -d "$BUNDLE_DIR" ]] && cp -R "$BUNDLE_DIR" "$APP/Contents/Resources/"
[[ -d Resources/Sounds ]] && cp -R Resources/Sounds "$APP/Contents/Resources/"
[[ -d Resources/Fonts ]] && cp -R Resources/Fonts "$APP/Contents/Resources/"
# Ad-hoc signature is enough for camera/mic/speech permission prompts on this Mac.
codesign --force --deep --sign - "$APP" >/dev/null
echo "built $APP"
if (( RUN )); then
  pkill -x VinylCat 2>/dev/null || true
  open "$APP"
fi
