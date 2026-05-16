#!/usr/bin/env bash
# Ghostie setup: installs whisper.cpp, downloads a model, builds the app.
set -euo pipefail

# Args (order-independent): a model name and/or --vad
MODEL="base.en"   # tiny.en | base.en | small.en | medium.en | large-v3
WANT_VAD=0
for a in "$@"; do
  case "$a" in
    --vad) WANT_VAD=1 ;;
    -*)    ;;
    *)     MODEL="$a" ;;
  esac
done
MODELS_DIR="$HOME/.ghostie/models"
MODEL_FILE="$MODELS_DIR/ggml-${MODEL}.bin"
VAD_FILE="$MODELS_DIR/ggml-silero-v5.1.2.bin"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Ghostie setup (model: ${MODEL}$([ "$WANT_VAD" = 1 ] && echo ', + Silero VAD'))"

# 1. whisper.cpp (local, private transcription)
if ! command -v whisper-cli >/dev/null 2>&1 && ! command -v whisper-cpp >/dev/null 2>&1; then
  echo "==> Installing whisper.cpp via Homebrew…"
  brew install whisper-cpp
else
  echo "==> whisper.cpp already installed."
fi

# 2. Model
mkdir -p "$MODELS_DIR"
if [ ! -f "$MODEL_FILE" ]; then
  echo "==> Downloading ggml-${MODEL}.bin …"
  curl -fL --progress-bar \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin" \
    -o "$MODEL_FILE"
else
  echo "==> Model already present: $MODEL_FILE"
fi

# 2b. Optional Silero VAD model — biggest single reducer of silence-driven
#     whisper hallucination. Ghostie auto-uses it when present.
if [ "$WANT_VAD" = 1 ]; then
  if [ ! -f "$VAD_FILE" ]; then
    echo "==> Downloading Silero VAD model …"
    curl -fL --progress-bar \
      "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" \
      -o "$VAD_FILE" \
      || echo "   (VAD download failed — Ghostie still works without it)"
  else
    echo "==> Silero VAD model already present: $VAD_FILE"
  fi
fi

# 3. Build (release)
echo "==> Building ghostie (release)…"
cd "$ROOT"
swift build -c release

BIN="$ROOT/.build/release/ghostie"
echo
echo "==> Done."
echo "    Binary:  $BIN"
echo "    Model:   $MODEL_FILE"
echo
echo "Next steps:"
echo "  1. Summaries use the Claude Code CLI — no API key. If you haven't"
echo "     already, run  claude  once in a terminal to log in."
echo "  2. Verify:                  $BIN doctor"
echo "  3. Smoke test:              $BIN test-record 15"
echo "  4. Run for real:            $BIN run"
echo "     Auto-start at login:     $BIN install-service"
echo
echo "On first capture, macOS will ask for Screen Recording + Microphone"
echo "permission for your terminal (or the background service). Grant both in"
echo "System Settings ▸ Privacy & Security, then run the command again."
