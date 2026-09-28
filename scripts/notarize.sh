#!/bin/sh
# Notarizes Rune for distribution outside the App Store.
#   scripts/notarize.sh <Rune.app> <out.dmg> <identity> <notarytool keychain profile>
# 1. zip + notarize + staple the app (so the app itself carries its ticket, which matters for
#    in-app updates that install the .app without the DMG)
# 2. build a signed DMG around the stapled app, notarize + staple the DMG
set -eu

APP="$1"
DMG="$2"
IDENTITY="$3"
PROFILE="$4"
ZIP="$(dirname "$DMG")/Rune-notarize.zip"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarization credentials found for profile \"$PROFILE\". Create them once with:"
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id <team-id>"
  exit 1
fi

echo "→ Notarizing app…"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "→ Building DMG…"
sh "$(dirname "$0")/make-dmg.sh" "$APP" "$DMG" "$IDENTITY"

echo "→ Notarizing DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature --verbose "$DMG"
spctl --assess --type execute --verbose "$APP"
echo "Notarized $DMG"
