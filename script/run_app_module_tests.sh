#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SOURCE="${1:?Pass a Swift test source file}"
TEST_NAME="$(basename "$TEST_SOURCE" .swift)"
PRODUCTS="$ROOT_DIR/build/DerivedData/Build/Products/Debug"
APP_CONTENTS="$PRODUCTS/Seven Island.app/Contents"
APP_MODULE="$APP_CONTENTS/MacOS/Seven Island.debug.dylib"
BUILD_DIR="$ROOT_DIR/build/app-module-tests"

if [[ ! -f "$APP_MODULE" ]]; then
  echo "Build the Debug app with script/build_and_run.sh before running app module tests." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

xcrun swiftc \
  -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$ROOT_DIR/build/module-cache" \
  -I "$PRODUCTS" \
  -F "$PRODUCTS/PackageFrameworks" \
  -F "$ROOT_DIR/mediaremote-adapter" \
  "$TEST_SOURCE" \
  "$APP_MODULE" \
  -Xlinker -rpath -Xlinker "$APP_CONTENTS/MacOS" \
  -Xlinker -rpath -Xlinker "$APP_CONTENTS/Frameworks" \
  -o "$BUILD_DIR/$TEST_NAME"

"$BUILD_DIR/$TEST_NAME"
