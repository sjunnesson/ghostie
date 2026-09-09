#!/usr/bin/env python3
"""Score a Ghostie transcript against a reference recording of the same call.

Ghostie has something most transcription work doesn't: a second recorder was
running for the 2026-09-08 call, so there is an independent transcript of the
same audio. That makes "did this change hurt the transcript?" a measurement
instead of an argument, which is the only reason the decode-speed work in
decode-speed.md can be attempted at all.

    scripts/score-transcript.py <ghostie_transcript.md> <reference.ndjson>
    scripts/score-transcript.py <a.md> <b.md>          # two Ghostie runs

Reference format is Wispr Flow's `refined.ndjson` (one JSON object per line:
`timestamp` "MM:SS", `text`, `speaker.id`). A second Ghostie transcript works
too, which is how you compare two runs of the pipeline against each other.

What it reports, and why each number is here:

  token overlap      The headline. Longest-common-subsequence agreement over
                     normalized words, both directions. Insensitive to turn
                     boundaries and speaker labels, so it measures the words
                     and nothing else.
  coverage buckets   Words per 5 minutes, as a ratio. A single number can hide
                     a track that dropped out for ten minutes; this can't.
  clock offset       Median seconds between the two timelines per bucket.
                     Constant is fine (the recorders started at different
                     moments); drifting is a bug.
  speaker agreement  Only when both sides carry speaker labels: how often the
                     same word is attributed to corresponding speakers.
  turn shape         Turns and words-per-turn. Readability, not accuracy — the
                     reference is the target shape.

Exit status is 1 when a --bar is given and not met, so this can gate a change.
"""

import argparse
import collections
import difflib
import json
import re
import statistics
import sys

TURN = re.compile(r"^\*\*\[([\d:]+)\] ([^:]+):\*\*\s*(.*)$")
WORD = re.compile(r"[a-zà-ÿ0-9']+")


def seconds(stamp):
    parts = [int(p) for p in stamp.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return parts[0] * 3600 + parts[1] * 60 + parts[2]


def read_ghostie(path):
    """Ghostie's `*_transcript.md`: **[MM:SS] Speaker:** text"""
    out = []
    for line in open(path, encoding="utf-8"):
        m = TURN.match(line.strip())
        if m and "repeated audio removed" not in m.group(3):
            out.append((seconds(m.group(1)), m.group(2), m.group(3)))
    return out


def read_ndjson(path):
    """Wispr Flow's refined.ndjson."""
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        if "timestamp" not in d or "text" not in d:
            continue          # meta/observation lines
        speaker = (d.get("speaker") or {}).get("id")
        out.append((seconds(d["timestamp"]), f"S{speaker}", d["text"]))
    return out


def read(path):
    return read_ndjson(path) if path.endswith(".ndjson") else read_ghostie(path)


def tokens(rows):
    """Flat word stream, plus (time, speaker) per word for the bucket stats."""
    words, meta = [], []
    for t, spk, text in rows:
        for w in WORD.findall(text.lower()):
            words.append(w)
            meta.append((t, spk))
    return words, meta


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("candidate")
    ap.add_argument("reference")
    ap.add_argument("--bar", type=float, default=None,
                    help="minimum token overlap %% of candidate; exit 1 below it")
    ap.add_argument("--min-bucket", type=float, default=0.85,
                    help="minimum per-5-minute coverage ratio when --bar is set")
    args = ap.parse_args()

    cand, ref = read(args.candidate), read(args.reference)
    if not cand or not ref:
        print("one side is empty — wrong file?", file=sys.stderr)
        return 2

    ct, cm = tokens(cand)
    rt, rm = tokens(ref)
    ops = difflib.SequenceMatcher(a=ct, b=rt, autojunk=False).get_opcodes()
    matched = sum(o[2] - o[1] for o in ops if o[0] == "equal")

    def shape(name, rows, words):
        ends = sum(1 for r in rows
                   if r[2].strip().rstrip("\"'”’)]»").endswith((".", "?", "!", "…")))
        print(f"  {name:10s} {len(rows):5d} turns  {words:6d} words  "
              f"{words/len(rows):4.1f} w/turn  {100*ends/len(rows):3.0f}% end a sentence")

    print("shape")
    shape("candidate", cand, len(ct))
    shape("reference", ref, len(rt))

    overlap = 100 * matched / len(ct)
    print(f"\ntoken overlap  {matched} words — "
          f"{overlap:.1f}% of candidate, {100*matched/len(rt):.1f}% of reference")

    # Offsets and per-speaker agreement, from long equal blocks only: short
    # accidental matches ("yeah") would otherwise dominate both.
    drift, pairs = [], collections.Counter()
    for op, i1, i2, j1, j2 in ops:
        if op != "equal" or i2 - i1 < 8:
            continue
        for k in range(i2 - i1):
            drift.append(rm[j1 + k][0] - cm[i1 + k][0])
            pairs[(cm[i1 + k][1], rm[j1 + k][1])] += 1
    if drift:
        by_bucket = collections.defaultdict(list)
        for op, i1, i2, j1, j2 in ops:
            if op != "equal" or i2 - i1 < 8:
                continue
            for k in range(i2 - i1):
                by_bucket[cm[i1 + k][0] // 600].append(rm[j1 + k][0] - cm[i1 + k][0])
        spread = [statistics.median(v) for v in by_bucket.values()]
        print(f"clock offset   median {statistics.median(drift):+.0f}s, "
              f"per-10-min range {min(spread):+.0f}..{max(spread):+.0f}s "
              f"({'constant — fine' if max(spread) - min(spread) < 15 else 'DRIFTING — bug'})")

    # Speaker agreement under the best 1:1 mapping of label sets.
    clabels = sorted({c for c, _ in pairs})
    rlabels = sorted({r for _, r in pairs})
    if len(clabels) == 2 and len(rlabels) == 2 and sum(pairs.values()):
        a = pairs[(clabels[0], rlabels[0])] + pairs[(clabels[1], rlabels[1])]
        b = pairs[(clabels[0], rlabels[1])] + pairs[(clabels[1], rlabels[0])]
        print(f"speakers       {100*max(a, b)/sum(pairs.values()):.1f}% agreement "
              f"on {sum(pairs.values())} matched words")

    # Coverage: words per 5 minutes on each side, aligned by the median offset.
    shift = int(statistics.median(drift)) if drift else 0
    cb = collections.Counter((t + shift) // 300 for t, _ in cm)
    rb = collections.Counter(t // 300 for t, _ in rm)
    print("\ncoverage by 5-minute bucket (candidate/reference)")
    worst, worst_at = 1.0, None
    for b in sorted(set(cb) | set(rb)):
        if rb[b] < 100:                     # too little reference to judge
            continue
        ratio = cb[b] / rb[b]
        if ratio < worst:
            worst, worst_at = ratio, b
        bar = "█" * min(40, int(ratio * 30))
        flag = "  <<<" if ratio < args.min_bucket else ""
        print(f"  {b*5:3d}-{b*5+5:3d}m  {cb[b]:5d}/{rb[b]:<5d} {ratio:4.2f}  {bar}{flag}")
    if worst_at is not None:
        print(f"\nworst bucket   {worst:.2f} at {worst_at*5}-{worst_at*5+5} min")

    if args.bar is not None:
        ok = overlap >= args.bar and worst >= args.min_bucket
        print(f"\nBAR {'PASS' if ok else 'FAIL'} — overlap {overlap:.1f}% "
              f"(need ≥{args.bar}), worst bucket {worst:.2f} (need ≥{args.min_bucket})")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
