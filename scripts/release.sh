#!/bin/bash
# Builds, signs, notarizes, and packages AppGlide for distribution.
#
# One-time setup:
#   xcrun notarytool store-credentials "AppGlide" \
#     --apple-id <apple-id-email> --team-id 9AZ9MMS68X
#   (paste an app-specific password from account.apple.com when prompted)
#
# Usage: scripts/release.sh
# Output: build/release/AppGlide-<version>.dmg (signed, notarized, stapled)

set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN_PROFILE="AppGlide"
WORK=build/release
ARCHIVE="$WORK/AppGlide.xcarchive"
EXPORT="$WORK/export"
APP="$EXPORT/AppGlide.app"
IDENTITY="Developer ID Application: Nicholas Hershy (9AZ9MMS68X)"

rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> Archiving (Release)"
xcodebuild archive \
  -project AppGlide.xcodeproj \
  -scheme AppGlide \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -quiet

echo "==> Exporting with Developer ID signing"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates \
  -quiet

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$WORK/AppGlide-$VERSION.dmg"

echo "==> Notarizing the app (version $VERSION)"
ditto -c -k --keepParent "$APP" "$WORK/AppGlide.zip"
xcrun notarytool submit "$WORK/AppGlide.zip" \
  --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> Building DMG"
STAGING="$WORK/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname AppGlide -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "==> Signing and notarizing the DMG"
codesign --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying"
codesign --verify --strict --verbose=2 "$APP"
spctl -a -vv "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo "Done: $DMG"
