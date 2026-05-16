#!/usr/bin/env bash
# Builds Ghostie.app — a signed macOS menu bar app — and installs it.
#
#   ./scripts/build-app.sh              # build + sign (auto identity) + install
#   ./scripts/build-app.sh --notarize   # also notarize & staple (Developer ID)
#
# Signing identity is auto-detected:
#   Developer ID Application  → hardened runtime, notarizable, permissions
#                               persist across rebuilds  (best; needs your
#                               Apple Developer account cert in the Keychain)
#   Apple Development         → signed for local use
#   (none)                    → ad-hoc signed (works; macOS may re-ask for
#                               permissions after a rebuild)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTARIZE=0; [ "${1:-}" = "--notarize" ] && NOTARIZE=1
APP_NAME="Ghostie"
BUNDLE_ID="com.davidsjunnesson.ghostie"
VERSION="1.0.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building release binary"
cd "$ROOT"
swift build -c release

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/ghostie" "$APP/Contents/MacOS/ghostie"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ghostie</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Ghostie transcribes your Teams calls locally so it can summarize them. Audio never leaves your Mac.</string>
  <key>NSHumanReadableCopyright</key><string>Ghostie</string>
</dict>
</plist>
PLIST

echo "==> Generating app icon (Pac-Man-style ghost)"
if "$ROOT/.build/release/ghostie" icon "$BUILD_DIR/icon.png" 2>/dev/null; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$BUILD_DIR/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d "$BUILD_DIR/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" \
    && echo "    icon created" || echo "    icon skipped"
else
  echo "    icon generation skipped (app still works)"
fi

# ---- Code signing -----------------------------------------------------------
ids() { security find-identity -v -p codesigning 2>/dev/null; }
hash_for() { ids | grep "$1" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40}).*/\1/'; }

DEVID="$(hash_for 'Developer ID Application' || true)"
APPLEDEV="$(hash_for 'Apple Development' || true)"
ENT="$ROOT/scripts/ghostie.entitlements"

if [ -n "$DEVID" ]; then
  echo "==> Signing with Developer ID ($DEVID) + hardened runtime"
  codesign --force --timestamp --options runtime \
    --entitlements "$ENT" --sign "$DEVID" "$APP"
  SIGNED="devid"
elif [ -n "$APPLEDEV" ]; then
  echo "==> Signing with Apple Development ($APPLEDEV)"
  codesign --force --entitlements "$ENT" --sign "$APPLEDEV" "$APP"
  SIGNED="appledev"
else
  echo "==> No Developer identity found — ad-hoc signing"
  echo "    (works for personal use; macOS may re-ask for permissions after a rebuild."
  echo "     For persistence, create a 'Developer ID Application' cert with your"
  echo "     Apple Developer account in Xcode ▸ Settings ▸ Accounts.)"
  codesign --force --entitlements "$ENT" --sign - "$APP"
  SIGNED="adhoc"
fi
codesign --verify --strict "$APP" && echo "    signature verified"

# ---- Notarization (optional, Developer ID only) -----------------------------
if [ "$NOTARIZE" = "1" ]; then
  if [ "$SIGNED" != "devid" ]; then
    echo "!! --notarize needs a Developer ID Application certificate. Skipping."
  else
    PROFILE="${NOTARY_PROFILE:-ghostie-notary}"
    echo "==> Notarizing (keychain profile: $PROFILE)"
    echo "    One-time setup if needed:"
    echo "    xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id <team> --password <app-specific-pw>"
    ZIP="$BUILD_DIR/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    echo "    notarized & stapled"
  fi
fi

# ---- Install ----------------------------------------------------------------
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
ditto "$APP" "$DEST/$APP_NAME.app"

echo
echo "==> Installed: $DEST/$APP_NAME.app"
echo
echo "Launch it:   open \"$DEST/$APP_NAME.app\""
echo "It appears as a 👻 ghost icon in your menu bar (no Dock icon)."
echo "First Teams call → macOS asks for Screen Recording + Microphone."
echo "Grant both to \"$APP_NAME\" in System Settings ▸ Privacy & Security."
echo "Use the menu's \"Start at Login\" to keep it always on."
