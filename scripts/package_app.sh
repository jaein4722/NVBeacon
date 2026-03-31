#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GPUUsage"
PRODUCT_NAME="GPUUsage"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-com.leejaein.GPUUsage}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"

DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/${APP_NAME}.app"
ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.zip"
BIN_PATH="$(swift build -c release --show-bin-path)"
EXECUTABLE_PATH="$BIN_PATH/$PRODUCT_NAME"
INFO_PLIST_PATH="$APP_PATH/Contents/Info.plist"

rm -rf "$APP_PATH" "$ZIP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

echo "Building release binary..."
swift build -c release --product "$PRODUCT_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_PATH/Contents/MacOS/$APP_NAME"

cat > "$INFO_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Signing app bundle..."
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_PATH"
else
  codesign --force --deep --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$INFO_PLIST_PATH"

echo "Creating zip archive..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "Notarization requires CODESIGN_IDENTITY to be set to a Developer ID Application certificate." >&2
    exit 1
  fi

  : "${APPLE_ID:?Set APPLE_ID to notarize.}"
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to notarize.}"
  : "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD to notarize.}"

  echo "Submitting zip for notarization..."
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

  echo "Stapling ticket..."
  xcrun stapler staple "$APP_PATH"

  echo "Repacking stapled app..."
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
fi

echo "App bundle: $APP_PATH"
echo "Zip archive: $ZIP_PATH"
