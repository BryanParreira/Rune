#!/bin/sh
# Packages Rune.app into a signed DMG with a designed "drag to Applications" window.
#   scripts/make-dmg.sh <Rune.app> <out.dmg> [identity]
# Uses dmgbuild (MIT, installed into build/venv on first use) to lay out the window without
# scripting Finder; falls back to a plain DMG if it can't be installed.
set -eu

APP="$1"
DMG="$2"
IDENTITY="${3:--}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(dirname "$DMG")/dmg-work"
VENV="$ROOT/build/venv"

rm -rf "$WORK" "$DMG"
mkdir -p "$WORK"

if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV" >/dev/null 2>&1 && "$VENV/bin/pip" install -q dmgbuild >/dev/null 2>&1 || true
fi

if [ -x "$VENV/bin/dmgbuild" ]; then
  # Background at 1x and 2x, combined into one HiDPI-aware TIFF.
  swift "$ROOT/scripts/make-dmg-background.swift" "$WORK" >/dev/null
  tiffutil -cathidpicheck "$WORK/dmg-background.png" "$WORK/dmg-background@2x.png" -out "$WORK/background.tiff" 2>/dev/null
  ICON="$APP/Contents/Resources/AppIcon.icns"
  "$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" \
    -D app="$APP" -D background="$WORK/background.tiff" -D icon="$ICON" \
    "Rune" "$DMG" >/dev/null
else
  echo "(dmgbuild unavailable; building a plain DMG)"
  STAGE="$WORK/stage"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Rune.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Rune" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
fi
rm -rf "$WORK"

if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
echo "Created $DMG"
