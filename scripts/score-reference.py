#!/usr/bin/env python3
"""Word error rate of one or more decodes against a hand-corrected reference.

    scripts/score-reference.py <reference.txt> <segments.json>...

The reference is what scripts/reference-draft.py wrote, after a person has
resolved every {A|B}. Each decode is whisper-cli `-oj` shaped and is scored
over the reference's own time window only. Words are compared lowercased with
punctuation stripped, so this measures the words and not the commas.

Refuses a reference that still has an unresolved {A|B}: a number computed
against a guess is worse than no number.
"""
import json, re, sys


def words(text):
    return re.sub(r"[^\w\s]", " ", text.lower()).split()


def reference(path):
    ref, times = [], []
    for line in open(path):
        if line.startswith("#") or not line.strip():
            continue
        m = re.match(r"(\d+):(\d\d)\s+(.*)", line)
        if not m:
            sys.exit(f"not a reference line: {line.strip()[:60]}")
        if "{" in m.group(3) or "|" in m.group(3):
            sys.exit(f"unresolved choice at {m.group(1)}:{m.group(2)} — settle every {{A|B}} first")
        times.append(int(m.group(1)) * 60 + int(m.group(2)))
        ref += words(m.group(3))
    return ref, min(times), max(times)


def errors(ref, hyp):
    """Levenshtein over words → (substitutions, deletions, insertions)."""
    prev = [(j, 0, 0, j) for j in range(len(hyp) + 1)]          # (cost, sub, del, ins)
    for i in range(1, len(ref) + 1):
        cur = [(i, 0, i, 0)]
        for j in range(1, len(hyp) + 1):
            if ref[i - 1] == hyp[j - 1]:
                cur.append(prev[j - 1])
                continue
            s, d, n = prev[j - 1], prev[j], cur[j - 1]
            best = min((s[0], 0), (d[0], 1), (n[0], 2))
            if best[1] == 0:
                cur.append((s[0] + 1, s[1] + 1, s[2], s[3]))
            elif best[1] == 1:
                cur.append((d[0] + 1, d[1], d[2] + 1, d[3]))
            else:
                cur.append((n[0] + 1, n[1], n[2], n[3] + 1))
        prev = cur
    return prev[-1][1:]


def main():
    ref, lo, hi = reference(sys.argv[1])
    print(f"reference: {len(ref)} words, {lo // 60:02d}:{lo % 60:02d}–{hi // 60:02d}:{hi % 60:02d}")
    for path in sys.argv[2:]:
        hyp = []
        for item in json.load(open(path))["transcription"]:
            # The window is closed by the reference's last line's start, so
            # allow that line its length.
            if lo - 1 <= item["offsets"]["from"] / 1000 <= hi + 1:
                hyp += words(item["text"])
        s, d, i = errors(ref, hyp)
        print(f"  {100 * (s + d + i) / max(1, len(ref)):5.1f}% WER  "
              f"({s} wrong, {d} missed, {i} added; {len(hyp)} words)  {path}")


if __name__ == "__main__":
    main()
