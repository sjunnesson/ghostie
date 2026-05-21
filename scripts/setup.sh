#!/usr/bin/env bash
# Ghostie setup: installs whisper.cpp, builds the binary, then uses the
# binary to fetch models. All URL/filename knowledge lives in
# `Sources/ghostie/Models.swift` — this script is now a thin orchestrator
# so the shell and the app can't drift out of sync.
set -euo pipefail

# Args (order-independent):
#   <model>            ggml model name for the single-language path
#                      (default: base.en). Anything else like medium.en
#                      is fetched too; codeswitch is independent.
#   --vad              also fetch the Silero VAD model
#   --codeswitch       also fetch the dual-model code-switching pair
#                      (KB-Whisper-large <variant> + whisper-large-v3 + VAD)
#   --kb-variant <v>   KB-Whisper Stage-2 variant: standard | strict
#                      (subtitle has no prebuilt GGML upstream)
MODEL="base.en"
WANT_VAD=0
WANT_CODESWITCH=0
KB_VARIANT="standard"
prev=""
for a in "$@"; do
  if [ "$prev" = "--kb-variant" ]; then KB_VARIANT="$a"; prev=""; continue; fi
  case "$a" in
    --vad)         WANT_VAD=1 ;;
    --codeswitch)  WANT_CODESWITCH=1 ;;
    --kb-variant)  prev="--kb-variant" ;;
    -*)            ;;
    *)             MODEL="$a" ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$HOME/.ghostie/models"
mkdir -p "$MODELS_DIR"

echo "==> Ghostie setup (model: ${MODEL}$([ "$WANT_VAD" = 1 ] && echo ', + VAD')$([ "$WANT_CODESWITCH" = 1 ] && echo ", + codeswitch [KB ${KB_VARIANT}]"))"

# 1. whisper.cpp CLI
if ! command -v whisper-cli >/dev/null 2>&1 && ! command -v whisper-cpp >/dev/null 2>&1; then
  echo "==> Installing whisper.cpp via Homebrew…"
  brew install whisper-cpp
else
  echo "==> whisper.cpp already installed."
fi

# 2. Build the release binary up-front so we can use it as the downloader.
echo "==> Building ghostie (release)…"
cd "$ROOT"
swift build -c release
BIN="$ROOT/.build/release/ghostie"

# 3. The chosen single-language model. Ghostie's `fetch-models` only knows
#    the well-known names (base.en, large-v3 etc.); a one-shot curl
#    handles any other ggml variant the user picked.
MODEL_FILE="$MODELS_DIR/ggml-${MODEL}.bin"
if [ ! -f "$MODEL_FILE" ]; then
  if [ "$MODEL" = "base.en" ]; then
    "$BIN" fetch-models --all
  else
    echo "==> Downloading ggml-${MODEL}.bin (one-off variant) …"
    curl -fL --progress-bar \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin" \
      -o "$MODEL_FILE"
  fi
else
  echo "==> Model already present: $MODEL_FILE"
fi

# 4. Optional extras. Each call is idempotent (SHA256-verified, intact
#    files skip), so re-running setup.sh is safe.
if [ "$WANT_VAD" = 1 ]; then
  "$BIN" fetch-models --vad
fi
if [ "$WANT_CODESWITCH" = 1 ]; then
  "$BIN" fetch-models "$KB_VARIANT" --codeswitch
fi

echo
echo "==> Done."
echo "    Binary:  $BIN"
echo "    Models:  $MODELS_DIR"
echo
echo "Next steps:"
echo "  1. Summaries use the Claude Code CLI — no API key. If you haven't"
echo "     already, run  claude  once in a terminal to log in."
echo "  2. Verify:           $BIN doctor"
echo "  3. Verify models:    $BIN doctor models"
echo "  4. Smoke test:       $BIN test-record 30"
echo "  5. Run for real:     $BIN run"
echo "     Auto-start at login:  $BIN install-service"
echo
echo "On first capture, macOS will ask for Screen Recording + Microphone"
echo "permission. Grant both in System Settings ▸ Privacy & Security."
