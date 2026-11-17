#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${SDK:-iphonesimulator}"
case "$sdk" in
  iphonesimulator)
    destination="${DESTINATION:-generic/platform=iOS Simulator}"
    signing=YES # Embed simulator entitlements for Keychain access.
    ;;
  iphoneos)
    destination="${DESTINATION:-generic/platform=iOS}"
    signing=NO
    ;;
  *) echo "SDK must be iphoneos or iphonesimulator." >&2; exit 1 ;;
esac
sdk_version="$(xcrun --sdk "$sdk" --show-sdk-version)"
IFS=. read -r sdk_major sdk_minor _ <<< "$sdk_version"
if (( sdk_major < 27 || (sdk_major == 27 && sdk_minor < 1) )); then
  echo "NVBeacon iOS requires SDK 27.1 or newer; selected SDK is $sdk_version. Select the latest Xcode using DEVELOPER_DIR or xcode-select." >&2
  exit 1
fi
xcodebuild -version
echo "Building with $sdk SDK $sdk_version"
xcodebuild -project "$repo_dir/Mobile/NVBeacon.xcodeproj" -scheme NVBeacon \
  -configuration "${BUILD_CONFIGURATION:-Debug}" -sdk "$sdk" -destination "$destination" \
  -derivedDataPath "$repo_dir/.build/ios" \
  -clonedSourcePackagesDirPath "$repo_dir/.build/ios-packages" \
  CODE_SIGNING_ALLOWED="$signing" build "$@"
