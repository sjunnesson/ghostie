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

## Invoked, not bundled

### Claude Code CLI (`claude`)

Summarization shells out to the `claude` CLI using the user's own existing
Claude Code login. The CLI is **not** bundled or redistributed with Ghostie
and is governed by Anthropic's own terms of service. No Anthropic API key is
used or stored by Ghostie.

---

If you redistribute Ghostie (especially the self-contained `.dmg`), keep this
file and the bundled upstream license files intact alongside the binaries.
