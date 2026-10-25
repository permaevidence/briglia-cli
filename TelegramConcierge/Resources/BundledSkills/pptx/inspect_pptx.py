#!/usr/bin/env python3
"""Inspect a .pptx file's structure: slides, titles, shapes, layouts.

Prints a JSON summary. Use it on a supplied template to learn its layouts
and placeholders before authoring, and on generated output to verify slide
count and structure.

Usage:
  python3 inspect_pptx.py deck.pptx              # slides with titles and shape counts
  python3 inspect_pptx.py template.pptx --layouts # available layouts and their placeholders
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from pptx import Presentation
    from pptx.util import Emu
except ImportError:
    print("error: python-pptx is required (briglia python-env install)", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect .pptx structure.")
    parser.add_argument("deck", type=Path)
    parser.add_argument("--layouts", action="store_true", help="List slide layouts and their placeholders")
    args = parser.parse_args()

    path = args.deck.expanduser().resolve()
    if not path.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 2

    prs = Presentation(str(path))

    if args.layouts:
        layouts = []
        for i, layout in enumerate(prs.slide_layouts):
            layouts.append({
                "index": i,
                "name": layout.name,
                "placeholders": [
                    {
                        "idx": ph.placeholder_format.idx,
                        "name": ph.name,
                        "type": str(ph.placeholder_format.type),
                    }
                    for ph in layout.placeholders
                ],
            })
        print(json.dumps(layouts, indent=2, ensure_ascii=False))
        return 0

    slides = []
    for i, slide in enumerate(prs.slides, 1):
        title = ""
        if slide.shapes.title is not None:
            title = slide.shapes.title.text
        shape_types: dict = {}
        for shape in slide.shapes:
            key = str(shape.shape_type)
            shape_types[key] = shape_types.get(key, 0) + 1
        slides.append({
            "slide": i,
            "layout": slide.slide_layout.name,
            "title": title[:100],
            "shapes": len(slide.shapes),
            "shape_types": shape_types,
            "has_notes": bool(slide.has_notes_slide and slide.notes_slide.notes_text_frame.text.strip()),
        })

    summary = {
        "slide_count": len(prs.slides),
        "slide_size_in": [round(Emu(prs.slide_width).inches, 2), round(Emu(prs.slide_height).inches, 2)],
        "slides": slides,
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
