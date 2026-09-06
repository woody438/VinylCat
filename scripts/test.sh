#!/bin/zsh
# Runs the built-in self-checks (no XCTest available with Command Line Tools alone).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | grep -E "error|warning: .*Sources" || true
"$(swift build --show-bin-path)/VinylCat" --self-test
