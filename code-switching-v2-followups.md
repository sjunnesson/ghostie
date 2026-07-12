# Code-switching v2 — follow-ups

What landed in `feat(codeswitch): v2 — LID-first, N-language, snap-to-silence,
re-route verification` (this branch) and what's left. Everything below
requires either hardware (ONNX runtime, audio recordings) or domain choices
that need a human in the loop.

## High priority — finish the v2 architecture

### 1. Wire ONNX Runtime + VoxLingua107 LID ✅ done (dlopen approach)

Landed differently from the sketch below — no SwiftPM binary dependency.
The vendored ONNX Runtime C API headers (`Sources/CONNXRuntime`, MIT) give
Swift the `OrtApi` table; `ORTRuntime.swift` dlopens `libonnxruntime.dylib`
at runtime (Homebrew, `Ghostie.app/Contents/Frameworks`, or
`GHOSTIE_ORT_DYLIB`) so builds and the `.dmg` stay dependency-free and the
LID is a zero-cost optional. `VoxLingua107LID.identify` is fully
implemented (Int16→Float32, in-graph features, softmax with look-alike
remap folded before the argmax, whitelist renormalization via
`restrictedPosterior`) and verified end-to-end against a live ORT session
(`ghostie lid-probe` + a synthetic model; posterior hand-checked exact).

Because no official ONNX export of the model exists,
`scripts/export-voxlingua-lid.py` converts
`speechbrain/lang-id-voxlingua107-ecapa` (Apache-2.0) locally — features
inside the graph, labels sidecar, PyTorch/ONNX parity check. Activation is
disk-driven: `brew install onnxruntime` + run the script; `ghostie doctor`
shows the active identifier. `GHOSTIE_BUNDLE_ORT=1 ./scripts/build-app.sh
--dmg` optionally bundles the dylib.

Remaining (needs a real mixed-language recording in front of a human):
routing-accuracy comparison vs `WhisperLID` on the fixture set in #3, and
a decision on hosting a converted model so `ModelDownloader` can fetch it
instead of requiring the local export.

### 2. Hierarchical sliding-window LID ✅ done

Coarse pass (≤ `cs.maxDetectMs` chunks) landed in the 2026-07 accuracy
pass; the fine pass is now in too (`LanguageSegmenter.fineDetections`):
inside chunks longer than `cs.intraSegmentRefineMs` (default 4000) or with
a coarse top1−top2 log-margin ≤ `cs.intraSegmentMarginThreshold` (default
0.15), the chunk is re-LID'd with `cs.lidWindowMs` × `cs.lidHopMs`
(default 1500 × 500) overlapping windows and a CUSUM change-point scan
(`LanguageSegmenter.changePoints`) splits it at sustained switches —
requiring accumulated log-likelihood-ratio evidence ≥ 2.0, dwell ≥
`cs.minDwellMs` (default 1500), and ≥ 2 corroborating windows, so a
single-window blip never breaks a sentence. Sub-span posteriors aggregate
(product in log space, renormalized) into one detection per span; the
smoother + snap-to-silence still own final boundary placement.

The fine pass only runs under a low-latency identifier
(`LanguageIdentifier.isLowLatency` — the ONNX VoxLingua107 LID; whisper
LIDs at ~1.2 s/window would multiply detect time by the window count).
Selftest: CUSUM scan over synthetic posterior timelines (mono, sustained
switch, blip, ambiguous, 3-language) plus an end-to-end detect() run with
a position-sniffing stub that must split a 10 s segment near the true 5 s
boundary.

### 3. Audio fixtures + end-to-end selftest assertions

The current selftest is entirely synthetic. Add `Tests/Fixtures/` recordings:

- `short_chunks_<lang>/` — labelled sub-2 s mono-language clips for at
  least 4 languages. Assertion: new LID's per-clip accuracy beats
  `WhisperLID` baseline.
- `intra_sentence_switch.wav` — single utterance switching language with
  no silence at the boundary, plus a paired `_with_silence` version with
  200 ms silence. Assertion: snap-to-silence places the cut within ±50 ms
  when silence exists; refuses to split (merges) when it doesn't.
- `three_languages.wav` — sv + en + de or sv + en + no. Assertion: each
  region decoded by its language's model.
- `cross_track_three.wav` — paired Me/Participants where an ambiguous Me
  segment resolves toward the third language via cross-track prior.
- `misrouted.wav` — engineered to make the smoother route one run to the
  wrong model. Assertion: post-decode re-LID flags + re-routes it.
- `music_dtmf_silence.wav` — assert: no runs produced, no language
  attributed.
- `opus_artifacts.wav` — clean + Opus-16kbps-and-back versions. Assert
  labels agree within `intraSegmentMarginThreshold`.

`runCodeSwitchSelfTest` already skips audio fixtures cleanly when absent;
extend it to run the asserts when present.

## Medium priority — quality / UX

### 4. Cleaner re-validation against per-language stitched output

`TranscriptCleaner`'s thresholds were tuned against full-track context.
Per-language batching shows the cleaner ~50% less context per pass.
Add a fixture under `runTranscriptCleanerSelfTest` that exercises the
loop-detector against a stitched-per-language transcript and confirms
the existing thresholds hold (or tune them).

### 5. Settings UI: rich language picker ✅ done

Settings ▸ Transcription now shows one checkbox per language (installed
languages ∪ explicit `cs.languages`; missing-model entries flagged),
writing the selection to `cs.languages`. The last language can't be
unchecked (an empty list means "everything installed", which would
paradoxically re-enable all). Advanced discloses one starter-sentence
field per active language, editing `codeSwitch.prompts[lang]` — a third
language's prompt no longer needs config.json.

### 6. Doctor — flag KB-Whisper-only English ✅ done

`cmdDoctor` now emits a failing row ("English-capable model — none
installed…") whenever a Swedish model is on disk with no model registered
for `en`.

### 7. Backlog re-runs across the v2 pipeline

The all-or-nothing failure contract is preserved
(`CodeSwitchTranscriber.swift:7-26`), but the backlog code in
`Backlog.swift` and `Pipeline.drain` should be exercised under a v2 path
where the LID model is missing on first attempt and arrives by the retry.
Add to `ghostie selftest` if possible; otherwise document a manual test
scenario in `code-switching.md`.

## Low priority — nice-to-haves

### 8. Confidence-gated cross-track prior

Skip Pass 2 cross-track refinement on segments where the local
detection's margin is already above a threshold. Reduces compute on the
easy cases. Measure before adding.

### 9. Per-language KB variant routing

Different parts of a call could route to different KB-Whisper variants
(`standard` for clean prose, `strict` for verbatim quotes). Architecture
already supports it via `modelPerLanguage` overrides; needs a per-run
heuristic to be useful.

### 10. whisper-server daemon

Keep models warm across calls. Eliminates ~3 s per-model load. Adds
lifecycle management to `Engine.swift` and a new doctor row. Worth
revisiting if cold-start ever becomes the bottleneck.

## Memory / cleanup

- The `LegacyPromptKeys` enum in `Config.swift` can come out after enough
  releases that no live config still has `promptSv`/`promptEn` on disk.
  Cite the release tag of v2-ship before deleting.
- ~~`Config.requiredModelPaths`~~ — already removed; every caller reads
  `effectiveModelPath(for:installed:)`.
