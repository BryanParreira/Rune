#!/bin/sh
# Publishes a new Rune version that existing installs pick up through "Check for Updates".
#   scripts/release.sh <version> ["release notes"]
#
# Steps: bump version + build number → universal Release build → Developer ID signing →
# notarize + staple → Sparkle-signed appcast → GitHub Release on the public releases repo →
# commit + tag the version bump.
#
# Environment:
#   RELEASES_REPO   owner/name of the public releases repo (default: <your gh user>/rune-releases)
#   NOTARY_PROFILE  notarytool keychain profile (default: rune-notary)
set -eu

VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-Rune $VERSION}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASES_REPO="${RELEASES_REPO:-$(gh api user -q .login)/rune-releases}"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
TAG="v$VERSION"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists"; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree has uncommitted changes; commit or stash them first."; exit 1
fi

# Version bump. The build number must always increase for Sparkle to see an update.
BUILD=$(( $(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?/\1/p' project.yml | head -1) + 1 ))
sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$BUILD\"/" project.yml
echo "→ Rune $VERSION (build $BUILD)"

make notarize NOTARY_PROFILE="${NOTARY_PROFILE:-rune-notary}"

# Appcast: start from the published one so older entries are kept, add this DMG.
STAGE="build/appcast"
rm -rf "$STAGE"; mkdir -p "$STAGE"
curl -fsL "https://github.com/$RELEASES_REPO/releases/latest/download/appcast.xml" -o "$STAGE/appcast.xml" || rm -f "$STAGE/appcast.xml"
cp build/Rune.dmg "$STAGE/Rune-$VERSION.dmg"
printf '%s\n' "$NOTES" > "$STAGE/Rune-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account rune \
  --download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/$TAG/" \
  --embed-release-notes \
  "$STAGE"

gh release create "$TAG" --repo "$RELEASES_REPO" --title "Rune $VERSION" --notes "$NOTES" \
  "$STAGE/Rune-$VERSION.dmg" "$STAGE/appcast.xml"

git add project.yml
git commit -m "Release $VERSION"
git tag "$TAG"
git push --follow-tags 2>/dev/null || echo "(push skipped: no upstream configured)"
echo "Published https://github.com/$RELEASES_REPO/releases/tag/$TAG"
