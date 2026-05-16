# Ghostie

Listens to your **Microsoft Teams calls locally** — **no bot ever joins the
meeting** — automatically transcribes each call and writes a markdown summary
(context, decisions, action items) to a folder on your Mac.

## How it works (no bot, no Graph API)

1. **Detect** — polls CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`
   on the default input device and checks that Microsoft Teams is running. When
   both hold, a call is in progress; when the mic goes idle for a grace period,
   the call has ended. Nothing connects to the meeting.
2. **Record** — `ScreenCaptureKit` captures two independent local audio taps:
   system audio (everyone else) and your microphone (you), as two 16 kHz mono
   WAV files. No virtual audio driver, no bot participant.
3. **Transcribe** — [whisper.cpp](https://github.com/ggerganov/whisper.cpp) runs
   **entirely on your machine**. Call audio never leaves your Mac. Decoding
   uses hallucination-resistant settings and a per-track **hallucination
   guard** (see below). The two tracks are merged by timestamp and labelled
   **Me** vs **Participants**.
4. **Summarize** — the transcript is sent to the Anthropic API and turned into a
   structured markdown note: Context · Participants · Discussion · Decisions ·
   Action Items · Open Questions · Summary.
5. **Save** — `~/Documents/Teams Call Notes/2026-05-16_14-03_Teams-Call.md`
   (plus a transcript file). Audio is deleted afterwards by default.

The detect → record → process loop runs forever, so every call is captured
automatically with zero interaction.

## Menu bar app (recommended)

Ghostie runs as a **macOS menu bar app** — a 👻 ghost icon in the menu
header, no Dock icon, always watching.

```bash
./scripts/setup.sh        # whisper.cpp + model + build
./scripts/build-app.sh    # build, sign & install Ghostie.app to /Applications
open "/Applications/Ghostie.app"
```

`build-app.sh` auto-detects your signing identity (it uses a **Developer ID
Application** cert if present, so granted permissions persist across rebuilds).
Add `--notarize` to also notarize & staple (one-time
`xcrun notarytool store-credentials ghostie-notary …` first).

The menu bar icon reflects state (watching · ● recording 02:13 · summarizing)
and its menu gives quick access to everything:

- **Pause / Resume Listening**
- **Open Notes Folder** · **Open Last Summary**
- **Run 15-Second Test** (verifies the whole pipeline)
- **Settings…** (`⌘,`) — a real settings window for the notes folder, audio
  options, detection timing, whisper model/language/prompt, VAD, hallucination
  guard, and the Anthropic API key & model. Saving applies immediately (no
  restart) and an *Open config.json* button remains for power users.
- **Diagnostics**
- **Start at Login** (registers a launch item via `SMAppService`)
- **Quit** (finishes any in-progress summary first)

On the **first call** macOS prompts for **Screen Recording** and **Microphone**
for *Ghostie*. Grant both in *System Settings ▸ Privacy & Security*. Because
the app is signed with a stable Developer ID, this is a one-time step.

## CLI (headless / servers)

The same binary also runs without a UI — useful for launchd or remote boxes:

```bash
ghostie run                # headless watch loop; Ctrl-C to stop
ghostie test-record 15     # 15s smoke test through the full pipeline
ghostie process <dir>      # re-summarize a saved recording folder
ghostie install-service    # headless launchd service
ghostie doctor             # diagnostics
ghostie selftest           # verify the transcript hallucination guard
```

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
and asserts clean speech is left untouched.

## Configuration

Edit `~/.ghostie/config.json` (created on first run). Notable keys:

| Key | Default | Purpose |
|-----|---------|---------|
| `notesFolder` | `~/Documents/Teams Call Notes` | Where summaries are saved |
| `keepAudio` | `false` | Keep raw WAVs after processing |
| `endGraceSeconds` | `12` | Mic-idle time before a call is "ended" |
| `minCallSeconds` | `20` | Ignore calls shorter than this |
| `whisperModel` | `…/ggml-base.en.bin` | Bigger model = better accuracy, slower |
| `language` | `en` | `auto` for automatic detection |
| `cleanTranscript` | `true` | Run the hallucination guard |
| `initialPrompt` | business-call primer | Biases whisper punctuation; `""` to disable |
| `vadModel` | `…/ggml-silero-v5.1.2.bin` | Auto-used if present (`setup.sh --vad`) |
| `summaryModel` | `claude-sonnet-4-6` | Anthropic model for the analysis |

Environment overrides: `ANTHROPIC_API_KEY`, `GHOSTIE_NOTES_FOLDER`,
`GHOSTIE_WHISPER_MODEL`, `GHOSTIE_SUMMARY_MODEL`.

## Privacy

- Audio capture and transcription are 100% local.
- Only the **text transcript** is sent to Anthropic for summarization, and only
  if you set an API key. With no key, you still get the full local transcript;
  no AI analysis is produced and nothing leaves the machine.
- Recordings live in `~/.ghostie/recordings` only while processing and are
  deleted unless `keepAudio` is true.
- **Be mindful of consent laws and your employer's policy before recording
  calls.**

## Requirements

- macOS 15+ (uses ScreenCaptureKit native microphone capture)
- Swift toolchain (Xcode or Command Line Tools)
- Homebrew (for `whisper-cpp`)

## Limitations

- Detection assumes a Teams mic session = a call. If another app uses the mic
  while Teams is open, that audio is captured too. Tune `triggerBundlePrefixes`.
- System-audio capture records *all* system sound during the call; during a
  Teams call that is overwhelmingly the other participants.
- Speaker labels are track-based (Me vs everyone-else), not per-person
  diarization.
