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

### `ggml-base.en.bin` speech model

- Source: https://huggingface.co/ggerganov/whisper.cpp
- Origin: OpenAI Whisper model weights converted to the GGML format.
- License: **MIT** (OpenAI Whisper). See the OpenAI Whisper repository:
  https://github.com/openai/whisper
- Bundled into the `.dmg` so first-run transcription works with no download.

## Downloaded at runtime by the user (not redistributed by this project)

These are fetched on demand into `~/.ghostie/models/` by the user (Settings ▸
Download models, `ghostie fetch-models`, or `scripts/setup.sh`). Ghostie does
not redistribute them; the user obtains them directly from the source under
that source's license. The license noted is best-effort — the model card is
the authoritative terms.

| Component | Used for | Source | License |
|-----------|----------|--------|---------|
| whisper-large-v3 (GGML) | English decode in code-switching | huggingface.co/ggerganov/whisper.cpp | MIT (OpenAI Whisper) — see model card for authoritative terms |
| KB-Whisper-large (GGML) | Swedish decode in code-switching | https://huggingface.co/KBLab/kb-whisper-large (KBLab / National Library of Sweden) | **Apache-2.0** (verified against the model card metadata, 2026-05-19) |
| Silero VAD (`ggml-silero-*`) | Voice-activity detection | https://github.com/snakers4/silero-vad | MIT — see repository for authoritative terms |

## Invoked, not bundled

### Claude Code CLI (`claude`)

Summarization shells out to the `claude` CLI using the user's own existing
Claude Code login. The CLI is **not** bundled or redistributed with Ghostie
and is governed by Anthropic's own terms of service. No Anthropic API key is
used or stored by Ghostie.

---

If you redistribute Ghostie (especially the self-contained `.dmg`), keep this
file and the bundled upstream license files intact alongside the binaries.
