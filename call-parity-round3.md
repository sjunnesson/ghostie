# Round 3 follow-ups — what the 2026-09-11 call showed

Third Ghostie-vs-Wispr comparison (34-min 1:1 on Google Meet in Chrome,
manual record, 1.9.0-dev at cf6d0e3). Content is at parity: 83.8% token
overlap, 99.3% diarization agreement, coverage 1.00–1.05 in every 5-minute
bucket, zero hallucinated turns, 6m52s wall clock. The gaps left are not in
the transcript. They are in what happens *around* it. Four items, in the
order they should land.

## 1. Browser Meet detection has never fired on a real call

**Evidence.** Every `Call detected (Meet…)` line in `~/.ghostie/ghostie.log`
is a selftest run. `Meeting roster:` has never been logged. Today's call
produced no `Possible call` line at all, so the AX roster walk never ran and
Participant 1 stayed unnamed while Wispr read "Jose Chavarría" off the same
tab. The summary then guessed the participant's location wrong.

**Where it dies.** `DetectionCoordinator` only pays for the tab-title probe
when `browserMicInUse` is true, and only walks the roster when the probe hit.
`browserMicInUse` needs an audio process whose `bundleId` matches
`com.google.chrome` or a `com.google.chrome.` prefix. The bundle id comes from
`NSRunningApplication(processIdentifier:)` (`CoreAudioActivityProvider.swift:265`).
Chrome's mic is held by a helper process, and `NSRunningApplication` returns
nil for helpers that are not LaunchServices apps. Nil bundle → no browser
mic → no probe → no roster. This is a hypothesis, not yet measured.

**Step 1 — measure (10 min, needs a Meet tab).** Open a solo Meet in Chrome
with the mic on and run:

```
ghostie diagnose-detect --duration 20 --json
```

Look at the audio-process rows. If the Chrome helper shows `bundleId: null`
while `isRunningInput: true`, the hypothesis holds. Also run
`ghostie roster-probe` in the same window to confirm the People panel is
readable at all. Both commands already exist.

**Step 2 — resolve helpers to their app.** In `CoreAudioActivityProvider`,
when `NSRunningApplication` gives nil, fall back to
`responsibility_get_pid_responsible_for_pid(pid)` and look that pid up
instead. That is the API macOS itself uses to attribute a helper's
permissions to its parent app, so a Chrome renderer/audio-service process
reports as Chrome. Add a selftest fixture: a process with nil bundle and a
responsible pid that resolves to a browser must count as browser mic use.

**Step 3 — run the probe while a capture is live.** A manual recording
leaves the state machine idle, so even with step 2 the probe depends on the
mic signal. While any recorder is live (manual or detected), run the tab
probe and `sampleRosterIfDue` unconditionally. The roster sample interval
already bounds the cost. This also makes naming work on the day Chrome
changes how it holds the mic.

**Step 4 — check the title rule against today's Chrome.** The rule requires
a `Meet – ` prefix (`AXBrowserTabProvider.meetingSite`). Read the actual
window title during the step 1 test. If Chrome now titles the window
differently, widen the rule with a fixture, not a guess.

**Done when:** a real Meet call logs `Possible call`, `Call detected (Meet…)`
and `Meeting roster: <name>` without a manual start, and the note names the
other party.

## 2. The mic conversion warning is a false positive

**Evidence.** 11:00:28: "the 16 kHz conversion produced silence 5 times —
the 'Me' track is being lost in conversion". The Me track measured −25 to
−30 dBFS in every minute of the call and decoded 330 segments.

**Why.** `MicCapture.swift:339` counts every buffer where the float input
had *any* nonzero sample and the int16 output was all zero. The counter is
cumulative over the session, not a run. A near-silent float buffer (all
samples below 1/32768) rounds to all-zero int16 legitimately, and five of
those over 30 seconds of pre-call quiet trips the alarm.

**Fix.** Two changes, both in the same function:
- Count only buffers whose input peak is at least one int16 step
  (`abs(f) >= 1.0/32768`). Quantization silence is not lost signal.
- Make it a run: reset the counter whenever a converted buffer carries
  signal, and warn on `conversionLossAlarm` *consecutive* losses.

Log a one-line recovery ("conversion recovered after N buffers") so a
transient shows up as transient. Selftest: feed 5 sub-LSB buffers then a
loud one — no warning; feed 5 consecutive loud-in/zero-out buffers — warning.

**Done when:** the warning never fires on a call whose Me track decodes, and
the v1.7.1 regression case (9ch→1ch converter writing zeros) still fires it.

## 3. Sentence-ending rate: 64% vs Wispr's 97%

**Evidence.** 156 of 244 Ghostie turns end a sentence. Round-2 runs read
66–80%. Wispr's 97% is partly cosmetic: its refiner drops short backchannels
("totally", "Yep, yep", "Costa Rica, yeah") and deleted a 32-word passage
Ghostie kept. Chasing 97% would mean deleting content. The honest target is
the round-2 band, 75–80%.

**What is actually short.** Not the "already punctuated" skip — that path
only skips blocks that *already* end a sentence (`TranscriptRefiner.swift:386`).
The non-terminal turns are (a) genuine interruptions ("Um, I've seen") and
(b) fragments the turn split leaves behind when a repunctuated block is cut
at a speaker change.

**Fix, in `TranscriptRefiner.split`:**
- When a turn does not end a sentence and the same speaker's next turn
  starts within a short gap (≤ 2 s, same value the merge step uses), join
  them. Today they stay separate because the other track interleaved.
- Treat an em dash or ellipsis as terminal for the *interrupted* case, and
  have the punctuation prompt end an interrupted turn with "—" rather than
  a comma. That makes the metric honest instead of inflating it.

Measure on the three fixtures (2026-08-28, 2026-09-08, 2026-09-11) with
`ghostie process <dir>` into a scratch notes folder; the compare script from
the round-3 session prints the rate. Overlap must not move.

**Done when:** all three fixtures read ≥ 75% with overlap unchanged.

## 4. Short-call overhead: 12 s per audio-minute vs 10

**Evidence.** Today's 6m52s breaks down as server start 21s, LID probes 52s,
decode 2m28s, punctuation 2m30s, summary 34s. Decode is on the round-2 rate.
Two stages are not.

**Punctuation only used 2 of 3 slots.** 146 blocks at `batchTurns = 80` is 2
batches, and `maxConcurrentBatches = 3`. Size batches so there are at least
three whenever there are enough blocks:
`batchSize = min(batchTurns, max(20, ceil(n / maxConcurrentBatches)))`,
still under `maxBatchChars`. Expected: 2m30s → ~1m40s on this call, no
change on long calls.

**LID probes run the two tracks in series** (26 s each). Run them
concurrently against the same whisper-server. Expected: 52s → ~30s.

**Server start (21s)** could begin when the recording starts instead of
when it ends. Cheap, but it keeps a large-v3 process resident for the whole
call. Defer; note it in [[ghostie-perf-backlog]].

**Done when:** a 30-minute call processes at ≤ 10 s per audio-minute.

## Order and gating

1 first — it is the only item that changes what the note says. 2 is a
half-hour fix and can ride the same commit day. 3 and 4 are independent of
each other and of 1; both are measured on the three real-audio fixtures and
need no live call. Item 1 needs one solo Meet session for step 1 and one
real call for the "done when".
