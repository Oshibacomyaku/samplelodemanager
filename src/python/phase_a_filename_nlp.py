#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


STOPWORDS = {
    "bpm", "loop", "loops", "one", "shot", "drum", "drums",
    "wav", "aif", "aiff", "flac", "mp3", "ogg", "m4a", "aac",
    "cymatics", "cymatic", "sample", "samples", "vol", "vol1", "vol2",
}

ALIAS = {
    "kick": "kicks",
    "snare": "snares",
    "clap": "claps",
    "rim": "rims",
    "hihat": "hats",
    "hi hat": "hats",
    "hi-hat": "hats",
    "open hat": "hats",
    "openhat": "hats",
    "cymbal": "cymbals",
    "shaker": "shakers",
    "perc": "percussion",
    "reese": "bass",
    "neuro": "bass",
    "growl": "bass",
}


def norm_text(text: str) -> str:
    return (text or "").lower()


def tokenize(text: str) -> list[str]:
    return re.findall(r"[a-z0-9#]+", norm_text(text))


def singular_plural_forms(tok: str) -> list[str]:
    out = [tok]
    if tok.endswith("s") and len(tok) >= 4:
        out.append(tok[:-1])
    else:
        out.append(tok + "s")
    return out


def is_noisy_candidate(c: str) -> bool:
    c = norm_text(c).strip()
    if not c:
        return True
    if re.search(r"\d", c):
        return True
    words = c.split()
    if len(words) > 3:
        return True
    for w in words:
        if len(w) < 3:
            return True
        if w in STOPWORDS:
            return True
    return False


def extract_candidates(filename: str, full_path: str, pack: str) -> list[str]:
    text = f"{filename} {Path(full_path).stem} {pack}"
    tokens = tokenize(text)
    cands: list[str] = []
    seen = set()

    def add(v: str) -> None:
        v = norm_text(v).strip()
        if not v or v in seen:
            return
        seen.add(v)
        cands.append(v)

    for t in tokens:
        add(t)
    for i in range(len(tokens) - 1):
        add(tokens[i] + " " + tokens[i + 1])

    final: list[str] = []
    seen2 = set()
    for c in cands:
        base = ALIAS.get(c, c)
        if is_noisy_candidate(base):
            continue
        for form in [base]:
            if form not in seen2:
                seen2.add(form)
                final.append(form)
        if " " not in base and re.fullmatch(r"[a-z#]+", base or ""):
            for form in singular_plural_forms(base):
                if form not in seen2 and not is_noisy_candidate(form):
                    seen2.add(form)
                    final.append(form)
    return final


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    in_path = Path(args.input)
    out_path = Path(args.output)

    lines_out = []
    if in_path.exists():
        for raw in in_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            parts = raw.split("\t")
            if len(parts) < 4:
                continue
            idx, filename, full_path, pack = parts[0], parts[1], parts[2], parts[3]
            cands = extract_candidates(filename, full_path, pack)
            lines_out.append(f"{idx}\t{','.join(cands)}")

    out_path.write_text("\n".join(lines_out), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

