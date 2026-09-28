#!/bin/sh
# Packages Rune.app into a compressed, signed DMG with an Applications shortcut.
#   scripts/make-dmg.sh <Rune.app> <out.dmg> [identity]
set -eu

APP="$1"
DMG="$2"
IDENTITY="${3:--}"
STAGE="$(dirname "$DMG")/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Rune.app"
ln -s /Applications "$STAGE/Applications"
cp INSTALL.md "$STAGE/INSTALL.md"
hdiutil create -volname "Rune" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
echo "Created $DMG"
