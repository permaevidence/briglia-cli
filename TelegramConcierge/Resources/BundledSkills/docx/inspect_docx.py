#!/usr/bin/env python3
"""Inspect a .docx file's structure: headings, paragraphs, tables, sections.

Prints a JSON summary useful both for understanding an existing document
before editing it and for verifying generated output uses real Word
structure (Heading styles, real tables, sane section geometry).

Usage:
  python3 inspect_docx.py document.docx
  python3 inspect_docx.py document.docx --headings-only
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from docx import Document
    from docx.shared import Emu
except ImportError:
    print("error: python-docx is required (briglia python-env install)", file=sys.stderr)
    raise SystemExit(1)


def emu_to_inches(value) -> float | None:
    if value is None:
        return None
    return round(Emu(value).inches, 2)


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect .docx structure.")
    parser.add_argument("document", type=Path)
    parser.add_argument("--headings-only", action="store_true", help="Print only the heading outline")
    args = parser.parse_args()

    path = args.document.expanduser().resolve()
    if not path.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 2

    doc = Document(str(path))

    headings = [
        {"style": p.style.name, "text": p.text[:120]}
        for p in doc.paragraphs
        if p.style is not None and p.style.name.startswith("Heading") and p.text.strip()
    ]

    if args.headings_only:
        print(json.dumps(headings, indent=2, ensure_ascii=False))
        return 0

    summary = {
        "paragraphs": len(doc.paragraphs),
        "headings": headings,
        "tables": [
            {"index": i, "rows": len(t.rows), "cols": len(t.columns)}
            for i, t in enumerate(doc.tables, 1)
        ],
        "inline_images": len(doc.inline_shapes),
        "sections": [
            {
                "index": i,
                "page_width_in": emu_to_inches(s.page_width),
                "page_height_in": emu_to_inches(s.page_height),
                "margins_in": {
                    "top": emu_to_inches(s.top_margin),
                    "bottom": emu_to_inches(s.bottom_margin),
                    "left": emu_to_inches(s.left_margin),
                    "right": emu_to_inches(s.right_margin),
                },
            }
            for i, s in enumerate(doc.sections, 1)
        ],
        "styles_in_use": sorted({
            p.style.name for p in doc.paragraphs if p.style is not None and p.text.strip()
        }),
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
