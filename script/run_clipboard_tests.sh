#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/clipboard-tests"
MODULE_CACHE="$ROOT_DIR/build/module-cache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"

xcrun swiftc \
  -module-cache-path "$MODULE_CACHE" \
  -o "$BUILD_DIR/ClipboardHistoryStoreTests" \
  "$ROOT_DIR/SevenIslandTests/ClipboardHistoryStoreTests.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Models/ClipboardHistoryItem.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Services/ClipboardHistoryStore.swift"

"$BUILD_DIR/ClipboardHistoryStoreTests"
