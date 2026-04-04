#!/usr/bin/env python3
import argparse
import difflib
from pathlib import Path


def read_lines(path: Path):
    if not path.exists():
        return []
    out = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        v = line.strip().lower()
        if v:
            out.append(v)
    return out


def normalize_forms(tok: str):
    forms = {tok}
    forms.add(tok.replace("-", " "))
    forms.add(tok.replace("_", " "))
    if tok.endswith("s") and len(tok) >= 4:
        forms.add(tok[:-1])
    else:
        forms.add(tok + "s")
    return list(forms)


def score_alias(alias: str, canon: str):
    best = 0.0
    for a in normalize_forms(alias):
        for c in normalize_forms(canon):
            r = difflib.SequenceMatcher(None, a, c).ratio()
            if r > best:
                best = r
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--unknown", required=True)
    ap.add_argument("--vocab", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    unknown = read_lines(Path(args.unknown))
    vocab = read_lines(Path(args.vocab))
    vocab = sorted(set(vocab))

    rows = []
    for tok in unknown:
        # candidate shortlist by text similarity
        cands = difflib.get_close_matches(tok, vocab, n=5, cutoff=0.72)
        best_tag = None
        best_score = 0.0
        for c in cands:
            s = score_alias(tok, c)
            if s > best_score:
                best_score = s
                best_tag = c
        if best_tag and best_score >= 0.82:
            rows.append((tok, best_tag, best_score))

    out_lines = [f"{a}\t{b}\t{s:.4f}" for a, b, s in rows]
    Path(args.output).write_text("\n".join(out_lines), encoding="utf-8")


if __name__ == "__main__":
    main()

