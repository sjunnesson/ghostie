# Third-Party Notices

Ghostie itself is licensed under the MIT License (see `LICENSE`). It also
relies on, and in the self-contained `.dmg` build redistributes, third-party
software and machine-learning models that carry their own licenses. Those
licenses are listed below and continue to apply to the relevant components.

## Bundled in the self-contained build (`build-app.sh --dmg`)

These are physically copied into `Ghostie.app/Contents/Resources` and therefore
redistributed with Ghostie:

### whisper.cpp (`whisper-cli`)

- Project: https://github.com/ggerganov/whisper.cpp
- Pinned version: `v1.8.4` (see `WHISPER_TAG` in `scripts/build-app.sh`)
- License: **MIT** — Copyright (c) The ggml authors
- Ghostie shells out to this binary for all speech-to-text; in the `.dmg` build
  a statically linked copy is bundled. The upstream `LICENSE` file is copied
  next to it in `Contents/Resources/whisper.cpp.LICENSE`.

### Silero VAD (`ggml-silero-v5.1.2.bin`)

- Source: https://huggingface.co/ggml-org/whisper-vad (mirrored from
  https://github.com/snakers4/silero-vad)
- License: **MIT** — see the Silero VAD repository for authoritative terms
- Voice-activity detection that suppresses silence-driven whisper hallucination.
  Small (~900 KB), so bundled directly rather than downloaded.

### ONNX Runtime (`Contents/Frameworks/libonnxruntime.dylib`)

- Source: https://github.com/microsoft/onnxruntime — the official
  `onnxruntime-osx-arm64` release binary, fetched by `scripts/build-app.sh`
  at build time and redistributed inside the `.app`.
- Copyright (c) Microsoft Corporation. License: **MIT** — the full text
  ships in the release archive and applies to the bundled dylib.
- Runs the speaker-embedding model locally for diarization (and the optional
  VoxLingua107 language identifier). Build with `GHOSTIE_BUNDLE_ORT=0` to
  omit it; Ghostie then falls back to any `libonnxruntime.dylib` the user has
  installed themselves, and to undiarized "Participants" labels if there is
  none.

## Downloaded at runtime by the user (not redistributed by this project)

These are fetched on demand from their upstream source into
`~/.ghostie/models/`. Ghostie does not redistribute them; the user obtains
each file directly from the linked source under that source's license. The
download is SHA256-verified against the source's signed etag at download
time. The license noted is best-effort — the model card is the authoritative
terms.

| Component | Used for | Source | Fetched by | License |
|-----------|----------|--------|------------|---------|
| `ggml-base.en.bin` (~140 MB) | Default English transcription | https://huggingface.co/ggerganov/whisper.cpp | First-launch auto-download (Settings ▸ Transcription), `ghostie fetch-models`, or `scripts/setup.sh` | **MIT** (OpenAI Whisper) — https://github.com/openai/whisper |
| whisper-large-v3 (GGML) | English decode in code-switching | https://huggingface.co/ggerganov/whisper.cpp | Settings ▸ Download models, `ghostie fetch-models` | MIT (OpenAI Whisper) — see model card for authoritative terms |
| KB-Whisper-large (GGML) | Swedish decode in code-switching | https://huggingface.co/KBLab/kb-whisper-large (KBLab / National Library of Sweden) | Settings ▸ Download models, `ghostie fetch-models` | **Apache-2.0** (verified against the model card metadata, 2026-05-19) |
| `wespeaker_en_voxceleb_resnet34_LM.onnx` (~27 MB) | Speaker embeddings for diarizing the Participants track | https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models (ONNX export of https://github.com/wespeaker/wespeaker) | First-launch auto-download, `ghostie fetch-models --diarization` | **Apache-2.0** (WeSpeaker) — see the model card for authoritative terms |

## Vendored source

### ONNX Runtime C API headers (`Sources/CONNXRuntime/include/`)

`onnxruntime_c_api.h` and `onnxruntime_ep_c_api.h` are vendored verbatim
from ONNX Runtime 1.27.1 — Copyright (c) Microsoft Corporation, **MIT
License** (https://github.com/microsoft/onnxruntime). Declarations only:
Ghostie never *links* the ONNX Runtime library — it is dlopened at runtime.
Released `.app` builds bundle the official Microsoft dylib (see "ONNX
Runtime" above); a build made with `GHOSTIE_BUNDLE_ORT=0` instead uses
whatever the user installed themselves (e.g. `brew install onnxruntime`,
MIT). Either way the MIT notice covers redistribution.

### VoxLingua107 ECAPA-TDNN language-ID model (optional, user-generated)

`scripts/export-voxlingua-lid.py` converts
https://huggingface.co/speechbrain/lang-id-voxlingua107-ecapa
(**Apache-2.0**, SpeechBrain) into a local ONNX file on the user's machine.
Ghostie does not redistribute the model or its weights.

## Invoked, not bundled

### Claude Code CLI (`claude`)

Summarization shells out to the `claude` CLI using the user's own existing
Claude Code login. The CLI is **not** bundled or redistributed with Ghostie
and is governed by Anthropic's own terms of service. No Anthropic API key is
used or stored by Ghostie.

---

If you redistribute Ghostie (especially the self-contained `.dmg`), keep this
file and the bundled upstream license files intact alongside the binaries.
