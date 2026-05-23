# Code-switching v2: LID-first, N-language transcription

Re-architecture brief for the multi-language path. Optimization target:
**transcript fidelity on mixed-language meeting audio**. The shape changes from
"VAD → per-segment whisper-LID → smooth → decode" to "**dedicated LID over the
whole track → chunk by language → decode each chunk with that language's
model → stitch back**". The set of allowed labels is **exactly the set of
per-language whisper models the user has on disk** — 1, 2, or N — so config
drift and "configured for sv but no Swedish model" disappear by construction.

Implementation complexity, extra disk, longer processing time, and one new
binary dependency (ONNX Runtime) are acceptable costs if they improve the
transcript. The non-negotiable constraint is unchanged: **nothing leaves the
machine during detection and transcription**. Every model runs locally; the
one-time model fetch from Hugging Face is the only network in the path.

## Why this shape

The current pipeline (`code-switching.md`) wedges language ID into whisper's
side-channel `--detect-language` head, run per VAD segment, on PCM that has to
be sliced to a temp WAV because `--detect-language` ignores `--offset-t`. Three
things break at the edges:

- Whisper's LID is *unreliable on short audio* — exactly the regime where
  code-switching matters. The 1.5 s `minDetectMs` floor is itself a workaround
  for that, and it costs every switch shorter than 1.5 s.
- Detection is *per VAD segment*, so a sentence that starts Swedish and ends
  English is one segment with one label.
- The smoother is *hardwired binary* (`Array(config.languages.prefix(2))` in
  `Smoother.swift:83-85`, a literal `other()` helper at `Smoother.swift:96-98`)
  — there is no representation for a third language at all.

Lifting LID out of whisper and running it as a *first-class pass over the full
track* fixes all three: the LID model is purpose-built for short audio, the
output is a frame-level posterior timeline that can change *inside* a VAD
segment, and the label set is whatever languages we ask the model about.

## Pipeline

```
                 ┌──────── load installed models → language whitelist
                 │
Me.wav    ──► LID(full track) ──► language timeline ──► snap-to-VAD ──► chunks[lang]
                                                                            │
Part.wav  ──► LID(full track) ──► language timeline ──► snap-to-VAD ──► chunks[lang]
                                                                            │
                                                                            ▼
                                              ┌─ stitch lang_1 ─► whisper(model_1, --language lang_1)
                                              ├─ stitch lang_2 ─► whisper(model_2, --language lang_2)
                                              └─ stitch lang_N ─► whisper(model_N, --language lang_N)
                                                                            │
                                                                            ▼
                                              re-LID each decoded run ─► verify language ─► (route + redo if wrong)
                                                                            │
                                                                            ▼
                                              map back to original timeline → TranscriptCleaner → merge by timestamp
```

Everything from `stitch` rightward is current code, generalized to N
languages. Everything left of `stitch` is new.

## 1. The language whitelist comes from the disk, not config

Today: `codeSwitch.languages: ["sv","en"]` is configured, and `modelPerLanguage`
is configured, and the two can disagree, and the resolver has multiple tiers
(`LanguageSegmenter.swift:187-202`) that try to recover. The whole class of
"works for me but my colleague's config crashes" bugs comes from this.

Replace with: a **single discovery pass** at runtime that scans
`~/.ghostie/models/` (and `Ghostie.app/Contents/Resources/` for the bundled
build) for known whisper models, builds the map `language → modelPath`, and
that map IS the whitelist. The user installs `kb-whisper-large` → Swedish is
on. They `rm` it → Swedish is off, no config edit. They install a German
fine-tune → German turns on. `Models.swift` becomes a registry of known
fine-tunes per language; new entries are pull-requestable without touching
the pipeline.

```swift
/// Installed-on-disk view. Drives the language whitelist, doctor output,
/// Settings model picker, and codeswitch enable-flag. The whole pipeline reads
/// from this — `codeSwitch.languages` is gone.
struct InstalledModels {
    /// language code → resolved GGML path. Empty == no language available.
    let perLanguage: [String: String]
    /// Decoder model picked per language (one entry per `perLanguage` key).
    func model(for lang: String) -> String? { perLanguage[lang] }
    /// Languages this install can decode. Drives the LID model's restrict-set.
    var languages: [String] { Array(perLanguage.keys).sorted() }
}
```

Registry expectations (`Models.swift`, expanded):

- Each registered `Model` carries `language: String` and `family: String` (so a
  user can install multiple Swedish fine-tunes and pick one in Settings).
- The registry is the only place that knows about KB-Whisper / large-v3 /
  NB-Whisper / etc. The pipeline reads `InstalledModels`, not the registry.

**Behavioural consequence:** the `codeSwitch.enabled` flag goes away. There is
only one path. With one model installed it's exactly today's single-language
path (LID is skipped; the one available label is used). With two or more, the
new pipeline runs.

## 2. Dedicated short-segment LID

Replace whisper-as-LID with a purpose-built spoken-LID model run locally via
ONNX Runtime. Concrete pick: **SpeechBrain VoxLingua107 ECAPA-TDNN**
(Apache-2.0, ~26M params, 107 languages, strong on sub-3 s utterances; ONNX
exports exist in the community and are reproducible). It accepts a raw float
buffer and returns a posterior over its 107 labels, which we restrict to
`InstalledModels.languages` and renormalize.

Why this and not the alternatives:

- **Whisper's encoder + language head.** Same model that's already on disk,
  no new dependency. *But* its short-audio degradation is the original
  problem; even via the C API rather than the CLI, the head is still trained
  as a side task. Don't reuse it.
- **NVIDIA TitaNet-LID.** Comparable accuracy; NeMo-format with a more
  involved ONNX export and a license that needs re-reading per release.
  Acceptable fallback; not the default.
- **fastText `lid.176.ftz`.** Text-only. Useful for *post-decode*
  verification (§5), not for primary audio LID.
- **Python sidecar.** Cut. Breaks the notarized self-contained `.dmg`,
  expands the privacy surface, and the Mac install story stops being one
  thing. If ONNX export ever proves infeasible, fall back to tightened
  whisper-LID with adaptive `minDetectMs` and explicit confidence
  thresholds — not a second runtime.

Interface:

```swift
protocol LanguageIdentifier {
    /// Posterior over `restrict` for one audio window. Sums to 1.
    func identify(_ pcm: UnsafeBufferPointer<Float>,
                  sampleRate: Int,
                  restrict: [String]) throws -> [String: Double]
}

struct VoxLingua107LID: LanguageIdentifier { /* ORT session, mean-stddev norm */ }
```

ONNX Runtime ships a Swift Package; binary framework, signed, ~30 MB universal.
Bundle inside `Ghostie.app/Contents/Frameworks/` and resolve via
`Config.bundledResource(_:)` so the `.dmg` path stays self-contained. Verify
SwiftPM-mode-v5 compatibility (per `CLAUDE.md`'s "don't switch to .v6"
constraint) before merging the dependency.

## 3. Full-track detection with hierarchical sliding

The user's framing — "run LID on the full audio, pull out the chunks" — is the
right pipeline shape, but a naive 0.25 s hop across a 60-minute call is ~14 400
inferences per track, which is real CPU even on Apple Silicon. **Hierarchical**
detection keeps the quality and pays for the easy cases cheaply:

1. **VAD pass** as today: `LanguageSegmenter.segments(for:)` returns
   `[VADSegment]`. Free; same model, same code.
2. **Coarse LID per VAD segment** at one inference per segment. Cheap.
3. **Fine LID inside segments** that are either (a) longer than
   `intraSegmentRefineMs` (default 4000) *or* (b) below
   `intraSegmentMarginThreshold` (default top1 − top2 ≤ 0.15). Sliding window
   1.5 s × 0.5 s hop, restricted to `InstalledModels.languages`.
4. **Change-point detection** on the frame-level posterior inside refined
   segments: a CUSUM-style detector on the log-likelihood ratio, with a
   minimum dwell time of `minDwellMs` (default 1500) so a half-second blip
   doesn't break a sentence in two.
5. **Snap each change point to silence** (§4). Boundary placement is what
   makes mid-sentence switches *transcribable*, not just *labelable*.

Counts per 60-minute call, two tracks: ~600 VAD segments per track,
~50–150 refined → maybe 5 000 inferences total per call. At ~10 ms/inference
on Apple Silicon CPU with ECAPA-TDNN that's about a minute. Within the "note
before the call hangs up" budget.

Numerical care: **all probability math is in log-space from the start.** The
N=2 case today (`Smoother.multiply` / `normalize` at `Smoother.swift:174-186`)
gets away with linear arithmetic; N≥4 with confident priors underflows. Write
once, never deal with this again.

## 4. Snap-to-silence boundary rule

A language change point reported by the LID is correct in *time*, not in
*audio*. Placing the boundary exactly there cuts mid-syllable; the decoder
then emits a duplicated half-word on each side or, worse, a hallucinated
prefix. The fix:

- For each LID change point `t`, find the nearest energy trough ≥ `snapMinMs`
  (default 80 ms) below `snapEnergyDb` (default −40 dBFS) within `snapSearchMs`
  (default 1500) of `t`.
- If a trough exists, place the boundary at its centre.
- If no trough exists within the window, **do not split.** The whole chunk
  stays one language — the dominant label by frame-count over that span.
  Forcing a split inside continuous speech is worse than a single
  misattributed word.

Energy detection runs on the same 16 kHz mono PCM already in memory
(`AudioStitcher.readPCM`), so no new I/O. Implement as a 20 ms RMS window with
a hysteretic threshold to ignore tiny dips.

## 5. Per-language decode (mostly current code, generalized)

Everything from "stitch by language" onward stays. Generalize three things:

- **`prompts: [String: String]`** keyed by language replaces `promptSv` /
  `promptEn`. `prompt(for:)` becomes `prompts[lang] ?? ""`, not the silent
  `lang == "sv" ? promptSv : promptEn` (`Config.swift:439-441`, latent bug
  for any 3-language config today). Migrate `promptSv`/`promptEn` from old
  configs on load (`Config.init(from:)` already uses
  `decodeIfPresent ?? default`, see the pattern at `Config.swift:156-189`;
  add a one-time backfill there).
- **`modelPerLanguage`** stays a map but is *populated from
  `InstalledModels.perLanguage`* at runtime; the config field becomes an
  *override* layer for advanced users (point sv at a different fine-tune than
  the default registry pick).
- **Stitching, offset table, silence pads, `--max-context 0`, the boundary
  dedupe** (`CodeSwitchTranscriber.swift:60-179`) are untouched. They are
  language-agnostic already; they just iterate over N entries instead of 2.

Serial-within-track decode keeps peak RAM at one model. Across tracks: still
serial by default; parallelize only behind a flag, because the two whisper
processes will each Metal-allocate a fresh ~1.5 GB and a 16 GB Mac will swap.

## 6. Post-decode verification (re-LID, not lexical)

After decoding, **re-run the LID on each decoded run's original audio** (we
have the boundaries, we have the PCM in memory). If the LID's confident
top-1 disagrees with the routed language by more than `verifyMarginDb`
(default 0.20 log-prob), re-route that single run to the other model and
re-decode. Log the re-route so `ghostie diagnose-detect` surfaces it.

Why not a lexical / script check (the previous plan's choice): for related
languages (sv↔no, en↔nl, es↔pt) lexical signals alias under script and
short-word frequency. Re-running the LID on the audio uses the same evidence
the routing decision was made on, just at the resolution of the final run
boundary — no new model, no new failure mode.

## 7. N-way smoother

Replace `Smoother`'s binary core with an N-language one:

- **Likelihood** `P(det | lang)` = the LID posterior, restricted to
  `InstalledModels.languages`, renormalized. Low confidence → near-uniform.
- **Per-track smoothing**: median + duration-aware hysteresis (the
  `minSwitchSegments` OR `minSwitchMs` rule at `Smoother.swift:240-261` is
  good; keep it). Operate on the argmax of distributions; ties resolve to the
  *current run's* language so a brief foreign token stays a loanword.
- **Cross-track prior**: keep "most recent confident interval in the other
  track ending at or before `t`, within `priorLookbackMs`". With N labels,
  the prior is `[recent: strength, others: (1 − strength) / (N − 1)]`. With
  no recent cross-track info, weak base-rate `[dominantLanguage: 0.55,
  others: 0.45 / (N − 1)]`. `dominantLanguage` stays a config field; default
  to the most-segments-seen language over the past 60 days
  (`~/.ghostie/recents.json`) rather than a hard-coded `"en"`, so the
  tiebreaker matches the user's actual call mix.
- **Two-pass structure stays.** Pass 2 reads from Pass 1 (preliminary, not
  refined) — no within-call feedback loop. The current discipline at
  `CodeSwitchTranscriber.swift:46-49` is correct; preserve it byte-for-byte.

`Smoother` becomes pure of any `prefix(2)` / `other(_:)` references. The
existing selftest at `main.swift:496-597` ports to N labels with no
fundamental change: every `["sv","en"]` literal becomes a parameter.

## Configuration

`CodeSwitchConfig` collapses considerably:

```swift
struct CodeSwitchConfig: Codable {
    // Whitelist *override*. Empty (default) = use InstalledModels.languages.
    var languages: [String] = []

    // Decoder *override*, layered on top of InstalledModels.perLanguage.
    var modelPerLanguageOverride: [String: String] = [:]

    // Prompt map keyed by language; resolved by prompt(for:). promptSv /
    // promptEn migrate on load (back-compat layer in init(from:)).
    var prompts: [String: String] = [
        "sv": "Affärssamtal på svenska. Termer: Ingka, Xplore, IKEA, IFB.",
        "en": "Business call in English. Terms: Ingka, Xplore, IKEA, IFB, MCP, ACP."
    ]

    // Smoother knobs (unchanged shapes; N-language semantics).
    var dominantLanguage: String = "en"
    var crossTrackPriorStrength: Double = 0.75
    var priorLookbackMs: Int = 8000
    var smoothingWindowMe: Int = 4
    var smoothingWindowParticipants: Int = 4
    var minSwitchSegments: Int = 2
    var minSwitchMs: Int = 2500
    var maxFillGapMs: Int = 4000
    var runPaddingMs: Int = 200
    var silencePadMs: Int = 500

    // LID knobs.
    var lidWindowMs: Int = 1500
    var lidHopMs: Int = 500
    var intraSegmentRefineMs: Int = 4000
    var intraSegmentMarginThreshold: Double = 0.15
    var minDwellMs: Int = 1500
    var snapMinMs: Int = 80
    var snapEnergyDb: Double = -40
    var snapSearchMs: Int = 1500
    var verifyMarginDb: Double = 0.20

    // KB variant stays a Swedish-only knob, gated on "sv" being present.
    var kbWhisperVariant: String = "standard"
}
```

`enabled` is *gone*. So is the hard-coded `["sv","en"]` default. So is
`minDetectMs` (no longer relevant — LID handles short audio natively).
`promptSv` / `promptEn` migrate via `decodeIfPresent` in `init(from:)`
(see existing pattern, `Config.swift:392-417`).

`ghostie doctor` reports:

- The detected LID framework and model paths.
- `InstalledModels.perLanguage` (the actual whitelist this run will use).
- Any `modelPerLanguageOverride` entries that don't resolve on disk → ✗.
- The resolved `prompts` map.
- Per-language SHA verification still runs against the registered model
  (`Models.required(for:)` becomes `Models.installed()` + a "missing
  recommended" hint).

## Definition of done

Extend `ghostie selftest` with fixtures under `Tests/Fixtures/`. The existing
audio-free selftest at `main.swift:496-597` keeps running everywhere; the
audio cases are skipped cleanly when fixtures are absent (per CLAUDE.md
policy).

1. **LID accuracy on short chunks.** A labelled corpus of sub-2 s
   mono-language clips across at least 4 configured languages. Assert the
   new identifier's per-clip accuracy beats the old whisper-`--detect-language`
   baseline by a measured delta. Keep the baseline path available behind a
   debug flag for regression.
2. **Intra-sentence switch.** A single utterance switching language
   mid-sentence with no silence at the LID boundary, plus a parallel fixture
   *with* a 200 ms silence at the boundary. Assert: with silence, the
   pipeline splits within ±50 ms; without silence, it either snaps to the
   nearest trough or refuses to split — never mid-syllable.
3. **Three-plus languages.** A fixture mixing at least three languages
   (sv/en/de or sv/en/no). Assert each region is decoded by its language's
   model, with no leaked tokens across run boundaries.
4. **N-way cross-track prior.** Reuse current paired fixtures, add a
   three-language version: an ambiguous segment on Me resolves toward
   whichever language Participants was most recently speaking, even when
   that's the third language.
5. **Post-decode re-route.** A fixture engineered so the smoother picks the
   wrong language for one run. Assert the verification pass detects and
   re-decodes it.
6. **Robustness against tonal audio.** A fixture of music + DTMF + silence.
   Assert: no run is produced (everything `unknown` or zero-confidence;
   smoothing absorbs it; no language gets a chunk).
7. **Codec artifacts.** A fixture re-encoded through Opus 16 kbps → decoded
   back to 16 kHz mono, then a clean version. Assert the language labels
   agree between the two within `intraSegmentMarginThreshold`.
8. **Privacy.** Block the network during the test and confirm a fully local
   run (Ollama summarizer) produces a complete transcript end-to-end. Audio
   + transcript never leave; only the Claude provider path is allowed to
   send the *text*, and only when explicitly selected.
9. **One-model install.** With exactly one whisper model installed and the
   LID framework present, the pipeline runs the single-language path
   byte-for-byte equivalent to today (no LID work performed, no stitching,
   `Transcriber.swift` flow unchanged).
10. **Zero-model install.** Doctor surfaces "no whisper models installed"
    and the pipeline refuses to start a call; selftest asserts the error
    message names the missing language families.

Quality bar for the merged transcript: each language gets its best
locally-available model, switch boundaries land on real silence troughs,
no mid-syllable cuts, no regression in processing time large enough to
break the "note before the call hangs up" promise.

## What stays as-is

The point of the re-architecture is to fix the LID and the language whitelist
without disturbing what already works:

- `Pipeline.swift`'s clean-per-track then merge-by-timestamp flow.
- `TranscriptCleaner.swift` (the per-track hallucination guard).
- `AudioStitcher` (`AudioStitcher.swift`) — native 16 kHz mono Int16 PCM
  slicing with an offset table. Generalized to N languages without changes
  to the file.
- `CodeSwitchTranscriber`'s overall shape: preflight models, run the two
  tracks, stitch per language, decode, map back, dedupe boundaries
  (`CodeSwitchTranscriber.swift:28-58`).
- All-or-nothing backlog on failure (`CodeSwitchTranscriber.swift:7-26`,
  `Backlog.swift`).
- Config's `decodeIfPresent ?? default` resilience pattern
  (`Config.swift:156-189`, `392-417`). New keys add to that init body, not
  to a parallel decoder.

## Sequencing

Each step compiles and ships green selftest before the next begins. Order is
optimised for "every PR moves quality forward even if the next never lands":

0. **N-language correctness in existing code.**
   - `prompt(for:)` reads from a `prompts: [String: String]` map; migrate
     `promptSv`/`promptEn` in `Config.init(from:)`.
   - `Smoother` math goes log-space.
   - `Models.required(for:)` becomes `Models.installed()` plus a list of
     "recommended for your config" gaps.
   - No behaviour change for current sv/en users; clears the path.
1. **Installed-models registry.** `InstalledModels` discovery, doctor
   readout, Settings "languages I can transcribe" panel. The
   `codeSwitch.enabled` flag is deprecated but still honoured (the pipeline
   prefers `InstalledModels.languages.count >= 2`).
2. **ONNX Runtime integration + VoxLingua107 LID.** Bundle the framework,
   download the model, expose `LanguageIdentifier`. Swap into
   `LanguageSegmenter` at per-VAD-segment granularity first (no
   intra-segment refinement yet). Selftest case 1 must pass.
3. **N-language `Smoother`.** Remove `prefix(2)` and the `other()` helper.
   Selftest cases 3 and 4 must pass.
4. **Hierarchical refinement + snap-to-silence.** Intra-segment sliding
   window, CUSUM change-point, energy-trough snap. Selftest case 2 must
   pass; case 6 (tonal robustness) must pass.
5. **Post-decode re-LID verification.** Selftest case 5.
6. **Remove `codeSwitch.enabled`.** Behaviour collapses to the unified
   pipeline; the one-model install case (selftest 9) is the regression gate.

Each PR is independently testable. PR 0 ships latent-bug fixes for current
users immediately. PR 2 is the largest dependency change; the framework
bundling work happens there once.

## Edge cases and gotchas

- **`SwiftPM .v5` constraint.** `CLAUDE.md` is explicit: do not switch
  language mode to `.v6`. ONNX Runtime's Swift wrapper must work under
  `.v5` strict-concurrency — verify before adopting.
- **Universal binary.** ONNX Runtime ships separate arm64 and x86_64
  binaries. The notarized `.dmg` build needs both, lipo'd or shipped as a
  universal framework. `scripts/build-app.sh` already handles this for
  `whisper-cli`; mirror that.
- **First-launch download size.** The LID model (~50 MB) plus per-language
  whisper models is a real chunk on a fresh install. The Settings
  "Download models" flow already exists and handles this; the new
  registry just adds rows.
- **KB-Whisper Swedish bias still applies.** The LID drives chunking, but
  if the user has only KB-Whisper installed for a track that's actually
  English, decode will misbehave. Doctor flags "no English-capable model
  installed; English audio will be decoded by KB-Whisper (Swedish bias)"
  so the user can install large-v3 explicitly.
- **Empty tracks.** Already handled
  (`CodeSwitchTranscriber.swift:36-37`). The new pipeline preserves it: no
  speech → no LID work → empty result.
- **Music / DTMF / hold tone.** Both VAD and the LID can be fooled. The
  rule is: if the LID's top-1 confidence is below `minLIDConfidence`
  (default 0.40) across the whole VAD segment, drop the segment entirely.
  Selftest case 6 holds this line.
- **Cross-track timing skew.** Past-only lookup
  (`Smoother.swift:49-56`) is the right rule and stays — answering in
  English shouldn't retro-flip your Swedish question.
- **Cleaner re-validation.** Per-language batching means
  `TranscriptCleaner` sees less context. Cleaner loop / repetition
  thresholds need a regression fixture on stitched per-language output.
  Add to the existing cleaner selftest at
  `runTranscriptCleanerSelfTest()` rather than a parallel harness.

## Future, explicitly out of scope

- **whisper-server daemon** keeping models warm across calls. Eliminates
  the ~3 s per-model load. Adds lifecycle management; revisit if cold-
  start is the bottleneck after the rest lands.
- **Speaker-aware LID.** Two speakers on one track with different first
  languages will confuse a frame-level LID at the speaker boundary. A
  diariser → per-speaker LID is the right answer, but not for v2.
- **Per-segment KB variant routing.** `standard` for clean prose,
  `strict` for verbatim quote regions. Architecturally clean given the
  registry; deferred until there's a demonstrated need.
