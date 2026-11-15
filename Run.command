#!/bin/zsh
set -e
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
BUILD_PATH="$SCRIPT_DIR/.build/debug"
if [[ ! -x "$BUILD_PATH/MSIControl" ]]; then
  cd "$SCRIPT_DIR"
  swift build --disable-sandbox
  BUILD_PATH="$(swift build --disable-sandbox --show-bin-path)"
fi
exec "$BUILD_PATH/MSIControl"
