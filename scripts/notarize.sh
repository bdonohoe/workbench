#!/bin/zsh
# Archives Bench, exports it signed with the Developer ID certificate, has
# Apple notarize it, staples the result, and zips it, so it opens on any
# Mac. Also packs it into a disk image for first installs, signed and
# notarized on its own. Prints the zip's path as the last line; the disk
# image sits beside it with the same name ending in .dmg.
#
# Needs fastlane/.env (gitignored) with an App Store Connect API key:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/notarized
TEAM=ZPU7B69KH3

[[ -f fastlane/.env ]] || { echo "Missing fastlane/.env with ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH." >&2; exit 1; }
set -a; source fastlane/.env; set +a
KEY="${ASC_KEY_PATH/#\~/$HOME}"
[[ "$KEY" = /* ]] || KEY="$PWD/fastlane/$KEY"
[[ -f "$KEY" ]] || { echo "Can't find the API key at $KEY." >&2; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate --quiet

# Exporting for Developer ID signs every piece of the app, Sparkle's
# helpers included, with the hardened runtime and without the debugging
# entitlement, which is what notarization needs.
echo "Archiving" >&2
xcodebuild -project Bench.xcodeproj -scheme Bench -configuration Release -derivedDataPath build \
    -archivePath "$OUT/Bench.xcarchive" archive > "$OUT/archive.log" 2>&1 \
    || { grep -E "error:" "$OUT/archive.log" >&2; echo "Archive failed. See $OUT/archive.log" >&2; exit 1; }
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
echo "Signing with Developer ID" >&2
xcodebuild -exportArchive -archivePath "$OUT/Bench.xcarchive" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
    || { grep -E "error:" "$OUT/export.log" >&2; echo "Export failed. See $OUT/export.log" >&2; exit 1; }
APP="$OUT/export/Workbench.app"
codesign --verify --deep --strict "$APP"

echo "Sending to Apple for notarization (a few minutes)" >&2
ditto -c -k --keepParent "$APP" "$OUT/upload.zip"
RESULT=$(xcrun notarytool submit "$OUT/upload.zip" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait)
rm "$OUT/upload.zip"
if ! grep -q "status: Accepted" <<< "$RESULT"; then
    echo "$RESULT" >&2
    ID=$(grep -m1 "id:" <<< "$RESULT" | awk '{print $2}')
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2
    exit 1
fi

xcrun stapler staple -q "$APP"
spctl --assess --type execute "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
ZIP="$OUT/Workbench-$VERSION-$BUILD.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# The disk image people download the first time. Sparkle keeps using the
# zip for updates.
DMG="${ZIP%.zip}.dmg"
scripts/make-dmg.sh "$APP" "$DMG" >/dev/null
# Read codesign's output whole first: piped into grep -m1, codesign can get
# SIGPIPE when grep stops early, and pipefail turns that into a failure.
SIGNING=$(codesign -dvv "$APP" 2>&1)
IDENTITY=$(grep -m1 '^Authority=' <<< "$SIGNING" | cut -d= -f2-)
codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "Sending the disk image for notarization" >&2
RESULT=$(xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait)
grep -q "status: Accepted" <<< "$RESULT" || { echo "$RESULT" >&2; echo "The disk image wasn't notarized." >&2; exit 1; }
xcrun stapler staple -q "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"

echo "Notarized $VERSION build $BUILD" >&2
echo "$ZIP"
