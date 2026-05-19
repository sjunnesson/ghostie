#!/usr/bin/env bash
# Builds Ghostie.app and (optionally) a self-contained, notarizable .dmg.
#
#   ./scripts/build-app.sh                  # build + sign + install locally
#   ./scripts/build-app.sh --reset-perms    # also clear stale TCC grants once
#                                           # (use after make-signing-cert.sh)
#   ./scripts/build-app.sh --dmg            # also bundle whisper+model and
#                                           # produce build/Ghostie.dmg
#   ./scripts/build-app.sh --dmg --notarize # notarize + staple the .dmg
#
# --dmg makes the app self-contained: a statically-built whisper-cli and the
# speech model are bundled inside Ghostie.app, so the target Mac needs nothing
# but macOS 15+. (Summaries still use the user's own Claude Code login; until
# they run `claude` once, calls transcribe and queue in the backlog.)
#
# Signing identity is auto-detected: Developer ID Application (notarizable,
# permissions persist) → Apple Development → stable self-signed
# ("Ghostie Self-Signed", or $GHOSTIE_SIGN_IDENTITY) → ad-hoc. Only ad-hoc
# loses Microphone/Screen-Recording grants on rebuild — see
# scripts/make-signing-cert.sh to create the stable self-signed identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Ghostie"
BUNDLE_ID="com.davidsjunnesson.ghostie"
VERSION="1.0.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
WHISPER_TAG="v1.8.4"
MODEL_CACHE="$HOME/.ghostie/models"

NOTARIZE=0; SELFCONTAINED=0; MAKE_DMG=0; RESET_PERMS=0
for a in "$@"; do
  case "$a" in
    --notarize)    NOTARIZE=1 ;;
    --dmg)         SELFCONTAINED=1; MAKE_DMG=1 ;;
    --reset-perms) RESET_PERMS=1 ;;
  esac
done

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

# ---- Self-contained: bundle a static whisper-cli + the model ----------------
NESTED_BINS=()
if [ "$SELFCONTAINED" = "1" ]; then
  command -v cmake >/dev/null 2>&1 || brew install cmake
  SRC="$HOME/.ghostie/cache/whisper.cpp"
  if [ ! -d "$SRC" ]; then
    echo "==> Cloning whisper.cpp $WHISPER_TAG"
    git clone --depth 1 --branch "$WHISPER_TAG" \
      https://github.com/ggerganov/whisper.cpp "$SRC"
  fi
  if [ ! -x "$SRC/build/bin/whisper-cli" ]; then
    echo "==> Building static whisper-cli (Metal embedded)…"
    cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON \
      -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF >/dev/null
    cmake --build "$SRC/build" -j --config Release --target whisper-cli >/dev/null
  fi
  cp "$SRC/build/bin/whisper-cli" "$APP/Contents/Resources/whisper-cli"
  echo "    bundled whisper-cli ($(otool -L "$APP/Contents/Resources/whisper-cli" | grep -c dylib) dynamic libs)"
  NESTED_BINS+=("$APP/Contents/Resources/whisper-cli")

  echo "==> Bundling speech model (ggml-base.en.bin)"
  mkdir -p "$MODEL_CACHE"
  if [ ! -f "$MODEL_CACHE/ggml-base.en.bin" ]; then
    curl -fL --progress-bar \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
      -o "$MODEL_CACHE/ggml-base.en.bin"
  fi
  cp "$MODEL_CACHE/ggml-base.en.bin" "$APP/Contents/Resources/ggml-base.en.bin"
  # Optional VAD model — only if it's already cached.
  if [ -f "$MODEL_CACHE/ggml-silero-v5.1.2.bin" ]; then
    cp "$MODEL_CACHE/ggml-silero-v5.1.2.bin" "$APP/Contents/Resources/"
    echo "    bundled Silero VAD model"
  fi
fi

# ---- Code signing -----------------------------------------------------------
ids() { security find-identity -v -p codesigning 2>/dev/null; }
hash_for() { ids | grep "$1" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40}).*/\1/'; }

DEVID="$(hash_for 'Developer ID Application' || true)"
APPLEDEV="$(hash_for 'Apple Development' || true)"
# Stable self-signed fallback (see scripts/make-signing-cert.sh). Override
# with GHOSTIE_SIGN_IDENTITY="<identity name or SHA-1>".
SELFSIGN="$(hash_for "${GHOSTIE_SIGN_IDENTITY:-Ghostie Self-Signed}" || true)"
ENT="$ROOT/scripts/ghostie.entitlements"

if [ -n "$DEVID" ]; then
  IDENTITY="$DEVID"; SIGNED="devid"
  SIGN_OPTS=(--force --timestamp --options runtime)
elif [ -n "$APPLEDEV" ]; then
  IDENTITY="$APPLEDEV"; SIGNED="appledev"
  SIGN_OPTS=(--force)
elif [ -n "$SELFSIGN" ]; then
  IDENTITY="$SELFSIGN"; SIGNED="selfsigned"
  SIGN_OPTS=(--force)
  echo "==> Signing with stable self-signed identity (permissions will persist)"
else
  IDENTITY="-"; SIGNED="adhoc"
  SIGN_OPTS=(--force)
  echo "==> No signing identity found — AD-HOC signing."
  echo "    macOS will re-ask for Microphone/Screen Recording on every"
  echo "    rebuild. Fix once with:  ./scripts/make-signing-cert.sh"
fi

# Sign nested executables first (whisper-cli), then seal the app.
for b in "${NESTED_BINS[@]:-}"; do
  [ -n "$b" ] || continue
  echo "==> Signing nested $(basename "$b")"
  codesign "${SIGN_OPTS[@]}" --sign "$IDENTITY" "$b"
done
echo "==> Signing $APP_NAME.app ($SIGNED)"
codesign "${SIGN_OPTS[@]}" --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature verified"

# ---- DMG --------------------------------------------------------------------
DMG="$BUILD_DIR/$APP_NAME.dmg"
if [ "$MAKE_DMG" = "1" ]; then
  echo "==> Creating $APP_NAME.dmg"
  STAGE="$BUILD_DIR/dmg-stage"
  rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
  [ "$SIGNED" = "devid" ] && codesign --force --sign "$DEVID" "$DMG"
  echo "    $DMG ($(du -h "$DMG" | cut -f1))"
fi

# ---- Notarization -----------------------------------------------------------
if [ "$NOTARIZE" = "1" ]; then
  if [ "$SIGNED" != "devid" ]; then
    echo "!! --notarize needs a Developer ID Application certificate. Skipping."
  else
    PROFILE="${NOTARY_PROFILE:-ghostie-notary}"
    echo "==> Notarizing (keychain profile: $PROFILE)"
    echo "    One-time setup if needed:"
    echo "    xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id 6V9RN6W28J --password <app-specific-pw>"
    TARGET="$DMG"
    [ "$MAKE_DMG" = "1" ] || { TARGET="$BUILD_DIR/$APP_NAME.zip"; ditto -c -k --keepParent "$APP" "$TARGET"; }
    xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$TARGET"
    [ "$MAKE_DMG" = "1" ] || xcrun stapler staple "$APP"
    echo "    notarized & stapled"
  fi
fi

# ---- Install locally --------------------------------------------------------
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
ditto "$APP" "$DEST/$APP_NAME.app"

echo
echo "==> Installed: $DEST/$APP_NAME.app  (signed: $SIGNED)"
[ "$MAKE_DMG" = "1" ] && echo "==> Distributable: $DMG"
echo

# Clear stale TCC grants once when moving onto a stable identity, so macOS
# prompts a single time under the new identity instead of being confused by
# the old ad-hoc hash. Harmless to run repeatedly (just re-prompts once).
if [ "$RESET_PERMS" = "1" ]; then
  echo "==> Resetting Microphone + Screen Recording grants for $BUNDLE_ID"
  tccutil reset Microphone "$BUNDLE_ID"  >/dev/null 2>&1 || true
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
  killall Ghostie >/dev/null 2>&1 || true
  echo "    Launch Ghostie and approve both ONCE — it will stick from now on."
  echo
fi
if [ "$SIGNED" = "adhoc" ]; then
  echo "NOTE: ad-hoc signed → macOS will re-prompt for Microphone/Screen"
  echo "      Recording on every rebuild. One-time fix:"
  echo "        ./scripts/make-signing-cert.sh"
  echo "        ./scripts/build-app.sh --reset-perms"
  echo
fi
if [ "$MAKE_DMG" = "1" ]; then
  echo "Share Ghostie.dmg → on the other Mac: open it, drag Ghostie to"
  echo "Applications, launch it. Transcription is fully bundled (no setup)."
  [ "$NOTARIZE" = "1" ] || echo "Not notarized: first open via right-click ▸ Open (or run --notarize)."
fi
echo "Menu-bar 👻 icon, no Dock icon. First Teams call → grant Screen"
echo "Recording + Microphone in System Settings ▸ Privacy & Security."
