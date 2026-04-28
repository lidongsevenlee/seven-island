#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/feature-tests"
TEST_BINARY="$BUILD_DIR/SevenIslandFeatureTests"
MODULE_CACHE="$ROOT_DIR/build/module-cache"

mkdir -p "$BUILD_DIR"
mkdir -p "$MODULE_CACHE"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

xcrun swiftc \
  -sdk "$SDKROOT" \
  -o "$TEST_BINARY" \
  "$ROOT_DIR/SevenIslandTests/SevenIslandFeatureTests.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Models/ClipboardHistoryItem.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Models/VSCodeProjectItem.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Models/CodexStatusSnapshot.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Services/ClipboardHistoryStore.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Services/VSCodeRecentProjectsService.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Services/AppLauncherService.swift" \
  "$ROOT_DIR/boringNotch/components/SevenIsland/Services/CodexStatusService.swift" \
  "$ROOT_DIR/boringNotch/components/Notch/LyricsDisplayText.swift"

"$TEST_BINARY"
