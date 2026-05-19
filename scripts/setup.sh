#!/usr/bin/env bash
# Ghostie setup: installs whisper.cpp, downloads a model, builds the app.
set -euo pipefail

# Args (order-independent):
#   <model>            ggml model name for the single-language path
#   --vad              also fetch the Silero VAD model
#   --codeswitch       also fetch the dual-model code-switching pair
#                      (KB-Whisper-large <variant> + whisper-large-v3)
#   --kb-variant <v>   KB-Whisper Stage-2 variant: standard | subtitle | strict
MODEL="base.en"   # tiny.en | base.en | small.en | medium.en | large-v3
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
case "$KB_VARIANT" in
  standard|subtitle|strict) ;;
  *) echo "!! --kb-variant must be standard | subtitle | strict (got '$KB_VARIANT')"; exit 1 ;;
esac
MODELS_DIR="$HOME/.ghostie/models"
MODEL_FILE="$MODELS_DIR/ggml-${MODEL}.bin"
VAD_FILE="$MODELS_DIR/ggml-silero-v5.1.2.bin"
KB_FILE="$MODELS_DIR/ggml-kb-whisper-large-${KB_VARIANT}-q5_0.bin"
ENV3_FILE="$MODELS_DIR/ggml-large-v3-q5_0.bin"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Ghostie setup (model: ${MODEL}$([ "$WANT_VAD" = 1 ] && echo ', + Silero VAD')$([ "$WANT_CODESWITCH" = 1 ] && echo ", + code-switching [KB ${KB_VARIANT}]"))"

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

# 2c. Optional code-switching dual-model pair. KB-Whisper-large for Swedish
#     runs, vanilla whisper-large-v3 for English runs.
#
#     KB-Whisper variant → GGML location on Hugging Face (verified May 2026):
#       standard = the *default* Stage-2 model, GGML lives on `main`
#                  (the `standard` *tag* exists but carries no GGML)
#       strict   = `strict` tag, ships ggml-model-q5_0.bin
#       subtitle = HF-format only upstream — no prebuilt whisper.cpp GGML
if [ "$WANT_CODESWITCH" = 1 ]; then
  case "$KB_VARIANT" in
    standard) KB_REV="main" ;;
    strict)   KB_REV="strict" ;;
    subtitle)
      echo "!! KB-Whisper 'subtitle' has no prebuilt whisper.cpp GGML upstream."
      echo "   Use --kb-variant standard (default) or strict, or convert the"
      echo "   subtitle revision to GGML yourself and point"
      echo "   codeSwitch.modelPerLanguage.sv at that file."
      echo "   See https://huggingface.co/KBLab/kb-whisper-large"
      exit 1 ;;
  esac
  KB_URL="https://huggingface.co/KBLab/kb-whisper-large/resolve/${KB_REV}/ggml-model-q5_0.bin"
  ENV3_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"

  if [ ! -f "$KB_FILE" ]; then
    echo "==> Downloading KB-Whisper-large (${KB_VARIANT}) …"
    curl -fL --progress-bar "$KB_URL" -o "$KB_FILE" \
      || { echo "!! KB-Whisper download failed"; rm -f "$KB_FILE"; exit 1; }
  else
    echo "==> KB-Whisper-large (${KB_VARIANT}) already present: $KB_FILE"
  fi

  if [ ! -f "$ENV3_FILE" ]; then
    echo "==> Downloading whisper-large-v3 (q5_0) …"
    curl -fL --progress-bar "$ENV3_URL" -o "$ENV3_FILE" \
      || { echo "!! whisper-large-v3 download failed"; rm -f "$ENV3_FILE"; exit 1; }
  else
    echo "==> whisper-large-v3 already present: $ENV3_FILE"
  fi

  # Code-switching segments with VAD, so the Silero model is required.
  if [ ! -f "$VAD_FILE" ]; then
    echo "==> Downloading Silero VAD model (required by code-switching) …"
    curl -fL --progress-bar \
      "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" \
      -o "$VAD_FILE" \
      || { echo "!! VAD download failed — code-switching needs it"; exit 1; }
  fi

  echo "==> Smoke-testing both code-switching models…"
  WCLI="$(command -v whisper-cli || command -v whisper-cpp || true)"
  if [ -n "$WCLI" ]; then
    "$WCLI" -m "$ENV3_FILE" --help >/dev/null 2>&1 \
      && echo "    whisper-large-v3 loads OK" || echo "    (could not verify large-v3)"
    "$WCLI" -m "$KB_FILE" --help >/dev/null 2>&1 \
      && echo "    KB-Whisper-large loads OK" || echo "    (could not verify KB-Whisper)"
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
if [ "$WANT_CODESWITCH" = 1 ]; then
  echo "    Code-switching models:"
  echo "      sv: $KB_FILE"
  echo "      en: $ENV3_FILE"
  echo "    Enable it in Settings (or set codeSwitch.enabled=true in config.json)."
fi
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
