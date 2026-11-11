#!/usr/bin/env python3
"""Draft a hand-correctable reference transcript from two decodes of one track.

Scoring a decoder needs the truth, and typing out ten minutes of a call from
nothing is an afternoon. Two engines that agree on a word are almost always
right about it, so this writes the stretch once, marks only where they differ,
and leaves a person to settle those by ear:

    05:33  Så jag behövde boka, den hittade att jag skulle boka flyg {recommedation|och ackommodation} for London

Listen, keep the right side of each {a|b} (or type what was said), fix
anything both got wrong, and score with scripts/score-reference.py.

    scripts/reference-draft.py <a.segments.json> <b.segments.json> <from-s> <to-s> > ref.txt

Both inputs are whisper-cli `-oj` shaped (what `ghostie transcribe-probe`
and GHOSTIE_DUMP_SEGMENTS write). Lines follow A's segments.
"""
import difflib, json, re, sys


def load(path, lo, hi):
    out = []
    for item in json.load(open(path))["transcription"]:
        start = item["offsets"]["from"] / 1000
        if lo <= start < hi and item["text"].strip():
            out.append((start, item["text"].strip().split()))
    return out


def norm(word):
    return re.sub(r"[^\w]", "", word.lower())


def main():
    a_path, b_path, lo, hi = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
    a, b = load(a_path, lo, hi), load(b_path, lo, hi)
    a_words = [(w, i) for i, (_, ws) in enumerate(a) for w in ws]
    b_words = [w for _, ws in b for w in ws]
    ops = difflib.SequenceMatcher(None, [norm(w) for w, _ in a_words],
                                  [norm(w) for w in b_words], autojunk=False).get_opcodes()
    lines = [[] for _ in a]
    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            for w, seg in a_words[i1:i2]:
                lines[seg].append(w)
            continue
        # A disagreement sits on the line of A's first word in it, or of the
        # word just before when A has nothing there.
        seg = a_words[i1][1] if i1 < len(a_words) else len(a) - 1
        if i1 == i2 and i1 > 0:
            seg = a_words[i1 - 1][1]
        left = " ".join(w for w, _ in a_words[i1:i2])
        right = " ".join(b_words[j1:j2])
        lines[seg].append("{%s|%s}" % (left, right))
    print(f"# Reference draft, {int(lo)}–{int(hi)} s. A = {a_path}")
    print(f"# B = {b_path}")
    print("# Resolve every {A|B} by ear, correct anything else, then score-reference.py.")
    for (start, _), words in zip(a, lines):
        if words:
            print(f"{int(start) // 60:02d}:{int(start) % 60:02d}  {' '.join(words)}")


if __name__ == "__main__":
    main()
