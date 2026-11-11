#!/usr/bin/env python3
"""Turn a `ghostie transcribe-probe --out <dir>` into a transcript
scripts/score-transcript.py can read, so a decoder experiment is scored with
the same script and the same bar as a real note.

    scripts/segments-to-transcript.py <probe-out-dir> > probe_transcript.md

Only the two tracks merged by time — no cleaning, punctuation or naming, so it
measures the decode and nothing downstream of it.
"""
import json, sys

rows = []
for tag, speaker in (("me", "Me"), ("participants", "Participants")):
    for item in json.load(open(f"{sys.argv[1]}/{tag}.segments.json"))["transcription"]:
        if item["text"].strip():
            rows.append((item["offsets"]["from"] // 1000, speaker, item["text"].strip()))
for sec, speaker, text in sorted(rows):
    stamp = f"{sec // 3600}:{sec % 3600 // 60:02d}:{sec % 60:02d}" if sec >= 3600 else f"{sec // 60:02d}:{sec % 60:02d}"
    print(f"**[{stamp}] {speaker}:** {text}\n")
