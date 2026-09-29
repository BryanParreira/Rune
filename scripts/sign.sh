#!/bin/sh
# Signs Rune.app inside-out for distribution.
#   scripts/sign.sh <path/to/Rune.app> [identity]
# With a "Developer ID Application" identity the app gets the hardened runtime and a secure
# timestamp (both required for notarization). With "-" it is ad-hoc signed (local use only).
set -eu

APP="$1"
IDENTITY="${2:--}"
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/Resources/Rune.entitlements"

if [ "$IDENTITY" = "-" ]; then
  FLAGS="--force --sign -"
else
  FLAGS="--force --options runtime --timestamp --sign"
fi

sign() {
  # shellcheck disable=SC2086
  if [ "$IDENTITY" = "-" ]; then codesign $FLAGS "$@"; else codesign $FLAGS "$IDENTITY" "$@"; fi
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  # Sparkle's helpers must be signed before the framework that contains them.
  sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
fi

for framework in "$APP"/Contents/Frameworks/*.framework; do
  [ "$framework" = "$SPARKLE" ] && continue
  [ -d "$framework" ] && sign "$framework"
done

sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed $APP with ${IDENTITY}"
