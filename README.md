# Ghostie

Listens to your **Microsoft Teams calls locally** — **no bot ever joins the
meeting** — automatically transcribes each call and writes a markdown summary
(context, decisions, action items) to a folder on your Mac.

## How it works (no bot, no Graph API)

1. **Detect.** The detector watches per-process audio I/O via CoreAudio
   (`kAudioProcessPropertyIsRunningInput` / `IsRunningOutput`, macOS 14.2+),
   filtered to Teams' bundle IDs. A Teams PID holding the input is the
   **primary signal**; promotion to a confirmed call requires the primary
   plus at least one independent **corroborator** from this list:

   - **Output I/O** on a Teams PID. Other participants' voices land here,
     so a real meeting almost always shows it.
   - **Camera in use** while Teams is running. CoreMediaIO does not expose
     per-PID camera attribution publicly, so this is approximated as any
     camera running with Teams open.
   - **AX meeting window** match on the Teams main app. Versioned title and
     role-description heuristics, see `MeetingWindowHeuristics.swift`. AX
     permission is optional. Denial just removes one corroborator; output
     and camera still carry the signal.

   A device hot-swap (headphones unplugged, AirPods handed off) starts a
   three-second quiescence window so a transient input drop does not collapse
   a confirmed call. A 30-second end grace covers mute, brief network blips,
   and Teams crash-relaunch uniformly.

2. **Record.** `ScreenCaptureKit` captures two independent local audio taps,
   system audio (the other participants) and your microphone (you), as two
   16 kHz mono WAV files. No virtual audio driver, no bot participant.
   Capture begins **tentatively at first evidence** — before the detector's
   3-second confirm window has elapsed — so a call's opening words are part
   of the recording; a candidate that never confirms is discarded unheard.
   The first 30 seconds of every recording sit in a bounded in-memory PCM
   ring; if the call ends before crossing `minCallSeconds`, no file ever
   reaches disk.

3. **Transcribe.** [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
   runs entirely on your machine. Call audio never leaves your Mac. Decoding
   uses hallucination-resistant settings and a per-track **hallucination
   guard** (see below). The two tracks are merged by timestamp and labelled
   **Me** vs **Participants**.

4. **Summarize.** The transcript is turned into a structured markdown note —
   Context, Participants, Discussion, Decisions, Action Items, Open Questions,
   Summary — by your chosen summarizer: the **Claude Code CLI** (`claude -p`,
   using your existing Claude Code login, no API key) or a **local Ollama
   model** (nothing leaves the machine). See [Summarization](#summarization).

5. **Save.** `~/Documents/Teams Call Notes/2026-05-16_14-03_Teams-Call.md`
   (plus a transcript file). Audio is deleted afterwards by default.

The detect → record → process loop runs forever, so every call is captured
automatically with zero interaction. Use `ghostie diagnose-detect` to see
live detector state in the field.

## Install

### Option A — self-contained `.dmg` (no terminal on the target Mac)

Build a distributable disk image once:

```bash
./scripts/build-app.sh --dmg              # → build/Ghostie.dmg
./scripts/build-app.sh --dmg --notarize   # also notarized & stapled
```

`--dmg` bundles a statically-built `whisper-cli` and the small Silero VAD
model inside `Ghostie.app`. The Whisper speech model (~140 MB) is **not**
bundled — on first launch Ghostie opens Settings and downloads it from
Hugging Face into `~/.ghostie/models/` (SHA256-verified). The only
requirement on the receiving Mac is **macOS 15+**. Copy `build/Ghostie.dmg`
to the other Mac, open it, drag **Ghostie** to **Applications**, launch it.
If you didn't notarize, the first launch is **right-click ▸ Open** (one time).

> With the default **Claude** summarizer, summaries use *your* Claude Code
> login, which can't be bundled. Until you run `claude` once on that Mac to
> sign in, calls still record + transcribe and are held in the
> [backlog](#never-loses-a-call-backlog); summaries backfill automatically once
> Claude Code is available. No Anthropic API key needed. (Or switch to the
> local **Ollama** summarizer in Settings — see [Summarization](#summarization).)

Notarizing needs a one-time credential store on the build machine:

```bash
xcrun notarytool store-credentials ghostie-notary \
  --apple-id <your-apple-id> --team-id 6V9RN6W28J --password <app-specific-pw>
```

### Option B — build from source

```bash
./scripts/setup.sh        # whisper.cpp + model + build
./scripts/build-app.sh    # build, sign & install Ghostie.app to /Applications
open "/Applications/Ghostie.app"
```

`build-app.sh` auto-detects your signing identity in order: **Developer ID
Application** → **Apple Development** → a stable **self-signed** identity
(`Ghostie Self-Signed`, see [below](#permissions-keep-re-prompting-on-every-rebuild))
→ **ad-hoc**. Anything but ad-hoc keeps granted permissions across rebuilds.

## Automatic updates

Installed copies update themselves over the air from
[GitHub Releases](https://github.com/sjunnesson/ghostie/releases) — no
rebuild, no reinstall:

- Ghostie checks for a newer release shortly after launch and about once a
  day. When one exists it shows **“Update to vX.Y.Z…”** in the menu and posts
  a single notification.
- You choose when to install. It downloads the new build, **verifies** it
  (published SHA-256 **and** Apple notarization — `codesign` confirms the same
  Developer ID team, `spctl`/Gatekeeper confirms notarization), then quits and
  relaunches. It **never interrupts an active call** — an install during a
  call waits until the call finishes.
- Toggle in **Settings ▸ General ▸ Updates**, or from the CLI:
  `ghostie update` (check) / `ghostie update --install`.
- Only **notarized Developer-ID** builds can self-update — that's the only
  signature the updater can cryptographically trust. From-source / ad-hoc /
  self-signed dev builds skip the check and say so; grab releases manually.

## Menu bar app

Ghostie runs as a **macOS menu bar app** — a 👻 ghost icon in the menu
header, no Dock icon, always watching.

The menu bar icon reflects state (watching · ● recording 02:13 · summarizing)
and its menu gives quick access to everything:

- **Pause / Resume Listening**
- **Open Notes Folder** · **Open Last Summary**
- **Run 15-Second Test** (verifies the whole pipeline)
- **Settings…** (`⌘,`) — a real settings window for the notes folder, audio
  options, detection timing, whisper model/language/prompt, VAD, hallucination
  guard, and the summarizer (Claude CLI path & model, or the Ollama server URL
  & model). Saving applies immediately (no restart) and an *Open config.json*
  button remains for power users.
- **Diagnostics**
- **Start at Login** (registers a launch item via `SMAppService`)
- **Quit** (finishes any in-progress summary first)

On the **first call** macOS prompts for **Screen Recording** and **Microphone**
for *Ghostie*. Grant both in *System Settings ▸ Privacy & Security*. With a
stable signing identity this is a one-time step.

### Permissions keep re-prompting on every rebuild

macOS ties the Microphone / Screen-Recording grant to the app's **code-signing
identity**. Without an Apple Developer account `build-app.sh` falls back to
**ad-hoc** signing, which has no stable identity — TCC then keys the grant to
the binary's exact hash, so *every rebuild looks like a new app* and macOS
asks again. (Check with `codesign -dvvv /Applications/Ghostie.app` — `Signature=adhoc`.)

Fix it once with a stable **self-signed** identity (no Apple account, no sudo):

```bash
./scripts/make-signing-cert.sh          # creates "Ghostie Self-Signed" (1 password prompt)
./scripts/build-app.sh --reset-perms    # rebuild signed with it + clear stale grants
# launch Ghostie, approve Microphone + Screen Recording ONCE — it now sticks
```

`build-app.sh` auto-detects the `Ghostie Self-Signed` identity (or any name in
`GHOSTIE_SIGN_IDENTITY`) and prefers it over ad-hoc. If the scripted cert
misbehaves, create it via the GUI instead — **Keychain Access ▸ Certificate
Assistant ▸ Create a Certificate**, name `Ghostie Self-Signed`, Identity Type
*Self Signed Root*, Certificate Type **Code Signing** — then rerun
`build-app.sh --reset-perms`.

## CLI (headless / servers)

The same binary also runs without a UI — useful for launchd or remote boxes:

```bash
ghostie run                          # headless watch loop; Ctrl-C to stop
ghostie test-record 15               # 15s smoke test through the full pipeline
ghostie process <dir>                # re-summarize a saved recording folder
ghostie install-service              # headless launchd service
ghostie doctor                       # dependency + permission diagnostics
ghostie diagnose-detect              # live detector readout (30s, 500ms refresh)
ghostie diagnose-detect --json       # line-delimited JSON for scripting
ghostie selftest                     # transcript guard + codeswitch + updater + detector
```

When detection misfires (a false start or a missed call), `diagnose-detect`
is the first stop. Each line shows the current state machine stage, every
evidence signal, and the most recent transition reason.

## Transcript quality

Whisper is excellent at recognition but notorious for **hallucinating** on
quiet/noisy audio — looping a phrase ("Thank you." ×30), emitting
`[BLANK_AUDIO]` / `[music]` runs, or pasting YouTube-subtitle training leaks
("Thanks for watching!", "Subtitles by the Amara.org community", URLs). A call
recording has lots of silence (mute, listening), so this matters a lot.

Ghostie adopts the practices proven in production by
[`whisper-guard`](https://github.com/silverstein/minutes) (the post-processing
layer behind the *minutes* project):

- **Hardened decoding** — explicit `best-of 5`, entropy/logprob/no-speech
  thresholds, temperature fallback, and `--suppress-nst` (suppress non-speech
  tokens), plus a business-call **initial prompt** that biases punctuation.
- **Per-track hallucination guard** (`TranscriptCleaner`) — collapses silence
  loops (with an audit annotation), drops noise-marker runs, strips known
  training-leak phrases / credit lines / bare URLs, and trims trailing
  noise/filler. It is deliberately conservative: a single closing "Okay." or
  legitimate backchannel survives. Cleaning runs per track *before* the merge.
- **Optional Silero VAD** — `./scripts/setup.sh --vad` fetches the model;
  Ghostie auto-uses it. VAD is the single biggest reducer of silence-driven
  hallucination.

`ghostie selftest` runs the guard over representative hallucination patterns
and asserts clean speech is left untouched, **and** runs the code-switching
smoother regression suite (below).

## Code-switching (Swedish ↔ English)

Whisper locks one language from the first ~30 s and applies it to the whole
file. Calls that mix Swedish and English (Nordic 1:1s, side conversations,
code-switched terms) get the minority language mistranslated or hallucinated.

Enable **code-switching** and Ghostie instead segments each track with VAD,
detects the language of every segment (encoder only — no decode), smooths the
detections into language-consistent runs, and decodes each run with the *right*
model: **KB-Whisper-large** for Swedish, **whisper-large-v3** for English.
Tracks are smoothed independently, then cross-track refined — when the other
speaker just switched to Swedish, your next ambiguous segment is nudged toward
Swedish too (past-only, so it respects who spoke when).

Get the models (~2 GB) either way:

- **From Settings** (no terminal — best for the `.dmg`): *Settings ▸
  Code-switching ▸ Download models*. Shows progress, skips anything already
  present, and points the config at what it fetched.
- **From the CLI**: `ghostie fetch-models standard` (same downloader), or the
  build script `./scripts/setup.sh --codeswitch --kb-variant standard`
  (`standard | strict`).

`standard` (the default Stage-2 model, best for notes) and `strict` (verbatim,
keeps filler) have prebuilt whisper.cpp GGMLs upstream. `subtitle` is published
HF-format only — pick `standard`/`strict`, or convert the `subtitle` revision
yourself and point `codeSwitch.modelPerLanguage.sv` at the file.

Then turn it on in **Settings ▸ Code-switching** (or set
`codeSwitch.enabled: true` in `config.json`). It applies on the next call with
no restart, exactly like every other setting. When disabled, nothing changes —
the single-model path is used. Everything still runs **100% locally**; the
models just live in `~/.ghostie/models/` and are larger.

`ghostie selftest` exercises the smoother (single-language collapse, mixed
3-run split, cross-track flip vs. isolated fall-back) with synthetic
detections — no audio or models required, so it stays green everywhere.

### Optional: dedicated ONNX language identifier

By default, per-segment language detection uses whisper's own language head.
A dedicated **VoxLingua107 ECAPA-TDNN** identifier (faster and better on
sub-2 s segments) activates automatically when two things are on disk:

```bash
brew install onnxruntime                 # the runtime (MIT), loaded at run time
python3 scripts/export-voxlingua-lid.py  # one-time model export (Apache-2.0)
```

The export script converts `speechbrain/lang-id-voxlingua107-ecapa` to
`~/.ghostie/models/lid-voxlingua107.onnx` with the feature pipeline inside
the graph (needs `pip install torch speechbrain onnx onnxruntime` in any
Python 3.10+ environment). Nothing links ONNX Runtime at build time — the
dylib is `dlopen`ed only if present, so installs without it are unaffected.
`ghostie doctor` shows which identifier is active either way.

## Summarization

The structured note is written by a **summarization provider**, chosen in
*Settings ▸ Summary* (or `summaryProvider` in `config.json`). Two ship:

- **Claude** (default) — shells out to the **Claude Code CLI** (`claude -p`)
  using your existing Claude Code login. No Anthropic API key. Best note
  quality. The text transcript is sent to Anthropic under your own account.
- **Ollama** — POSTs the transcript to a local (or LAN)
  [Ollama](https://ollama.com) server, so it **never leaves the machine**.
  Set the server URL and pick a pulled model (e.g. `llama3.1:8b`) in Settings;
  note quality tracks the model you run.

Both providers share the same analyst prompt, so the note structure is
identical either way. The selected provider is honoured **strictly** — if it
fails, the call goes to the [backlog](#never-loses-a-call-backlog) and is
retried; Ghostie never silently falls back to the other one. `ghostie doctor`
reports whether the active provider is ready.

## Never loses a call (backlog)

If a call can't be fully processed — whisper isn't set up, Claude Code isn't
logged in, you're offline — the recording is **not** discarded. It's queued to
a durable backlog at `~/.ghostie/backlog/`:

- Transcription failed → the **audio** is kept and re-tried later.
- Transcription OK but summary failed → the **transcript** is saved (audio
  dropped, so it's never re-transcribed) and only the summary is re-tried.

The note is still written immediately with a "⏳ queued" banner and the full
transcript, then **upgraded in place** once processing succeeds. The backlog
drains automatically: on launch, after every successful call, when settings
change, and every 10 minutes. The menu shows **Process Backlog (N pending)**
and `ghostie process-backlog` forces a drain. Entries that keep failing are
given up after a few attempts with a best-effort note (never an endless queue).

## Configuration

Edit `~/.ghostie/config.json` (created on first run). Notable keys:

| Key | Default | Purpose |
|-----|---------|---------|
| `notesFolder` | `~/Documents/Teams Call Notes` | Where summaries are saved |
| `keepAudio` | `false` | Keep raw WAVs after processing |
| `endGraceSeconds` | `30` | Primary-signal-lost grace before a call is "ended"; covers mute, brief blips, Teams crash-relaunch |
| `minCallSeconds` | `20` | Calls shorter than this are dropped from the in-memory ring without hitting disk |
| `triggerBundleIds` | `["com.microsoft.teams", "com.microsoft.teams2"]` | Exact Teams main-app bundle IDs the detector trusts |
| `triggerBundlePrefixes` | `["com.microsoft.teams"]` | Deprecated; use `triggerBundleIds`. Readable for one release, then removed |
| `whisperModel` | `…/ggml-base.en.bin` | Bigger model = better accuracy, slower |
| `language` | `en` | `auto` for automatic detection |
| `cleanTranscript` | `true` | Run the hallucination guard |
| `initialPrompt` | business-call primer | Biases whisper punctuation; `""` to disable |
| `vadModel` | `…/ggml-silero-v5.1.2.bin` | Auto-used if present (`setup.sh --vad`) |
| `summaryProvider` | `claude` | Summarizer backend: `claude` (cloud) or `ollama` (local) |
| `summaryModel` | `claude-sonnet-4-6` | Model for `claude -p` (alias or full id); `claude` provider only |
| `summaryTimeoutSeconds` | `300` | Wall-clock cap per summarization request (both providers); raise for big local models |
| `claudeBinary` | _(auto-detected)_ | Path to the `claude` CLI; `claude` provider only |
| `ollamaUrl` | `http://localhost:11434` | Ollama server URL (LAN host also fine); `ollama` provider only |
| `ollamaModel` | _(empty)_ | Ollama model name from `ollama list`; `ollama` provider only |
| `codeSwitch.enabled` | `false` | Per-segment dual-model sv↔en pipeline |
| `codeSwitch.kbWhisperVariant` | `standard` | Swedish style: `standard`/`subtitle`/`strict` |
| `codeSwitch.dominantLanguage` | `en` | Tiebreaker for ambiguous segments |
| `codeSwitch.crossTrackPriorStrength` | `0.75` | `0.5` disables cross-track refine; `1.0` absolute |
| `codeSwitch.minSwitchMs` | `2500` | A run this long switches language even if VAD made it one segment |

Environment overrides: `GHOSTIE_NOTES_FOLDER`, `GHOSTIE_WHISPER_MODEL`,
`GHOSTIE_SUMMARY_MODEL`.

With the default **Claude** provider, summaries use the Claude Code CLI
(`claude -p`) and your existing Claude Code login — no Anthropic API key; run
`claude` once in a terminal to sign in. With the **Ollama** provider they run
fully locally. Either way `ghostie doctor` confirms the active provider is
ready. See [Summarization](#summarization).

## Privacy

- Audio capture and transcription are 100% local.
- With the default **Claude** summarizer, only the **text transcript** is sent
  to Anthropic (via the Claude Code CLI under your own account). Without Claude
  Code installed/logged in you still get the full local transcript; no AI
  analysis is produced and nothing leaves the machine.
- With the **Ollama** summarizer, summarization is also 100% local — the
  transcript never leaves the machine running Ollama.
- Recordings live in `~/.ghostie/recordings` only while processing and are
  deleted unless `keepAudio` is true.
- **Be mindful of consent laws and your employer's policy before recording
  calls.**

## Requirements

- macOS 15+ (uses ScreenCaptureKit native microphone capture)
- Swift toolchain (Xcode or Command Line Tools)
- Homebrew (for `whisper-cpp`)

## Limitations

- **Teams only by design.** The detector is scoped to the Microsoft Teams
  desktop app. Zoom, Google Meet, and Slack huddles do not trigger a
  recording, even when the mic is in use. The provider architecture in
  `Sources/ghostie/Detection/` is built to make adding them later
  straightforward, but each needs its own evidence shape.
- **Browser-Teams is not yet detected.** Calls held in `teams.microsoft.com`
  inside Safari, Chrome, Edge, or Arc fall through. Opt-in browser detection
  via a TLS-peer probe plus AX title matching is on the roadmap. Until it
  lands, install the desktop client for anything you want auto-captured.
- **AX heuristics drift over Teams releases.** Microsoft can change the
  meeting window's title or role description in any release. The
  versioned `MeetingWindowHeuristics` constant gives us something to bump
  when it happens, but we may not detect the change before users do.
  Because AX is a corroborator and not a veto, output and camera signals
  keep working in the meantime.
- **System-audio capture records all system sound during the call.** During
  a Teams call that is overwhelmingly the other participants, but anything
  else playing audio at the time gets mixed in.
- **Speaker labels are track-based** (Me vs everyone-else), not per-person
  diarization.

## License

Ghostie is released under the **MIT License** — see [`LICENSE`](LICENSE). You
may use, modify, and redistribute it (including commercially); just keep the
copyright and license notice.

It builds on third-party software and speech models under their own licenses
(whisper.cpp — MIT; OpenAI Whisper weights — MIT; KB-Whisper — Apache-2.0;
Silero VAD — MIT). The self-contained `.dmg` redistributes a statically built
`whisper-cli` and the base speech model. See
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for details and attribution.

Models are downloaded by you from their original sources and remain under
their respective licenses; Ghostie does not relicense them.
