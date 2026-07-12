# Code-switching v2 — follow-ups

What landed in `feat(codeswitch): v2 — LID-first, N-language, snap-to-silence,
re-route verification` (this branch) and what's left. Everything below
requires either hardware (ONNX runtime, audio recordings) or domain choices
that need a human in the loop.

## High priority — finish the v2 architecture

### 1. Wire ONNX Runtime + VoxLingua107 LID

The protocol seam is in place (`LanguageIdentifier`, `VoxLingua107LID`);
`isReady` is hard-coded to `false` so the segmenter falls through to
`WhisperLID`. To turn the dedicated LID on:

- Add `onnxruntime-swift-package-manager`
  (`https://github.com/microsoft/onnxruntime-swift-package-manager`) as a
  SwiftPM dependency in `Package.swift`. Verify it works under the project's
  Swift 5 language mode (`CLAUDE.md` is explicit: do **not** switch to
  `.v6`).
- Verify universal-binary support for the notarized `.dmg`
  (`scripts/build-app.sh` already lipo's `whisper-cli`; mirror that for the
  ORT framework). Confirm the framework is signable and notarizes.
- Pick the actual model file. VoxLingua107 ECAPA-TDNN exports from the
  SpeechBrain community are the obvious starting point; verify Apache-2.0
  license terms on the export you choose. Target size budget: ~50–80 MB.
- Register the model in `Models.swift` alongside the whisper models, with a
  Hugging Face URL the existing `ModelDownloader` can stream + SHA-verify.
- Implement `VoxLingua107LID.identify(...)`:
  - Convert Int16-LE Data → Float32 normalized buffer
  - Apply VoxLingua107's expected pre-processing (mean-stddev, possibly
    mel filterbank — check the export's signature)
  - Run the ORT session, get logits over 107 languages
  - Restrict to `restrict`, renormalize via log-sum-exp, return log-probs
- Flip `VoxLingua107LID.isReady` to:
  `frameworkLoadable && FileManager.default.fileExists(atPath: modelPath)`

When `isReady` is true, `LanguageSegmenter.defaultIdentifier` picks ONNX
LID automatically; nothing else in the pipeline changes. Doctor already
reports the active identifier (`description` getter).

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

### 6. Doctor — flag KB-Whisper-only English

When the only English-capable model installed is KB-Whisper, the
Swedish-biased LID head will mislabel English audio. Doctor should
explicitly warn: "no English-capable model installed; English audio will be
decoded by KB-Whisper (Swedish-biased)." Cheap to add; meaningful for
users who only run `--codeswitch --no-en` or similar.

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
- `Config.requiredModelPaths` is still around as a backward-compat shim.
  Once Settings + doctor + `cmdFetchModels` all read from
  `effectiveModelPath(for:installed:)` (most already do), it can be
  removed.
