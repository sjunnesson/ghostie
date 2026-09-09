# Halving the pipeline again: 30 min → 15 min

Implementation brief for the next round of processing-speed work. Optimization
target: **wall-clock from "call ended" to "note written"**, on the 126-minute
reference recording, without losing transcript fidelity against a second
recorder of the same call.

The previous round (v1.8.0) took that call from 55m30s to 30m09s by deleting
work that bought nothing: a language-ID pass that spent 26 minutes confirming
what its own 24-sample probe already said, and a punctuation pass that ran 11
independent requests in series. Everything cheap is now gone. This round has to
make the *expensive* work smaller, which means trading against quality — so
every step here is defined as an experiment with a measured accept/reject bar,
not as a change to make.

## Where the 30 minutes actually go

Measured on `~/.ghostie/recordings/2026-09-08_21-20-29` (126.2 min, two tracks),
run 2026-09-09 11:09:00 → 11:39:09:

| stage | time | share |
|---|---|---|
| VAD segmentation + whisper-server start | 1m28s | 5% |
| LID probes (2 tracks × 24) | 2m26s | 8% |
| **decode `me-en.wav`** | **8m03s** | **27%** |
| **decode `participants-en.wav`** | **8m08s** | **27%** |
| transcript guard | 1s | — |
| diarization | 1m52s | 6% |
| **punctuation restoration** | **7m28s** | **25%** |
| speaker naming | 7s | — |
| summary | 36s | 2% |
| **total** | **30m09s** | |

Decode is 54%, punctuation 25%. Nothing else is worth touching until those two
are: halving diarization saves 56 seconds.

To reach 15 minutes we need to remove ~15. Two of the three levers below are
structural and safe; the third (a smaller decode model) is the only one that
gets us the whole way, and it is the one that can cost fidelity.

## The reference test

Every change here is scored the same way, because we have something almost no
transcription project has: **the same conversation recorded twice**, once by
Ghostie and once by Wispr Flow.

- Audio: `~/.ghostie/recordings/2026-09-08_21-20-29/{me,participants}.wav`
- Reference: `~/Library/Application Support/Wispr Flow/meetings/648f48b0-.../refined.ndjson`
- Current baseline (v1.8.0): 17,582 words, **83.9% token overlap** with the
  reference, 1318 turns at 13.3 words, diarization 99.8% agreement.

Method (already used to produce those numbers): parse both to
`(seconds, speaker, text)`, run `difflib.SequenceMatcher` over normalized token
streams, report overlap plus the per-5-minute coverage ratio. **Step 0 of this
work is to move that script into the repo** — `scripts/score-transcript.py`,
taking a Ghostie transcript and a reference ndjson — so each experiment below is
one command, and so the bar is a number rather than an impression.

**Accept/reject bar for any decode change: token overlap with the reference must
not drop by more than 1.5 points (83.9% → ≥82.4%), and no 5-minute bucket may
fall below 0.85 coverage.** A change that loses more than that is buying speed
with the record, which is the wrong trade for a tool whose whole claim is that
the note is accurate.

## Lever 1 — decode only the speech (safe, ~8 min)

`AudioStitcher.stitch` builds the run-batch WAV from **language runs**, and a
monolingual call is one run covering the whole track. So whisper decodes all
126 minutes of both tracks, including every silence — which is also where the
"Thank you." hallucinations the v1.8.0 gate now deletes came from. The VAD
speech segments that would bound this are *already computed* one stage earlier
in `LanguageSegmenter.segments`, and thrown away after the language timeline is
built.

Measured on the reference recording (100 ms windows at `WavLevel.activeThreshold`,
gaps under 500 ms bridged, 200 ms padding each side — i.e. what the VAD pass
would keep):

| track | total | speech | runs | decode saving |
|---|---|---|---|---|
| `me` | 126.2 min | 70.0 min (55.4%) | 1479 | **44.6%** |
| `participants` | 126.2 min | 57.6 min (45.6%) | 997 | **54.4%** |

**16m11s → ~8m10s.** Decode time is very close to linear in audio duration, so
this estimate is firm.

Implementation: thread the VAD segments through to `decode(runs:pcm:)` and
intersect each language run with them, so a run contributes only its speech
spans. The offset table `AudioStitcher` already returns is exactly the
machinery needed to map results back — `toOriginal` is per-span already, and
`silencePadMs` already separates spliced spans so whisper doesn't run words
together across a cut.

Risks, in order:

- **Timestamp remap.** More spans means more entries in the offset table and
  more chances for an off-by-one. Mitigation: the existing selftest for
  `AudioStitcher` covers the table; extend it with a many-span case, and use
  the reference test to catch drift (a systematic remap error shows up
  immediately as a collapsing per-bucket coverage ratio).
- **Words lost at span edges.** A VAD boundary that clips a word start costs a
  word. Mitigation: the 200 ms padding above is already in the measurement, and
  `snapBoundaries`' trough search exists for exactly this. Watch the overlap
  number, not intuition.
- **More segments through the guard.** The silence gate has less silence to
  work on, which is fine — it is a backstop, and its stand-down threshold is a
  share, so it scales.

This lever alone: 30m09s → **~22m**. Not a halving, but it is the one with no
fidelity cost and it makes every later decode experiment 2× faster to run.

## Lever 2 — a smaller decode model (the halving, and the risk)

`ggml-large-v3-q5_0.bin` (1.0 GB, 32 decoder layers) is doing the decoding.
`Models.largeV3Turbo` is **already in the catalog and already downloadable** —
`ggml-large-v3-turbo-q5_0.bin`, ~550 MB, 4 decoder layers, flagged
`multilingual: true` and `goodForLID: true`. Nothing in the code has to change
to try it: install it and point `codeSwitch.languages[].model` at it.

Expected 3–5× on the decode stage. Combined with Lever 1 that is **16m11s →
~2–3m**, and it is the difference between "22 minutes" and "13 minutes".

It is also the only step here that can degrade the transcript, so it is run as
an experiment, in this order:

1. `ghostie fetch-models --all` (or just the turbo entry) to install it.
2. Decode **only the `me` track** of the reference recording with each model
   and score both against Wispr. One track is enough to reject a bad model and
   costs 8 minutes instead of 16.
3. If overlap holds within the bar, run the full pipeline and compare the whole
   note, not just the transcript — turbo's known weakness is proper nouns, and
   this call is full of them (Ingka, Xplore, Akshan, Bologna, Porus).
4. Repeat for Swedish. **This is the step most likely to fail**: the turbo
   distillation is weakest outside English, and Ghostie decodes Swedish with
   KB-Whisper anyway. If turbo is only acceptable for English, that is a fine
   outcome — `codeSwitch.languages` is already per-language, so English can use
   turbo and Swedish keep KB-Whisper with no new mechanism at all.

If turbo fails the bar, the fallback ladder, cheapest first:

- **Beam search.** `-bo 5 -bs 5` in both `Transcriber` and
  `CodeSwitchTranscriber` is roughly 3–5× the cost of greedy. `-bo 2 -bs 2`
  typically recovers most of that for a small accuracy cost. Same experiment,
  same bar. Note the flags are deliberate anti-hallucination settings
  (`CLAUDE.md`), so this trade must be scored on hallucination count — the
  silence gate's `decoded from silence` counter is now a direct readout of it.
- **`transcriptionQuality` becomes real.** It currently only picks a model on
  the single-language path and does nothing under code-switching, which is
  where everyone actually is. Making it choose large-v3 vs turbo per language
  turns this whole lever into a user-facing setting rather than a decision
  taken for them.

## Lever 3 — stop punctuating what is already punctuated (~2 min)

479 of 858 blocks were rewritten last run; the rest came back unchanged. Some of
those were already correct — whisper's unpunctuated register comes and goes in
multi-minute stretches, and blocks from a punctuated stretch cost a full
round-trip to be told nothing is wrong.

`TranscriptRefiner.needsRestoration` already makes this judgement for a whole
transcript (`terminalFraction < 0.6`). Apply the same test **per block** and
send only the blocks that fail it; keep the rest verbatim. Blocks are
independent, so this is a filter on the batch list, not a change to the
protocol.

Expected **7m28s → ~5m**, and proportionally fewer requests, which also lowers
the rate-limit pressure that forced concurrency down from 4 to 3.

Risk: a block that *looks* punctuated but is capitalized wrongly gets skipped.
Acceptable — the pass exists for the run-on register, and the guard means the
worst case is a line left as whisper wrote it.

## Projected budget

| stage | now | after L1 | after L1+L2 | after L1+L2+L3 |
|---|---|---|---|---|
| VAD + server start | 1m28s | 1m28s | 1m28s | 1m28s |
| LID probes | 2m26s | 2m26s | ~1m15s | ~1m15s |
| decode | 16m11s | ~8m10s | ~2m30s | ~2m30s |
| diarization | 1m52s | 1m52s | 1m52s | 1m52s |
| punctuation | 7m28s | 7m28s | 7m28s | ~5m |
| naming + summary | 43s | 43s | 43s | 43s |
| **total** | **30m09s** | **~22m** | **~15m** | **~13m** |

(The LID probe line drops with Lever 2 because the probes run through
`ServerWhisperLID` on the same model the decode uses.)

**Lever 2 is load-bearing.** L1 and L3 together are ~20 minutes, not 15. If
turbo and the beam-search fallback both fail the reference bar, the honest
answer is that 20 minutes is the floor for this architecture and the next real
gain is the one below.

## The other answer: don't wait until the call ends

Everything above shortens a batch job that starts when the user hangs up. The
alternative is to stop having a batch job.

The recorder already streams both tracks to disk (`Recording crossed buffer cap
(30s) — flushed to disk and now streaming`), and the VAD/decode stages are
per-span and stateless. Decoding completed spans *while the call is still
running* would make the note land ~1–2 minutes after hangup regardless of call
length, which is a better user-visible outcome than any number in the table
above.

It is a much larger change and it fights the pipeline's current shape in three
specific places, which is why it is scoped here rather than planned:

- The monolingual LID fast path samples across the **whole** track; it would
  have to decide from the first few minutes and be able to change its mind.
- The echo guard and diarization both work over the **complete** pair of tracks.
- Backlog durability assumes a recording is processed once, atomically.

Worth doing after Levers 1–3, and worth prototyping behind a flag rather than
converting the pipeline.

## Order of work

1. `scripts/score-transcript.py` + the reference numbers checked in, so every
   later step is one command and a number. Half a day.
2. Lever 1 (VAD-bounded decode). The largest safe win; also halves the cost of
   running experiments 3 and 4. Extend the `AudioStitcher` selftest first.
3. Lever 3 (per-block punctuation filter). Small, independent, no fidelity risk.
4. Lever 2 (turbo, English first, Swedish separately). Gated on the bar.
5. Re-run the full reference comparison and update the numbers in `CLAUDE.md`
   and this file.

Steps 2 and 3 are independent and can land in either order. Step 4 should not
start before step 1, because it doubles the turnaround of every experiment.
