#!/usr/bin/env bash
# Ghostie setup: installs whisper.cpp, downloads a model, builds the app.
set -euo pipefail

MODEL="${1:-base.en}"   # tiny.en | base.en | small.en | medium.en | large-v3
MODELS_DIR="$HOME/.ghostie/models"
MODEL_FILE="$MODELS_DIR/ggml-${MODEL}.bin"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Ghostie setup (model: ${MODEL})"

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
echo "  1. Set your Anthropic key:  export ANTHROPIC_API_KEY=sk-ant-..."
echo "     (or add it to ~/.ghostie/config.json)"
echo "  2. Verify:                  $BIN doctor"
echo "  3. Smoke test:              $BIN test-record 15"
echo "  4. Run for real:            $BIN run"
echo "     Auto-start at login:     $BIN install-service"
echo
echo "On first capture, macOS will ask for Screen Recording + Microphone"
echo "permission for your terminal (or the background service). Grant both in"
echo "System Settings ▸ Privacy & Security, then run the command again."
