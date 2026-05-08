#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OpenASO"
SCHEME="OpenASO"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-com.thirdtech.openaso}"
if [[ "$CONFIGURATION" == "Debug" && "${BUNDLE_ID:-}" == "com.thirdtech.openaso" ]]; then
  BUNDLE_ID="com.thirdtech.openaso.dev"
fi
ARCH="${OPENASO_ARCH:-$(uname -m)}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/OpenASO.xcodeproj"
BUILD_DIR="$ROOT_DIR/Build"
APP_BUNDLE="$BUILD_DIR/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"

load_dotenv_key() {
  local key="$1"
  local line value

  line="$(grep -E "^${key}=" "$ROOT_DIR/.env" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0

  value="${line#*=}"
  value="${value%$'\r'}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  export "$key=$value"
}

if [[ -f "$ROOT_DIR/.env" ]]; then
  load_dotenv_key "POSTHOG_PROJECT_TOKEN"
  load_dotenv_key "POSTHOG_HOST"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

build_app() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    -destination "platform=macOS,arch=$ARCH" \
    build
}

open_app() {
  if [[ -n "${POSTHOG_PROJECT_TOKEN:-}" || -n "${POSTHOG_HOST:-}" ]]; then
    "$APP_BINARY" >/dev/null 2>&1 &
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    build_app
    open_app
    ;;
  --debug|debug)
    build_app
    exec lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_app
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_app
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    build_app
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
