# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Ghostie is a single macOS executable (SwiftPM, Swift tools 6.0, **macOS 15+**) that
detects Microsoft Teams calls locally, records them with ScreenCaptureKit,
transcribes with whisper.cpp, and summarizes via the Claude Code CLI. No bot
joins the meeting and no Graph API is used — detection is purely local. All
source is in `Sources/ghostie/`.

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

`ghostie selftest` is the only automated test. It runs two suites in
`main.swift`: `runTranscriptCleanerSelfTest()` (exercises
`TranscriptCleaner.clean` over silence loops, training-data leaks,
noise-marker runs, interleaved drift) and `runCodeSwitchSelfTest()` (exercises
the `Smoother` over synthetic `LanguageDetection`s — single-language collapse,
mixed 3-run split, cross-track flip vs. isolated fall-back; **no audio or
models needed**, so it's green everywhere). **Any change to
`TranscriptCleaner.swift` or `Smoother.swift` must keep `ghostie selftest`
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
  CoreAudio input/output attribution on Teams bundle IDs, corroborated by
  AX meeting-window / camera signals. idle → candidate (tentative capture
  starts, so the confirm window's audio is kept) → confirmed (3 s;
  `onCallStart`) → ending → idle (30 s grace; `onCallStop`). A demoted
  candidate fires `onTentativeDiscard` and its capture is thrown away.
- **`AudioRecorder.swift`** — ScreenCaptureKit with two taps:
  `.audio` (system → everyone else → `participants.wav`) and `.microphone`
  (you → `me.wav`), both 16 kHz mono. Speaker labels are **track-based**, not
  diarization. A 2×2 dropped video stream is required only to keep the stream alive.
- **`Pipeline.swift`** — transcribe both tracks → clean per track → merge by
  timestamp → summarize → write `<notesFolder>/<date>_Teams-Call.md` (+ transcript).
  `Pipeline.drain(config:)` is the backlog retry entry point.
- **`Transcriber.swift`** — wraps the whisper.cpp CLI with hardened,
  hallucination-resistant decoding flags (set explicitly so a future
  whisper-cli default change can't silently regress quality). Parses
  `<prefix>.json`.
- **`TranscriptCleaner.swift`** — the per-track hallucination guard. Deliberately
  conservative (a single legitimate "Okay." survives). Covered by `selftest`.
- **Code-switching (N-language, e.g. sv↔en)** — active whenever ≥2 per-language
  whisper models are installed on disk; **the disk is the whitelist**, not a
  Settings toggle (there is no `codeSwitch.enabled` flag). `codeSwitch.languages`
  empty (the default) means "use whatever `Models.installed()` reports";
  a non-empty list is an explicit override **and** the "I want code-switching"
  intent signal Settings writes (so `Models.required` knows whether to fetch the
  pair). `CodeSwitchConfig.effectiveLanguages(installed:)` / `effectiveDominant`
  / `effectiveModelPath` resolve config ∩ disk into the single whitelist every
  stage (segmenter, smoother, verifier, decoder) reads — they must not diverge.
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
  both the property list and that init**.
- **whisper-cli quirks (codeswitch)**: `--detect-language`/`-dl` ignores
  `--offset-t`/`--duration` (detects from file start) → segments are physically
  sliced before detection; `-nt` collapses the VAD pass to one segment (never
  pass it there); KB-Whisper's language-ID is Swedish-biased (detect with the
  non-KB/large-v3 model, decode Swedish with KB); flags are `--duration` (not
  `--duration-t`) and `-mc 0` (no `--no-context`). See `code-switching.md`
  "Implementation corrections".
