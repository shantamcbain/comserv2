#!/usr/bin/env python3
"""Split CHANGELOG.tt cl-entry blocks into changelog/entries/<id>.inc.

Fragments use .inc so the Documentation scanner (.tt/.md only) does not
publish each note as /Documentation/<id>.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # Comserv/
SRC = ROOT / "root/Documentation/changelog/CHANGELOG.tt"
OUT = ROOT / "root/Documentation/changelog/entries"
ENTRY_START = re.compile(
    r'<div\s+id="([^"]+)"\s+class="cl-entry"',
    re.I,
)


def main() -> None:
    text = SRC.read_text(encoding="utf-8")
    OUT.mkdir(parents=True, exist_ok=True)
    starts = [m.start() for m in ENTRY_START.finditer(text)]
    if not starts:
        raise SystemExit("no cl-entry blocks found")
    seen: dict[str, int] = {}
    written = 0
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(text)
        html = text[start:end].rstrip() + "\n"
        m = ENTRY_START.search(html)
        if not m:
            continue
        eid = m.group(1).strip()
        if not eid:
            continue
        if eid in seen:
            seen[eid] += 1
            eid = f"{eid}-{seen[eid]}"
        else:
            seen[eid] = 1
        safe = re.sub(r"[^A-Za-z0-9._-]", "-", eid)
        path = OUT / f"{safe}.inc"
        path.write_text(html, encoding="utf-8")
        written += 1
    print(f"wrote {written} entries to {OUT} (starts={len(starts)})")


if __name__ == "__main__":
    main()
