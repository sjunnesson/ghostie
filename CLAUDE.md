# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Ghostie is a single macOS executable (SwiftPM, Swift tools 6.0, **macOS 15+**) that
detects Microsoft Teams and Zoom desktop calls locally (plus, opt-in, Teams
and Google Meet meetings in a browser tab), records them with
ScreenCaptureKit, transcribes with whisper.cpp, and summarizes via the Claude
Code CLI. No bot joins the meeting and no Graph API is used — detection is
purely local. All source is in `Sources/ghostie/`.

## Commands

```bash
swift build                       # debug build
swift build -c release            # release build (what the scripts use)
./scripts/setup.sh [model] [--vad] # install whisper.cpp + model, then release build
./scripts/build-app.sh            # build, sign, install Ghostie.app to /Applications
./scripts/build-app.sh --dmg [--notarize]  # self-contained distributable .dmg

.build/release/ghostie selftest   # REGRESSION SUITE (see Testing)
.build/release/ghostie doctor     # check deps/permissions/backlog
.build/release/ghostie test-record 15      # smoke-test the full pipeline
.build/release/ghostie process <dir>       # re-run pipeline on a recording dir
.build/release/ghostie fetch-models [v]    # download codeswitch models (KB v + large-v3 + VAD)
```

There is no XCTest target and no linter. `swift build` warnings are expected to
stay at zero (a recent commit silenced them deliberately).

### Testing

`ghostie selftest` is the only automated test. Its suites (wired in
`main.swift`, living in `SelfTest/`): `runTranscriptCleanerSelfTest()`
(exercises `TranscriptCleaner.clean` over silence loops, training-data leaks,
noise-marker runs, interleaved drift, within-segment loops),
`runEchoSuppressorSelfTest()` (exercises `EchoSuppressor.suppress` over
real-call echo fixtures — pure echo, mixed real+echo segments, ASR variance,
plus the never-engage guards for headphone/solo calls), and
`runCodeSwitchSelfTest()` (exercises the `Smoother` over synthetic
`LanguageDetection`s — single-language collapse, mixed 3-run split,
cross-track flip vs. isolated fall-back; **no audio or models needed**, so
it's green everywhere). **Any change to `TranscriptCleaner.swift`,
`EchoSuppressor.swift` or `Smoother.swift` must keep `ghostie selftest`
green**; add a `check(...)` case in the relevant suite rather than building a
separate harness. Optional end-to-end audio fixtures under `Tests/Fixtures`
are skipped cleanly when absent.

## Architecture

The detect → record → transcribe → summarize loop is decoupled from any UI so
the same code drives the menu-bar app and the headless daemon.

- **`main.swift`** — entry point; switches on the subcommand. Bundled as
  `Ghostie.app` → menu bar UI; run as a bare binary → headless daemon. Also
  hosts the selftest and the `icon` PNG generator used by `build-app.sh`.
- **`Engine.swift`** — the core loop, UI-agnostic. Drives both `HeadlessRunner`
  (in `Engine.swift`) and `MenuBarApp`. Owns `EngineState` and the backlog
  retry timer. Thread safety is **manual** via the private `gate` and `work`
  `DispatchQueue`s (not actors), which is why it is `@unchecked Sendable`;
  preserve that model when editing — don't introduce actor isolation.
- **`CallDetector.swift`** — the "no bot" mechanism, now a thin shim over
  `Detection/` (DetectionCoordinator + CallStateMachine + providers): per-PID
  CoreAudio input/output attribution on the `triggerBundleIds` (Teams + Zoom
  desktop by default), corroborated by AX meeting-window / camera signals
  (per-app heuristics via `MeetingWindowHeuristics.forBundleId`). With
  `detectBrowserMeetings` on, a browser's mic use also counts — but ONLY
  while a window title matches a Teams or Google Meet meeting tab
  (`AXBrowserTabProvider.meetingSite(forTitle:)`). idle → candidate
  (tentative capture starts, so the confirm window's audio is kept) →
  confirmed (3 s; `onCallStart`) → ending → idle (30 s grace; `onCallStop`).
  A demoted candidate fires `onTentativeDiscard` and its capture is thrown
  away. At confirm the coordinator freezes a `CallSource` (Teams / Zoom /
  Meet, from the evidence's bundle ids / tab site); Engine reads it via
  `currentCallSource()` and threads it to the pipeline for note naming.
- **`AudioRecorder.swift`** — two audio paths, both 16 kHz mono:
  SCK `.audio` (system → everyone else → `participants.wav`), and the mic
  (you → `me.wav`) via **`MicCapture.swift`** — AVAudioEngine with
  voice-processing I/O so speaker output (the other participants) is
  echo-cancelled out of the Me track. If VP can't start (or
  `config.micEchoCancellation` is off) it falls back to the raw SCK
  `.microphone` tap, which re-captures everything the speakers play. The Me/
  far-end split is **track-based**, never inferred — diarization only ever runs
  *within* the Participants track. VP failure is not always a throw: a stopped
  graph keeps emitting zero-filled buffers, so `MicCapture` rebuilds on
  `AVAudioEngineConfigurationChange` and `AudioRecorder` probes for a non-zero
  sample before committing, then watchdogs the track for the rest of the call.
  A 2×2 dropped video stream is required only to keep the stream alive.
- **`SpeakerDiarizer.swift` / `SpeakerEmbedder.swift` / `Fbank.swift`** —
  splits the Participants track per person. Kaldi-compatible 80-bin fbank →
  WeSpeaker ResNet34 (ONNX, `feats [1,T,80] → embs [1,256]`) → average-linkage
  agglomerative clustering on cosine distance. Windows below the voiced gate
  are never embedded (silence yields a meaningless but unit-length vector that
  clustering cannot ignore) and are backfilled from their neighbours instead.
  The 0.70 merge threshold is measured, not guessed — see the doc comment.
  Entirely optional: no ONNX runtime or no model means the far end keeps one
  "Participants" label.
- **`SpeakerNamer.swift`** — replaces placeholder labels with names read off
  the transcript by the configured summarization provider. Every failure path
  keeps the placeholder, and `isPlausibleName` rejects roles, descriptions and
  anything with a digit, because a wrongly named speaker corrupts the summary
  built on it.
- **`WavLevel.swift`** — post-hoc signal probe on the finished WAVs. Catches a
  track that recorded nothing regardless of cause, on every route to a note,
  and puts a ⚠️ line in the meta block (which the summarizer also sees).
- **`Pipeline.swift`** — transcribe both tracks → clean per track → diarize
  Participants → cross-track echo guard → merge by timestamp → name speakers →
  summarize → write
  `<notesFolder>/<date>_<Source>-Call.md` (+ transcript), where Source is
  the detected app ("Teams"/"Zoom"/"Meet", generic "Call" when unknown). The
  name must stay a pure function of `startedAt` + the source stored in
  backlog meta.json — retries re-derive it to upgrade the queued note in
  place (pre-source entries default to "Teams"). `Pipeline.drain(config:)`
  is the backlog retry entry point.
- **`EchoSuppressor.swift`** — the cross-track echo guard (text-level backstop
  behind `MicCapture`'s AEC — Bluetooth latency can defeat AEC, and backlogged
  pre-fix recordings re-process through it). Direction is known a priori:
  system audio can never contain the mic, so a ≥5-word run on Me that also
  appears on Participants within its time window is echo and only the Me copy
  is trimmed/dropped. It only engages when duplication is endemic (≥25% of Me
  words, ≥100 words), so headphone calls and genuine verbal mirroring are
  never touched. Pure + deterministic; covered by `selftest` with fixtures
  from a real speakerphone call.
- **`Transcriber.swift`** — wraps the whisper.cpp CLI with hardened,
  hallucination-resistant decoding flags (set explicitly so a future
  whisper-cli default change can't silently regress quality). Parses
  `<prefix>.json`.
- **`TranscriptCleaner.swift`** — the per-track hallucination guard. Deliberately
  conservative (a single legitimate "Okay." survives). Covered by `selftest`.
- **Code-switching (N-language, e.g. sv↔en)** — active whenever ≥2 languages
  resolve to an installed model; there is no `codeSwitch.enabled` flag.
  `codeSwitch.languages` is an array of **`LanguageSetting` records**
  (`{code, model?, prompt?}` — see `Languages.swift`); empty (a fresh install)
  means "use whatever `Models.installed()` reports", so the disk is the
  whitelist until the user configures one. Settings *materializes* the list
  from disk on the first add/remove, so from then on the config and the pane
  agree. `CodeSwitchConfig.effectiveLanguages(installed:)` / `effectiveDominant`
  / `effectiveModelPath` resolve config ∩ disk into the single whitelist every
  stage (segmenter, smoother, verifier, decoder) reads — they must not diverge.
  **`LanguageSetup.resolve(config:catalog:present:)`** is the one computation
  behind the Settings pane, `doctor`, and the add/remove flows: pure, with
  `present` as the injected on-disk test, so all of it is checkable in
  `selftest` without a filesystem. UI code must render it, not re-derive it.
- **Multilingual fallback** — `CatalogEntry.multilingual` (large-v3 family)
  means "decodes any Whisper language", so every language gets a default model
  without a per-language catalog entry, and adding German/Spanish usually costs
  no download. Keep the two lookups distinct: `InstalledModels.modelPath(for:)`
  is *specialists only* and feeds `languages`, the **disk-driven whitelist**;
  `decodePath(for:)` adds the multilingual fallback and feeds
  `effectiveModelPath`. Widening the former would make one installed large-v3
  mean "listen for 99 languages" — there's a selftest pinning this.
  `multilingual` is separate from `goodForLID` (decode coverage vs. the
  language *head*); they coincide for large-v3, not in principle.
  When active it replaces the single whisper pass; per-track cleaning + the
  timestamp merge in `Pipeline` are unchanged. `LanguageSegmenter.swift` (VAD
  segments + per-segment language detection), `LanguageIdentifier.swift` (the
  pluggable LID seam: `WhisperLID` today, `VoxLingua107LID` stub for the ONNX
  path; plus the `LogProb.skewed` log-prob shape both it and the smoother share),
  `Smoother.swift` (the pure, testable two-pass core: per-track median/hysteresis
  then cross-track Bayesian refine in log-space; also defines the shared
  `VADSegment`/`LanguageDetection`/`LanguageRun`/`LanguageTimeline` types),
  `AudioStitcher.swift` (native 16 kHz-mono WAV slicing into per-language
  stitched WAVs with silence pads + an offset table — no ffmpeg; also the
  snap-to-silence `troughs` energy scan), `CodeSwitchTranscriber.swift`
  (orchestrates and returns per-track `Transcriber.Segment`s; any whisper failure
  throws so the whole call backlogs and re-runs cleanly — no partial state).
  `ModelDownloader.swift` fetches the per-language models from Hugging Face into
  `~/.ghostie/models/` (shared by the Settings “Download models” button and
  `ghostie fetch-models`; variant→URL/filename mapping kept in lockstep with
  `setup.sh` and `CodeSwitchConfig.modelPath`).
- **Summarization** — `Summarizer.swift` is a thin façade that dispatches to a
  `SummarizationProvider` based on `config.summaryProvider`. Two providers
  ship: `ClaudeSummarizationProvider` (shells out to `claude -p` using the
  user's existing Claude Code login — **no API key**; cwd =
  `NSTemporaryDirectory()` **so it does not pick up any project CLAUDE.md**,
  meaning *this file does not affect generated summaries*), and
  `OllamaSummarizationProvider` (POSTs to `/api/chat` on a local Ollama
  server, for fully-on-device notes). The analyst system prompt lives in
  `SummarizerPrompt.swift` so both providers produce notes with the same
  structure. Provider selection is honored strictly — a failure backlogs the
  transcript, it never silently falls back to the other provider.
- **`Backlog.swift`** — durable retry queue at `~/.ghostie/backlog/`. Two
  stages: `transcribe` (audio kept) and `summarize` (transcript kept, audio
  dropped so it's never re-transcribed). A note is always written immediately
  with a "queued" banner and upgraded in place once processing succeeds. Drains
  on launch, after each call, on settings change, and every 10 min.
- **`Config.swift`** — `~/.ghostie/config.json` + env overrides
  (`GHOSTIE_NOTES_FOLDER`, `GHOSTIE_WHISPER_MODEL`, `GHOSTIE_SUMMARY_MODEL`).
  Binary/model paths are **never persisted** so resolution (including
  `.app`-bundled resources for the self-contained `.dmg`) re-runs on every
  machine and self-heals stale paths. The single-language `whisperModel` is
  disk-resolved at load (like `whisperBinary`): `GHOSTIE_WHISPER_MODEL` or an
  explicit non-default config file wins, else `Models.bestSingleLanguageModel`
  picks the best installed model (large-v3 → KB → base.en) — don't revert this
  to a hardcoded base.en default. `Config.load()` is re-read per call, so
  Settings changes apply with no restart.
- Supporting: `WavWriter`, `AudioChunkConverter`, `MenuBarApp`,
  `SettingsWindow`, `GhostIcon`, `Logger`.

## Conventions & gotchas

- **Swift 5 language mode** is set intentionally in `Package.swift` to avoid
  Swift 6 strict-concurrency friction with the many CoreAudio / ScreenCaptureKit
  C callbacks. Don't switch to `.v6`.
- Audio + transcription are 100% local. The **text transcript** only leaves
  the machine when the Claude provider is selected (to Anthropic, via the
  user's own Claude Code login). With the Ollama provider, summarization is
  also fully local — nothing leaves the machine running Ollama.
- Recordings, notes, and `config.json` are gitignored. Never commit `*.wav`,
  `recordings/`, or `config.json`.
- New self-contained features must keep the `.dmg` path working: bundle
  resources under `Ghostie.app/Contents/Resources` and resolve them via
  `Config.bundledResource(_:)`.
- **Swift `Codable` back-compat**: synthesized `Decodable` throws on *any*
  missing key (property defaults are NOT used), and `Config.loadRaw()` swallows
  that with `try?` → a single new key would reset every existing user's whole
  config. `Config`/`CodeSwitchConfig` therefore have hand-written
  `init(from:)` using `decodeIfPresent ?? default`; **add new config keys to
  both the property list and that init**. Retired keys are read but never
  written: `CodeSwitchConfig.LegacyKeys` (`promptSv`/`promptEn`, `prompts`,
  `modelPerLanguage`) folds them into `languages` records on decode,
  `Config.LegacyKeys` folds `detectBrowserTeams` into `detectBrowserMeetings`,
  and `LanguageSetting` decodes from a bare string so a pre-v3 `["sv","en"]`
  migrates by being decoded. Value-level folds too (Settings writes every
  key, so "persisted the old default" ≠ "user chose it"): a `triggerBundleIds`
  equal to the pre-Zoom Teams-only default upgrades to the new default (adds
  `us.zoom.xos`), the old Teams-specific `initialPrompt` default upgrades to
  the app-neutral one, and the old "Teams Call Notes" `notesFolder` default
  upgrades to "Ghostie Call Notes" (existing note files are never moved).
  Every legacy shape has a `selftest` case — keep it that way, because a
  decoder slip here is a silent whole-config reset.
- **whisper-cli quirks (codeswitch)**: `--detect-language`/`-dl` ignores
  `--offset-t`/`--duration` (detects from file start) → segments are physically
  sliced before detection; `-nt` collapses the VAD pass to one segment (never
  pass it there); KB-Whisper's language-ID is Swedish-biased (detect with the
  non-KB/large-v3 model, decode Swedish with KB); flags are `--duration` (not
  `--duration-t`) and `-mc 0` (no `--no-context`). See `code-switching.md`
  "Implementation corrections".
