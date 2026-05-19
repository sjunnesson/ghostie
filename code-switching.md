# Code-switching transcription (sv ↔ en)

Implementation path for handling Swedish/English code-switching in Ghostie, fitted to the existing stack: Swift, whisper.cpp via `whisper-cli` subprocess, Silero VAD, two-track recording (Me + Participants), `TranscriptCleaner` post-pass.

## Problem

Whisper detects language once from the first ~30 seconds and locks it in for the whole file. Teams calls at Ingka are mostly English with Swedish mixed in (Swedish 1:1s, Nordic-only segments, side conversations, code-switched terms), and the lock is wrong whenever the first 30 seconds doesn't match the rest. When it's wrong, the minority language either gets translated into broken text in the other language or hallucinated as nonsense.

Ghostie currently exposes this via `config.language` with `auto` or a fixed ISO code. Both modes lose information on mixed audio.

## Approach

Replace the single-language pass per track with a per-segment pipeline:

1. VAD-segment each track into speech chunks
2. Detect language on each chunk (encoder + language head only, no decode)
3. Smooth detections into language-consistent runs
4. Transcribe each run with `--language` forced to the detected language
5. Stitch runs back into the track's transcript, then run `TranscriptCleaner` and merge tracks as today

Three practical choices made up front:

- **Two models, one per language.** Use vanilla whisper-large-v3 (GGML) for English runs and KB-Whisper-large (GGML) for Swedish runs. KB-Whisper is a fine-tune from whisper-large-v3 with strong Swedish gains but slight English regression, so routing English to the base model is especially important here: most call content is English, so the English path needs the best available model rather than a Swedish-tuned one. KB-Whisper still earns its place for the Swedish minority because plain whisper-large-v3 is meaningfully worse on Swedish. The cost is ~2 GB disk and an extra model-load per track; both are paid for by the accuracy gain on real Ingka calls. Batching by language (Phase 4) keeps model loads to one per language per track, not per run.
- **Per-track detection, cross-track smoothing.** VAD segmentation and per-segment language detection run independently on each track. The smoother then runs in two passes: a per-track median window first (the preliminary pass), then a cross-track Bayesian refinement that uses the *other* track's preliminary labels as a prior. When a participant just switched to Swedish, the prior on your next ambiguous segment shifts toward Swedish, which catches short minority-language switches that the per-track median misses. The split helps because each track has at most one active speaker (no cross-talk in per-segment detection) while the language *timeline* of the call is shared.
- **KB-Whisper variant selectable.** KB-Whisper ships in three Stage 2 variants: `standard` (balanced), `subtitle` (condensed, drops filler), and `strict` (verbatim, keeps filler). Default to `standard` for meeting notes since Claude's summary works best on clean prose. `strict` is exposed for compliance/legal scenarios where verbatim matters. `subtitle` for users who want shorter transcripts at the cost of some context. Each variant is a separate GGML file; setup picks one.

## Pipeline

```
Me.wav ─────► VAD ► detect ► smooth(median) ─┐
                                              │
                                              ├─► cross-track refine ─► runs[sv|en] ─► Me track
Part.wav ───► VAD ► detect ► smooth(median) ─┘                                 │
                                                                               ▼
                                                                  ┌─ stitch sv ─► KB-Whisper-<variant>
                                                                  │
                                                                  └─ stitch en ─► whisper-large-v3
                                                                               │
                                                                               ▼
                                                                  map back to timeline
                                                                               │
                                                                               ▼
                                                                   TranscriptCleaner
                                                                               │
                                                                               ▼
                                                                   (same for Participants)
                                                                               │
                                                                               ▼
                                                                   merge by timestamp ► summary
```

## Phase 0: ship the models

`scripts/setup.sh` currently pulls one whisper.cpp GGML model. The codeswitch path needs two:

- A KB-Whisper-large variant (~1 GB) for Swedish runs: `standard`, `subtitle`, or `strict`
- `ggml-large-v3-q5_0.bin` (~1 GB) for English runs

Each KB-Whisper variant is a separate GGML on Hugging Face under different revisions. Add a `--codeswitch` option that takes a variant flag and fetches both:

```bash
# scripts/setup.sh --codeswitch --kb-variant standard
case "$WHISPER_MODEL" in
  kb-whisper-large)
    REV="${KB_VARIANT:-standard}"   # standard | subtitle | strict
    URL="https://huggingface.co/KBLab/kb-whisper-large/resolve/${REV}/ggml-model-q5_0.bin"
    DEST="$MODELS_DIR/ggml-kb-whisper-large-${REV}-q5_0.bin"
    ;;
  whisper-large-v3)
    URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"
    DEST="$MODELS_DIR/ggml-large-v3-q5_0.bin"
    ;;
esac
```

Users can fetch multiple KB-Whisper variants if they want to switch between them at runtime without re-downloading. Total disk cost is ~2 GB per variant pair; ~4 GB if all three KB variants are kept on disk.

The existing `whisperModel` config key stays for users who don't enable codeswitch. If a user wants to fall back to single-model mode (e.g. an older Mac with disk pressure), the smoother and decoder still work with one model pointed at both languages in `modelPerLanguage`.

**Definition of done:** `./scripts/setup.sh --codeswitch --kb-variant standard` downloads both GGML files, and smoke tests confirm each model decodes a sample in its language: `whisper-cli -m kb-whisper-large-standard -f sv.wav -l sv` and `whisper-cli -m large-v3 -f en.wav -l en`.

## Phase 1: VAD-driven segmenter

Today whisper-cli is called with `--vad` and `--vad-model`, and whisper.cpp does VAD-aware decoding internally. For code-switching we need the segment boundaries *before* decoding so we can route each segment to a per-language pass.

Two options:

- **A. Shell out to whisper-cli with `--vad` and `--no-prints` to a JSON of segments.** Cheap and uses the same Silero model already on disk. But whisper.cpp's VAD-only mode still runs the encoder per segment, so it's wasteful if we only want timestamps.
- **B. Run Silero VAD directly in Swift via the ONNX runtime.** Faster, cleaner, gives us raw segment timestamps. Adds an ONNX dependency.

Go with **A** for v1 (no new dependency, ships in a week), document **B** as the speed optimization. With A, the call looks like:

```
whisper-cli -m <model> -f Me.wav \
  --vad --vad-model <silero> \
  --vad-threshold 0.5 \
  --vad-min-speech-duration-ms 250 \
  --vad-min-silence-duration-ms 350 \
  --output-json --no-prints \
  --detect-language
```

Parse the JSON to extract `[(start, end)]` per speech segment.

Swift sketch:

```swift
struct VADSegment {
    let start: TimeInterval
    let end: TimeInterval
}

struct LanguageSegmenter {
    let whisperCLI: URL
    let model: URL
    let vadModel: URL

    func segments(for wav: URL) throws -> [VADSegment] {
        let result = try runWhisperCLI(args: [
            "-m", model.path,
            "-f", wav.path,
            "--vad", "--vad-model", vadModel.path,
            "--vad-threshold", "0.5",
            "--vad-min-speech-duration-ms", "250",
            "--vad-min-silence-duration-ms", "350",
            "--output-json", "--no-prints",
            "--detect-language"
        ])
        return parseVADJSON(result.stdoutJSON)
    }
}
```

**Definition of done:** given a 30-minute mixed-language WAV, `segments(for:)` returns 50–500 segments with sensible boundaries and no segments shorter than 250 ms.

## Phase 2: per-segment language detection

For each VAD segment, run whisper-cli in detect-only mode on a slice of the audio. whisper-cli supports `--offset-t` (milliseconds from start) and `--duration-t` so you don't have to splice WAVs to disk:

```
whisper-cli -m <model> -f Me.wav \
  --offset-t <start_ms> --duration-t <duration_ms> \
  --detect-language --no-prints --output-json
```

The JSON includes the detected language and per-language log-probabilities. Capture both: the top label and the margin (top1 minus top2) is what the smoother uses.

```swift
struct LanguageDetection {
    let segment: VADSegment
    let top: String          // "sv", "en", …
    let confidence: Double   // softmax of the top logit
    let margin: Double       // top1 − top2 in log-space
}
```

Two things matter here:

- **Minimum segment length for reliable detection is ~1.5 s.** Anything shorter, mark as `unknown` and let the smoother fill it from neighbours. This is why backchannel "mm", "ja", "yeah" don't trigger fake switches.
- **Restrict the label set.** Pass `--language auto` but only consider sv/en in the smoother. If whisper-cli returns `no` (Norwegian) or `da` (Danish) on a short Swedish chunk, treat it as `sv` since the model regularly confuses Nordic languages on short audio. This is configurable as `languageWhitelist: ["sv", "en"]`.

**Definition of done:** running detection across all VAD segments of a known mixed call labels each segment with `sv`/`en`/`unknown` plus confidence, with no calls to the decoder.

## Phase 3: two-pass smoothing into language runs

Raw per-segment labels will flap and short segments will be unreliable. Smooth in two passes: first a per-track median + hysteresis to get *preliminary* labels for each track independently, then a cross-track Bayesian refinement that uses the *other* track's preliminary labels as a prior.

### Pass 1: per-track preliminary

1. Fill `unknown` segments from the nearest confident neighbour (within `maxFillGapMs`, default 4000).
2. Apply a sliding median over `smoothingWindow` segments (default 4 for both tracks).
3. Apply hysteresis: require `minSwitchSegments` consecutive opposite-language segments (default 2) to switch. Below that, treat as a brief loanword and keep the current language.

The output is a `LanguageTimeline` per track: a sequence of `(start, end, language, confidence)` intervals covering the speech portions of the track.

### Pass 2: cross-track Bayesian refinement

For each segment in track A, compute a refined label using both the local detection and a prior derived from track B's preliminary timeline:

```
P(lang | det, B) ∝ P(det | lang) × P(lang | B at time t)
```

- **Likelihood** `P(det | lang)`: softmax over the detection log-probs restricted to the language whitelist (sv, en). Sub-threshold confidence gives a near-uniform likelihood and the prior dominates.
- **Prior** `P(lang | B at time t)`: look up what track B was doing in the immediate past, not concurrent. Concurrent overlap is unreliable because A asking "ska vi switcha till engelska?" and B answering in English shouldn't push A's question toward English. Find the most recent confident interval in track B that *ended* at or before time t. If that interval is within `priorLookbackMs` (default 8000) of t, use its language. Otherwise fall back to a weak base-rate prior toward `dominantLanguage` (default `en`): 0.55 for the dominant language, 0.45 for the other. This is just strong enough to break ties for genuinely ambiguous local detections, and weak enough that any confident detection wins.

The prior strength is bounded:

```
P(matching lang | B = lang) = crossTrackPriorStrength   // default 0.75
P(opposing lang | B = lang) = 1 - crossTrackPriorStrength
```

At strength 0.5 the prior is neutral and Pass 2 is a no-op. At strength 1.0 it's absolute. Default 0.75 is strong enough to flip ambiguous segments but not strong enough to overwhelm a confident detection.

After computing the posterior per segment, re-run the median + hysteresis from Pass 1 over the refined labels. Then collapse adjacent same-language segments into runs and pad each run with `runPaddingMs` (default 200 ms) on each side to avoid clipping word boundaries.

### Sketch

```swift
struct LanguageRun {
    let language: String
    let start: TimeInterval
    let end: TimeInterval
    let segments: [VADSegment]
}

struct LanguageTimeline {
    let intervals: [(start: TimeInterval, end: TimeInterval, language: String, confidence: Double)]

    /// Most recent confident interval ending at or before `t`, within `withinMs`.
    func mostRecentEndingBefore(_ t: TimeInterval, withinMs: Int) -> String? { … }
}

struct Smoother {
    let window: Int
    let minSwitchSegments: Int
    let dominantLanguage: String
    let crossTrackPriorStrength: Double  // 0.5..1.0
    let priorLookbackMs: Int

    /// Pass 1: per-track preliminary smoothing.
    func preliminary(_ dets: [LanguageDetection]) -> LanguageTimeline { … }

    /// Pass 2: refine track A using track B's preliminary timeline as a prior.
    func refine(_ dets: [LanguageDetection], priorFrom otherTrack: LanguageTimeline) -> [LanguageRun] {
        let refined = dets.map { det -> LanguageDetection in
            let likelihood = softmax(det.logprobs, whitelist: ["sv", "en"])
            let prior: [String: Double]
            if let other = otherTrack.mostRecentEndingBefore(det.segment.start, withinMs: priorLookbackMs) {
                prior = [other: crossTrackPriorStrength, opposite(other): 1 - crossTrackPriorStrength]
            } else {
                // No recent info from the other track: weak base-rate prior toward the
                // user's dominant call language (en by default). At 0.55 this only breaks
                // ties for genuinely ambiguous local detections; a confident local label wins.
                prior = [dominantLanguage: 0.55, opposite(dominantLanguage): 0.45]
            }
            let posterior = combine(likelihood, prior)
            return det.relabel(top: posterior.argmax, confidence: posterior.max)
        }
        return collapseToRuns(medianSmooth(refined))
    }
}
```

The pipeline coordination becomes: run Pass 1 on both tracks in parallel, then Pass 2 on each track using the other's Pass-1 output, then proceed to Phase 4. The CodeSwitchTranscriber owns this dance.

```swift
let mePrelim   = smoother.preliminary(meDetections)
let partPrelim = smoother.preliminary(partDetections)

async let meRuns   = decode(track: me,           runs: smoother.refine(meDetections,   priorFrom: partPrelim))
async let partRuns = decode(track: participants, runs: smoother.refine(partDetections, priorFrom: mePrelim))
```

**Definition of done:** synthetic test cases produce expected runs. Specifically: a case where the Me track has a 2-second ambiguous segment and the Participants track is confidently English in the preceding 5 seconds should refine that segment to English, while the same Me segment with no nearby Participants speech should fall back to the per-track median's decision.

## Phase 4: per-run transcription (dual model, batched)

Decode Swedish runs with the configured KB-Whisper-large variant (`standard` by default; `subtitle` or `strict` per config) and English runs with whisper-large-v3. Batching is mandatory because whisper-cli loads the model fresh on each invocation, and a one-hour call can produce dozens of runs. Per-run subprocesses would pay multi-second model-load cost dozens of times. We batch all runs of the same language into one stitched WAV per language per track, then decode each stitched WAV with one whisper-cli call.

The pattern per track:

1. Partition runs by language: `svRuns`, `enRuns`
2. For each non-empty language group, build a stitched WAV with ffmpeg: concatenate the run audio slices with 500 ms of true silence between them as a hard boundary, write to `~/.ghostie/scratch/<call-id>/<track>-<lang>.wav`
3. Keep an offset table mapping `(stitched_start, stitched_end) → (original_start, original_end)` per run
4. Run whisper-cli once per language with the right model and prompt:

```
whisper-cli -m <kb-whisper-large | whisper-large-v3> \
  -f <stitched.wav> \
  --language <sv|en> \
  --no-context \
  --suppress-nst \
  --best-of 5 \
  --temperature 0.0 --temperature-inc 0.2 \
  --entropy-thold 2.4 --logprob-thold -1.0 --no-speech-thold 0.6 \
  --prompt "<promptSv | promptEn>" \
  --output-json
```

5. Walk the output segments, find which run each segment belongs to by stitched-timeline timestamp, and map back to original-track timestamps using the offset table
6. Discard any whisper output that lands inside the 500 ms silence pads (boundary noise)

The 500 ms silence pads matter because whisper's language model behaviour is strong: adjacent runs touching directly can leak tokens across boundaries. True silence forces a clean reset between runs without inflating decode time noticeably.

Keep the hardened decoding flags Ghostie already uses. The important changes vs single-pass:

- `--language` is set explicitly per stitched WAV, never `auto`
- `--no-context` prevents previous-run hidden state from biasing tokens across run boundaries within the stitched WAV (the silence pads handle most of this, but `--no-context` is belt-and-braces)
- Each model gets its own prompt: KB-Whisper sees `promptSv`, whisper-large-v3 sees `promptEn`. KB-Whisper was fine-tuned with Swedish-formatted prompts, so an English prompt there can degrade output

Swift orchestration:

```swift
struct CodeSwitchTranscriber {
    func transcribe(track: URL, callID: String) async throws -> [TranscriptSegment] {
        let segs = try segmenter.segments(for: track)
        let dets = try await detectLanguages(track: track, segments: segs)
        let runs = smoother.runs(from: dets)

        let byLang = Dictionary(grouping: runs, by: \.language)

        var out: [TranscriptSegment] = []
        for (lang, langRuns) in byLang {
            let (stitched, offsets) = try await audioStitcher.stitch(
                track: track,
                runs: langRuns,
                callID: callID,
                silencePadMs: 500
            )
            defer { try? FileManager.default.removeItem(at: stitched) }

            let result = try await runWhisperCLI(
                model: model(for: lang),
                track: stitched,
                language: lang,
                prompt: prompt(for: lang)
            )

            for seg in result.segments {
                if let mapped = offsets.mapToOriginal(seg) {
                    out.append(mapped)
                }
                // segments inside silence pads return nil and are dropped
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
```

Performance: model-load is now twice per track (sv model + en model) regardless of run count. On Apple Silicon with q5_0 quants and Metal, each model loads in ~3 seconds, so codeswitch adds ~12 seconds total overhead per call vs today's single pass (2 tracks × 2 models). Decoding itself is faster than per-run because whisper-cli batches GEMM operations better on longer audio. Net: a 60-minute mixed-language call finishes in roughly 10–14 minutes, comparable to today.

Memory: only one model needs to be loaded at a time per track. Process them serially within a track (sv then en) and the peak RAM is the size of one model (~1.5 GB resident for q5_0). The two tracks can still run in parallel if RAM allows.

**Definition of done:** the merged transcript for a mixed-language test call has KB-Whisper-quality Swedish where Swedish was spoken and whisper-large-v3-quality English where English was spoken, with timestamp continuity preserved and no leaked tokens across run boundaries.

## Phase 5: config and UI

Add to `~/.ghostie/config.json`:

```json
{
  "codeSwitch": {
    "enabled": false,
    "languages": ["sv", "en"],
    "dominantLanguage": "en",
    "modelPerLanguage": {
      "sv": "kb-whisper-large",
      "en": "whisper-large-v3"
    },
    "kbWhisperVariant": "standard",
    "smoothingWindowMe": 4,
    "smoothingWindowParticipants": 4,
    "minSwitchSegments": 2,
    "maxFillGapMs": 4000,
    "runPaddingMs": 200,
    "silencePadMs": 500,
    "minDetectMs": 1500,
    "crossTrackPriorStrength": 0.75,
    "priorLookbackMs": 8000,
    "promptSv": "Affärssamtal på svenska. Termer: Ingka, Xplore, IKEA, IFB.",
    "promptEn": "Business call in English. Terms: Ingka, Xplore, IKEA, IFB, MCP, ACP."
  }
}
```

When `codeSwitch.enabled` is true, the new pipeline replaces the existing single-language transcribe step. When false, nothing changes. `modelPerLanguage` lets advanced users point both languages at the same model (e.g. KB-Whisper for everything if they're disk-constrained) without code changes. `kbWhisperVariant` only affects Swedish decoding; English always uses `whisper-large-v3`. Setting `crossTrackPriorStrength` to 0.5 disables cross-track refinement and reverts Phase 3 to per-track only, which is useful when debugging.

In the Settings window, add a "Code-switching" section under Whisper:

- Toggle: `Enable code-switching`
- Multi-select chips for languages (sv, en, no, da, de…) with sv+en pre-checked
- Dropdown: `Dominant language` (used as tiebreaker)
- Two model pickers, one per language, populated from models found in `~/.ghostie/models/`
- Dropdown: `Swedish transcription style: standard | subtitle | strict` with one-line descriptions
- Two prompt fields per language
- Advanced disclosure: smoothing windows, min switch segments, padding, silence pad, cross-track prior strength, prior lookback

`ghostie doctor` should print the codeswitch config and verify that the configured KB-Whisper variant and the English model are both present on disk.

**Definition of done:** toggling code-switching in Settings flips the pipeline on the next call without restart, matching how other settings already work.

## Phase 6: testing

Add to `ghostie selftest`:

1. **Synthetic fixtures.** Audio fixtures in `Tests/Fixtures/`:
   - `sv_only.wav` (single track) — 30s Swedish
   - `en_only.wav` (single track) — 30s English
   - `mixed.wav` (single track) — sv 10s, en 15s, sv 10s with one English loanword in the sv portion
   - `cross_track_me.wav` + `cross_track_part.wav` (paired) — Me has a 2s ambiguous segment at t=20s; Participants is confidently English from t=15s to t=22s. The expected behaviour is the ambiguous segment refines to English via cross-track prior.
   - `cross_track_isolated_me.wav` + `cross_track_isolated_part.wav` (paired) — same ambiguous Me segment but Participants is silent in the lookback window. Expected: per-track median's call (whatever it is) is preserved, not flipped.
2. **Per-phase assertions.**
   - VAD segmenter returns ≥1 segment per fixture
   - Detector labels `sv_only` segments majority sv, etc.
   - Pass 1 smoother produces 1 run for sv_only and en_only, 3 runs for mixed
   - Pass 2 (cross-track) flips the ambiguous segment in the paired cross-track fixture and leaves it alone in the isolated fixture
   - Full pipeline produces transcripts with expected language per region (assert via a token whitelist per language, not exact string match)
3. **Variant assertion.** Decode the same `sv_only.wav` with `standard` and `strict` variants. Assert the `strict` output contains more tokens (filler words preserved) than `standard`. Don't assert on exact text.
4. **Regression for the cleaner.** Make sure `TranscriptCleaner` doesn't treat language boundaries as hallucinations. The merge step inserts a run separator that the cleaner needs to recognize.

`ghostie selftest` already exists; extend it rather than adding a parallel command.

## Edge cases and gotchas

- **Run boundaries inside a word.** Padding handles most of this; the remaining cases produce a duplicated half-word at the boundary. The merge step should deduplicate by checking for high token overlap (>50%) between the last 2 tokens of run N and the first 2 of run N+1.
- **Music or DTMF tones.** Silero VAD usually filters these but not always. The language detector will return low-confidence garbage on these segments; treat sub-threshold confidence as `unknown` and let smoothing absorb it.
- **Norwegian and Danish confusion.** KB-Whisper is fine-tuned for Swedish but the language ID head still emits no/da occasionally on short Swedish phrases. Whitelist sv+en, map no/da to sv.
- **Cross-track timing skew.** The Bayesian prior uses the most recent confident interval in the other track that ended *at or before* the current segment's start, not concurrent overlap. Concurrent overlap is unreliable: if you ask in Swedish and a colleague answers in English, the answer shouldn't push your question toward English. Using past-only lookback respects causality.
- **Cross-track confirmation bias.** A risk with cross-track priors is that one track's mis-detection flips a marginal segment on the other track, which could then flip its preliminary timeline, etc. Mitigations baked in: Pass 2 reads from *Pass 1* (preliminary) timelines, not from refined ones, so there's no feedback loop within a call. The prior is also bounded at 0.75, so a confident local detection always wins. If real-world data shows drift, the next step is to disable cross-track refinement on segments where the local detection is high-confidence (skip Pass 2 if local margin > threshold).
- **TranscriptCleaner trip wires.** The existing cleaner strips known training-leak phrases and YouTube credits. Running per-run rather than per-track means each run is shorter and the cleaner sees less context, which is *good* for hallucination suppression. No changes expected, but watch for legitimate short Swedish utterances being treated as filler. The selftest fixtures cover this.
- **First-run latency.** Loading a 1 GB GGML model adds ~3 seconds on first invocation. With dual-model batched decoding, the new pipeline loads each language's model once per track per call (4 loads total for both tracks if both languages appear, 2 if only one does). That's ~12 seconds overhead per call vs today's single pass. If this becomes a bottleneck, the next step is whisper-server long-running daemon mode (see Future) which keeps models resident across calls.
- **Backlog re-runs.** The backlog system re-runs failed transcripts. Make sure a partial codeswitch result (some runs done, some failed) is either fully redone or resumable, not partially persisted in a way that confuses the cleaner. Simplest: if any run fails, mark the whole track as failed and re-run.
- **Privacy footprint unchanged.** Everything still happens locally; the model lives in `~/.ghostie/models/`. The README's privacy section needs no changes beyond noting the larger model size if codeswitch is enabled.

## Future

A few extensions worth noting but explicitly out of v1 scope:

- **whisper-server daemon.** Run `whisper-server` (whisper.cpp's HTTP example) as a long-lived process with both models warm. Eliminates the ~12s per-call model-load overhead and makes per-run decoding cheap enough that stitched-WAV batching becomes optional. Cost: lifecycle management (start/stop with Ghostie, port allocation, restart on crash) and a new subprocess to watch in `ghostie doctor`.
- **Third and fourth languages.** Norwegian and Danish colleagues do appear. Adding `no` or `da` is a config change once `modelPerLanguage` exists. The smoother already handles arbitrary label sets through the whitelist; the only real work is picking a model for each (NB-Whisper from Nasjonalbiblioteket exists for Norwegian).
- **Confidence-gated cross-track prior.** If local detection is already high-confidence (margin above threshold), skip Pass 2 entirely for that segment. Reduces compute on the easy cases and eliminates the rare cross-track flip on already-correct labels. Worth measuring before adding the conditional.
- **Per-segment variant routing.** Different parts of a call may benefit from different KB-Whisper variants: action items in `standard` for cleanliness, verbatim quotes flagged for `strict`. Not obviously useful, but the architecture allows it.

## Suggested PR breakdown

1. `feat(setup): --codeswitch flag fetches KB-Whisper-large (variant-selectable) and whisper-large-v3 GGML`
2. `feat(transcribe): LanguageSegmenter via whisper-cli --vad --detect-language`
3. `feat(transcribe): per-segment language detection`
4. `feat(transcribe): Smoother Pass 1 (per-track median + hysteresis)`
5. `feat(transcribe): Smoother Pass 2 (cross-track Bayesian refinement)`
6. `feat(transcribe): AudioStitcher (ffmpeg-based, builds per-language stitched WAV with silence pads and offset table)`
7. `feat(transcribe): CodeSwitchTranscriber routing stitched WAVs to per-language models with KB variant selection`
8. `feat(config): codeSwitch block + Settings UI with per-language model picker and KB variant dropdown`
9. `test(selftest): code-switching fixtures including cross-track and variant assertions`
10. `docs(readme): code-switching section and config table additions`

Each PR is independently testable. PRs 6 and 7 are the biggest; PR 5 (cross-track) is the most algorithmically interesting and easiest to ship without if Pass 1 alone proves accurate enough on real calls.

## Implementation corrections (verified against whisper-cli v1.8.x + KBLab repo, May 2026)

Several assumptions in the plan above did not hold once run against the real
`whisper-cli` and Hugging Face. The shipped implementation differs as follows:

- **KB-Whisper GGML URLs.** Variants are *not* each a revision serving
  `ggml-model-q5_0.bin`. Reality: `standard` = the **default model on `main`**
  (the `standard` *tag* carries no GGML), `strict` = the `strict` tag (has the
  GGML), `subtitle` = **HF-format only, no prebuilt whisper.cpp GGML upstream**.
  `setup.sh` maps `standard→main`, `strict→strict`, and fails `subtitle` early
  with guidance.
- **`-dl` ignores `--offset-t`/`--duration`.** `--detect-language` always
  detects from the *file start* regardless of offset (identical probability for
  every segment — verified). Per-segment detection therefore physically slices
  each VAD segment to a temp WAV (native 16 kHz-mono PCM, no ffmpeg) and runs
  `-dl` on the slice. The plan's offset-flag approach does not work.
- **Detection model must be balanced.** KB-Whisper's language-ID head is
  Swedish-biased — it labels English audio `sv (p≈1.0)`. VAD-driving *and*
  detection use the dominant-language / non-KB model (vanilla large-v3); KB is
  used only to *decode* Swedish runs.
- **whisper-cli flag names.** `--duration-t` does not exist (use `--duration` /
  `-d`); `--no-context` does not exist (use `--max-context 0` / `-mc 0`).
  `-nt`/`--no-timestamps` must NOT be passed to the VAD pass — in this build it
  collapses VAD output into a single whole-file segment.
- **Duration-aware hysteresis.** Count-only `minSwitchSegments` suppresses a
  genuine long switch that VAD returned as one segment. Added `minSwitchMs`
  (default 2500): a run switches on `minSwitchSegments` segments **or**
  `minSwitchMs` of audio. A real loanword is short in time, so it still won't
  switch.
- **AudioStitcher is native, not ffmpeg.** Ghostie's WAVs are always canonical
  16 kHz mono Int16; slicing/stitching is done in-process (no new dependency),
  which also keeps it unit-testable.
- **Config back-compat.** Swift's *synthesized* `Decodable` throws on any
  missing key (defaults are not consulted), so adding the `codeSwitch` block
  would have silently reset every existing user's whole config via
  `loadRaw()`'s `try?`. `Config`/`CodeSwitchConfig` now have a resilient
  `init(from:)` (`decodeIfPresent ?? default`); old/partial configs load
  cleanly.

End-to-end verified with the real KB-Whisper-large (standard) + large-v3 models
on a synthetic sv→en call: each language is decoded by its model and merged by
timestamp. `ghostie selftest` covers the smoother logic (no audio/models).
