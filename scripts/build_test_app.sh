#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.3.5}"
SHORT_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD | tr '[:upper:]' '[:lower:]')"
APP_NAME="NVBeacon-${VERSION}-test-${SHORT_SHA}"
APP_PATH="$ROOT_DIR/dist/${APP_NAME}.app"
TEST_BUNDLE_ID="com.leejaein.NVBeacon.test.${SHORT_SHA}"
OPEN_APP="${OPEN_APP:-0}"
CLEAN_OLD_TEST_APPS="${CLEAN_OLD_TEST_APPS:-1}"

if [[ "$CLEAN_OLD_TEST_APPS" == "1" ]]; then
  while IFS= read -r pid; do
    kill -9 "$pid" 2>/dev/null || true
  done < <(pgrep -f "$ROOT_DIR/dist/.*-test-.*\\.app/Contents/MacOS/.*-test-.*" || true)

  while IFS= read -r old_app; do
    rm -rf "$old_app"
  done < <(find "$ROOT_DIR/dist" -maxdepth 1 -type d -name '*-test-*.app' ! -name "${APP_NAME}.app" -print 2>/dev/null)
fi

APP_NAME="$APP_NAME" \
BUNDLE_ID="$TEST_BUNDLE_ID" \
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}" \
SKIP_DMG=1 \
"$ROOT_DIR/scripts/package_app.sh"

echo "Test app bundle: $APP_PATH"
echo "Open it with: open \"$APP_PATH\""

if [[ "$OPEN_APP" == "1" ]]; then
  open "$APP_PATH"
fi
