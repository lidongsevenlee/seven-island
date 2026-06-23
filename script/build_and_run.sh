#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/boringNotch.xcodeproj"
SCHEME="boringNotch"
CONFIGURATION="Debug"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_NAME="Seven Island"
BUNDLE_ID="com.local.seven-island"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

# 旧版 pkill -x "$APP_NAME" 有两个问题：进程名 "Seven Island" 含空格匹配不到，
# 且 GUI 进程会忽略默认的 SIGTERM。改用 -f 匹配完整 bundle 路径（覆盖主程序 +
# XPCServices/BoringNotchXPCHelper），并用 -9 (SIGKILL) 确保旧实例真正退出。
pkill -9 -f "$APP_BUNDLE" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 5
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
