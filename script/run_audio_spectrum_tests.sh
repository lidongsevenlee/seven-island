#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/audio-spectrum-tests"
mkdir -p "$BUILD_DIR" "$ROOT_DIR/build/module-cache"
xcrun swiftc -module-cache-path "$ROOT_DIR/build/module-cache" \
  "$ROOT_DIR/SevenIslandTests/AudioSpectrumTests.swift" \
  "$ROOT_DIR/boringNotch/helpers/AudioSpectrumAnalyzer.swift" \
  "$ROOT_DIR/boringNotch/managers/MusicAudioSpectrum.swift" \
  "$ROOT_DIR/boringNotch/components/Music/MusicSpectrumBar.swift" \
  -o "$BUILD_DIR/AudioSpectrumTests"
"$BUILD_DIR/AudioSpectrumTests"
