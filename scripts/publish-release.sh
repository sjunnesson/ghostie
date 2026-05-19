#!/usr/bin/env bash
# Publish a Ghostie release that existing users auto-update to.
#
#   ./scripts/publish-release.sh X.Y.Z
#
# Human-triggered and IRREVERSIBLE: it builds a notarized, stapled .dmg + the
# OTA app-zip, tags vX.Y.Z, pushes the tag, and creates a GitHub Release with
# the assets the in-app updater reads. There is deliberately no CI workflow —
# releases are cut by a person, on purpose.
#
# Preconditions (all checked before anything is published):
#   • gh CLI installed and `gh auth login` done (write access to the repo)
#   • clean git working tree
#   • tag vX.Y.Z does not already exist (locally or on origin)
#   • notarytool keychain profile present ($NOTARY_PROFILE or ghostie-notary)
#     — see scripts/build-app.sh for one-time `xcrun notarytool
#     store-credentials` setup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="sjunnesson/ghostie"
APP_NAME="Ghostie"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 X.Y.Z" >&2; exit 1
fi
TAG="v$VERSION"
PROFILE="${NOTARY_PROFILE:-ghostie-notary}"

echo "==> Preconditions"
command -v gh >/dev/null 2>&1 || { echo "!! gh CLI not found (brew install gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "!! run: gh auth login"; exit 1; }
[ -z "$(git -C "$ROOT" status --porcelain)" ] \
  || { echo "!! git working tree is not clean"; exit 1; }
if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1 \
   || git -C "$ROOT" ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "!! tag $TAG already exists — bump the version"; exit 1
fi
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "!! notary profile '$PROFILE' missing — see build-app.sh header"; exit 1; }

echo
echo "About to BUILD, NOTARIZE, tag $TAG, push it, and PUBLISH a GitHub"
echo "Release to $REPO. Existing users will auto-update to this. Irreversible."
printf "Type the version (%s) to confirm: " "$VERSION"
read -r CONFIRM
[ "$CONFIRM" = "$VERSION" ] || { echo "aborted"; exit 1; }

echo "==> Building notarized release $TAG"
GHOSTIE_VERSION="$VERSION" "$ROOT/scripts/build-app.sh" --dmg --notarize

OTA="$ROOT/build/${APP_NAME}-${VERSION}.zip"
SHA="$ROOT/build/${APP_NAME}-${VERSION}.sha256"
DMG="$ROOT/build/${APP_NAME}.dmg"
for f in "$OTA" "$SHA" "$DMG"; do
  [ -f "$f" ] || { echo "!! expected artifact missing: $f"; exit 1; }
done
SHA256="$(cat "$SHA")"

# Release notes: commits since the previous tag + the SHA-256 the in-app
# updater extracts (HTML comment, stripped before display).
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
PREV="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
{
  echo "## $APP_NAME $TAG"
  echo
  if [ -n "$PREV" ]; then
    git -C "$ROOT" log --pretty='- %s' "$PREV"..HEAD
  else
    git -C "$ROOT" log --pretty='- %s' -20
  fi
  echo
  echo "<!--sha256:$SHA256-->"
} > "$NOTES"

echo "==> Tagging $TAG"
git -C "$ROOT" tag -a "$TAG" -m "$APP_NAME $TAG"
git -C "$ROOT" push origin "$TAG"

echo "==> Creating GitHub Release"
gh release create "$TAG" \
  "$OTA" "$SHA" "$DMG" \
  --repo "$REPO" \
  --title "$APP_NAME $TAG" \
  --notes-file "$NOTES"

echo
echo "==> Published $TAG"
echo "    OTA zip:  $(basename "$OTA")  (sha256 $SHA256)"
echo "    Installed users will be offered this within ~24h, or via"
echo "    “Check for Updates…”."
