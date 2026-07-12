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

### 2. Hierarchical sliding-window LID

**Partially landed (accuracy pass, 2026-07):** long VAD segments are now
split into equal ≤ `cs.maxDetectMs` (default 8 s) chunks that are detected
independently (`LanguageSegmenter.splitForDetect`), so a switch inside one
long segment is no longer averaged into a single label and the LID's 30 s
slice cap no longer silently hides the tail. The same pass also made
`ServerWhisperLID` return the full renormalized `language_probabilities`
posterior (Nordic look-alike mass folded *before* the argmax —
`restrictedPosterior`), and fixed `WhisperLID.spread` so a weak top-1 can
never invert into evidence against itself. What remains here is the finer
*overlapping* sliding window + change-point detection:

- Coarse pass: one `identifier.identify` per ≤ maxDetectMs chunk (today's path).
- Fine pass: re-LID with `cs.lidWindowMs` × `cs.lidHopMs` (default 1500 ×
  500) inside segments where either `segment.durationMs >
  intraSegmentRefineMs` (default 4000) OR the coarse top1−top2 margin is
  ≤ `intraSegmentMarginThreshold` (default 0.15).
- Detect language change points on the fine-pass posterior, then run them
  through the existing snap-to-silence rule
  (`CodeSwitchTranscriber.snapBoundaries`) before they become run
  boundaries.
- CUSUM-style change-point detector with `cs.minDwellMs` (default 1500)
  prevents half-second blips from breaking sentences.

The selftest for this case already exists in spirit (the 3-language fixture
and the snap test); add a sliding-window mock that emits a known posterior
timeline.

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

### 5. Settings UI: rich language picker

The mode popup is binary (single / sv+en). With N languages on disk,
a multi-select picker keyed off `InstalledModels.languages` is more
honest. The popup's write path is already a one-liner — change it to a
multi-select and write `cs.languages` accordingly.

Adjacent: surface the per-language prompt fields (today only `prompts["sv"]`
/ `prompts["en"]` are in the default map; the UI can't yet edit a `prompts`
entry for a third language).

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
