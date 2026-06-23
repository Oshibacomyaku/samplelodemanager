#!/usr/bin/env python3
# @noindex
"""Verify index.xml lists every @provides [nomain] src/ path from the entry script.

Usage:
  python scripts/verify_index_provides.py
  python scripts/verify_index_provides.py --version 0.2.9

Exits 0 when the latest (or specified) index version includes all src/ provides.
Does not auto-generate index.xml (reapack-index limitations); validation only.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENTRY = ROOT / "SampleLodeManager" / "oshibacomyaku_Sample Lode Manager.lua"
INDEX = ROOT / "index.xml"

PROVIDES_RE = re.compile(r'^--\s*@provides\s+\[nomain\]\s+(.+)$')
SOURCE_FILE_RE = re.compile(r'<source[^>]+file="([^"]+)"')
VERSION_RE = re.compile(r'<version\s+name="([^"]+)"')


def read_provides(entry_path: Path) -> set[str]:
    out: set[str] = set()
    for line in entry_path.read_text(encoding="utf-8").splitlines():
        m = PROVIDES_RE.match(line.strip())
        if not m:
            continue
        rel = m.group(1).strip().replace("\\", "/")
        if rel.startswith("src/"):
            out.add(rel)
    return out


def read_index_sources_for_version(index_path: Path, version: str | None) -> set[str]:
    text = index_path.read_text(encoding="utf-8")
    versions = VERSION_RE.findall(text)
    if not versions:
        raise SystemExit("index.xml: no <version> elements found")
    target = version or versions[-1]

    # Slice from target <version> to next </version>
    marker = f'<version name="{target}"'
    start = text.find(marker)
    if start < 0:
        raise SystemExit(f"index.xml: version {target!r} not found")

    end = text.find("</version>", start)
    if end < 0:
        raise SystemExit(f"index.xml: unclosed version {target!r}")

    block = text[start:end]
    files = {m.group(1).replace("\\", "/") for m in SOURCE_FILE_RE.finditer(block)}
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="index.xml version name (default: latest)")
    parser.add_argument("--entry", type=Path, default=ENTRY)
    parser.add_argument("--index", type=Path, default=INDEX)
    args = parser.parse_args()

    if not args.entry.is_file():
        print(f"Missing entry: {args.entry}", file=sys.stderr)
        return 2
    if not args.index.is_file():
        print(f"Missing index: {args.index}", file=sys.stderr)
        return 2

    provides = read_provides(args.entry)
    indexed = read_index_sources_for_version(args.index, args.version)
    version = args.version or VERSION_RE.findall(args.index.read_text(encoding="utf-8"))[-1]

    missing = sorted(provides - indexed)
    extra = sorted(indexed - provides)

    print(f"Entry @provides src/: {len(provides)}")
    print(f"index.xml v{version} <source file=...>: {len(indexed)}")

    if missing:
        print("\nMissing from index.xml:")
        for p in missing:
            print(f"  - {p}")
    if extra:
        print("\nIn index but not in @provides (src/):")
        for p in extra:
            print(f"  - {p}")

    if missing:
        return 1
    print("\nOK: all src/ @provides rows are listed in index.xml")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
