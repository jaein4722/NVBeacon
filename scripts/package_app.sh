#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-NVBeacon}"
PRODUCT_NAME="NVBeacon"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"

VERSION="${VERSION:-0.4.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-com.leejaein.NVBeacon}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
SKIP_DMG="${SKIP_DMG:-0}"
NOTARIZE="${NOTARIZE:-0}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/jaein4722/NVBeacon/appcast/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"
DMGBUILD_VERSION="${DMGBUILD_VERSION:-1.6.7}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"
APP_STORE_CONNECT_API_KEY_PATH="${APP_STORE_CONNECT_API_KEY_PATH:-}"
APP_STORE_CONNECT_API_KEY_ID="${APP_STORE_CONNECT_API_KEY_ID:-}"
APP_STORE_CONNECT_API_ISSUER_ID="${APP_STORE_CONNECT_API_ISSUER_ID:-}"

DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
NOTARIZE_ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-notarize.zip"
DMG_STAGING_DIR="$DIST_DIR/.dmg-staging"
DMG_BACKGROUND_PATH="$DIST_DIR/.dmg-background.png"
ICON_SOURCE_PATH="${ICON_SOURCE_PATH:-$ROOT_DIR/icon.png}"
ICON_NAME="AppIcon"
ICONSET_DIR="$DIST_DIR/.${ICON_NAME}.iconset"
ICON_NORMALIZED_PATH="$DIST_DIR/.${ICON_NAME}-1024.png"
ICON_RESOURCE_PATH="$APP_PATH/Contents/Resources/${ICON_NAME}.icns"
DMGBUILD_SITE_DIR="$ROOT_DIR/.build/packaging-tools/dmgbuild-$DMGBUILD_VERSION"
DMG_VERIFY_MOUNT_PATH="$DIST_DIR/.distribution-check-mount"
BIN_PATH="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
EXECUTABLE_PATH="$BIN_PATH/$PRODUCT_NAME"
INFO_PLIST_PATH="$APP_PATH/Contents/Info.plist"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
SPARKLE_FRAMEWORK_SOURCE_PATH="$BIN_PATH/Sparkle.framework"

cleanup() {
  if mount | grep -q "on $DMG_VERIFY_MOUNT_PATH "; then
    hdiutil detach "$DMG_VERIFY_MOUNT_PATH" -quiet || true
  fi
  rm -rf "$DMG_STAGING_DIR" "$NOTARIZE_ZIP_PATH" "$ICONSET_DIR" "$ICON_NORMALIZED_PATH" "$DMG_BACKGROUND_PATH" "$DMG_VERIFY_MOUNT_PATH"
}

trap cleanup EXIT

assess_gatekeeper_app() {
  spctl --assess --type exec -vv "$1"
}

assess_gatekeeper_dmg() {
  spctl --assess --type open --context context:primary-signature -vv "$1"
}

assess_distribution_ready() {
  local path="$1"

  if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$path" --verbose
  elif [[ "$path" == *.app ]]; then
    assess_gatekeeper_app "$path"
  else
    assess_gatekeeper_dmg "$path"
  fi
}

ensure_dmgbuild() {
  if PYTHONPATH="$DMGBUILD_SITE_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -c "import dmgbuild" >/dev/null 2>&1; then
    return
  fi

  echo "Installing dmgbuild $DMGBUILD_VERSION for styled DMG packaging..."
  mkdir -p "$DMGBUILD_SITE_DIR"
  python3 -m pip install --disable-pip-version-check --target "$DMGBUILD_SITE_DIR" "dmgbuild==$DMGBUILD_VERSION"
}

generate_dmg_background() {
  echo "Generating DMG background..."
  swift "$ROOT_DIR/scripts/generate_dmg_background.swift" \
    --output "$DMG_BACKGROUND_PATH" \
    --app-name "$APP_NAME"
}

create_styled_dmg() {
  ensure_dmgbuild
  generate_dmg_background

  echo "Creating styled DMG archive..."
  PYTHONPATH="$DMGBUILD_SITE_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m dmgbuild \
      -s "$ROOT_DIR/scripts/dmgbuild_settings.py" \
      -D app="$APP_PATH" \
      -D background="$DMG_BACKGROUND_PATH" \
      -D volume_name="$VOLUME_NAME" \
      "$VOLUME_NAME" \
      "$DMG_PATH"
}

verify_dmg_distribution() {
  local dmg_path="$1"
  local mounted_app_path="$DMG_VERIFY_MOUNT_PATH/${APP_NAME}.app"

  echo "Checking notarized DMG signature and Gatekeeper policy..."
  codesign --verify -R="notarized" --check-notarization "$dmg_path"
  assess_gatekeeper_dmg "$dmg_path"

  rm -rf "$DMG_VERIFY_MOUNT_PATH"
  mkdir -p "$DMG_VERIFY_MOUNT_PATH"

  echo "Mounting DMG for distribution checks..."
  hdiutil attach "$dmg_path" -mountpoint "$DMG_VERIFY_MOUNT_PATH" -nobrowse -readonly -quiet

  if [[ ! -d "$mounted_app_path" ]]; then
    echo "Expected mounted app not found at $mounted_app_path" >&2
    exit 1
  fi

  echo "Verifying mounted app bundle is ready for distribution..."
  assess_distribution_ready "$mounted_app_path"

  hdiutil detach "$DMG_VERIFY_MOUNT_PATH" -quiet
  rm -rf "$DMG_VERIFY_MOUNT_PATH"
}

submit_for_notarization() {
  local artifact_path="$1"

  if [[ -n "$KEYCHAIN_PROFILE" ]]; then
    xcrun notarytool submit "$artifact_path" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    return
  fi

  if [[ -n "$APP_STORE_CONNECT_API_KEY_PATH" ]]; then
    : "${APP_STORE_CONNECT_API_KEY_ID:?Set APP_STORE_CONNECT_API_KEY_ID to notarize.}"
    : "${APP_STORE_CONNECT_API_ISSUER_ID:?Set APP_STORE_CONNECT_API_ISSUER_ID to notarize.}"

    xcrun notarytool submit "$artifact_path" \
      --key "$APP_STORE_CONNECT_API_KEY_PATH" \
      --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
      --issuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
      --wait
    return
  fi

  : "${APPLE_ID:?Set APPLE_ID to notarize.}"
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to notarize.}"
  : "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD to notarize.}"

  xcrun notarytool submit "$artifact_path" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
}

generate_app_icon() {
  if [[ ! -f "$ICON_SOURCE_PATH" ]]; then
    return
  fi

  echo "Generating app icon from $ICON_SOURCE_PATH..."
  mkdir -p "$ICONSET_DIR"
  cp "$ICON_SOURCE_PATH" "$ICON_NORMALIZED_PATH"

  # Normalize arbitrary PNG input into a square 1024px source before building
  # the .icns asset set required by macOS app bundles.
  sips -Z 1024 "$ICON_NORMALIZED_PATH" >/dev/null
  sips -p 1024 1024 "$ICON_NORMALIZED_PATH" >/dev/null

  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_NORMALIZED_PATH" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$ICON_NORMALIZED_PATH" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done

  iconutil --convert icns --output "$ICON_RESOURCE_PATH" "$ICONSET_DIR"
}

rm -rf "$APP_PATH" "$DMG_PATH" "$NOTARIZE_ZIP_PATH" "$DMG_STAGING_DIR" "$DMG_BACKGROUND_PATH" "$DMG_VERIFY_MOUNT_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$FRAMEWORKS_DIR"

echo "Building $BUILD_CONFIGURATION binary..."
swift build -c "$BUILD_CONFIGURATION" --product "$PRODUCT_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_PATH/Contents/MacOS/$APP_NAME"

if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE_PATH" ]]; then
  echo "Expected Sparkle.framework not found at $SPARKLE_FRAMEWORK_SOURCE_PATH" >&2
  exit 1
fi

echo "Bundling Sparkle.framework..."
ditto "$SPARKLE_FRAMEWORK_SOURCE_PATH" "$FRAMEWORKS_DIR/Sparkle.framework"

generate_app_icon

ICON_PLIST_ENTRY=""
if [[ -f "$ICON_RESOURCE_PATH" ]]; then
  ICON_PLIST_ENTRY=$'  <key>CFBundleIconFile</key>\n  <string>'"$ICON_NAME"$'</string>\n'
fi

SPARKLE_PUBLIC_KEY_ENTRY=""
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  SPARKLE_PUBLIC_KEY_ENTRY=$'  <key>SUPublicEDKey</key>\n  <string>'"$SPARKLE_PUBLIC_ED_KEY"$'</string>\n'
fi

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
${ICON_PLIST_ENTRY}  <key>CFBundleIdentifier</key>
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
  <key>SUFeedURL</key>
  <string>${SPARKLE_FEED_URL}</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
${SPARKLE_PUBLIC_KEY_ENTRY}</dict>
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

echo "Assessing app with Gatekeeper..."
if assess_gatekeeper_app "$APP_PATH"; then
  echo "Gatekeeper assessment: accepted."
else
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "Gatekeeper assessment: rejected (expected for ad-hoc local builds)." >&2
    echo "This build is fine for your own Mac, but other Macs will likely show 'Apple cannot check it for malicious software'." >&2
    echo "For real distribution, sign with a Developer ID certificate and notarize the archive." >&2
  else
    echo "Gatekeeper assessment: rejected. This usually means the app is signed but not yet notarized." >&2
  fi
fi

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "Notarization requires CODESIGN_IDENTITY to be set to a Developer ID Application certificate." >&2
    exit 1
  fi

  echo "Creating zip archive for notarization..."
  ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP_PATH"

  echo "Submitting app bundle archive for notarization..."
  submit_for_notarization "$NOTARIZE_ZIP_PATH"

  echo "Stapling ticket..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"

  echo "Verifying notarized app is ready for distribution..."
  assess_distribution_ready "$APP_PATH"
fi

echo "App bundle: $APP_PATH"

if [[ "$SKIP_DMG" == "1" ]]; then
  echo "Skipping DMG creation."
  exit 0
fi

create_styled_dmg

if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  echo "Signing DMG..."
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

echo "Assessing DMG with Gatekeeper..."
if assess_gatekeeper_dmg "$DMG_PATH"; then
  echo "Gatekeeper assessment: accepted."
else
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "Gatekeeper assessment: rejected (expected for ad-hoc local builds)." >&2
    echo "This DMG is fine for local testing, but other Macs will likely show an 'unverified developer' warning." >&2
  else
    echo "Gatekeeper assessment: rejected. The DMG is signed but not yet notarized." >&2
  fi
fi

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Submitting DMG for notarization..."
  submit_for_notarization "$DMG_PATH"

  echo "Stapling DMG..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  echo "Verifying notarized DMG is ready for distribution..."
  verify_dmg_distribution "$DMG_PATH"
fi

echo "DMG archive: $DMG_PATH"
