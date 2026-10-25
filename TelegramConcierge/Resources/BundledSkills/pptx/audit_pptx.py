#!/usr/bin/env python3
"""Audit a .pptx structurally, without any renderer.

python-pptx exposes exact slide geometry, so many visual defects are
computable directly. Checks per slide:

- shapes extending beyond the slide bounds (exact)
- stretched images: embedded picture's native aspect ratio (crop-adjusted)
  vs the shape's aspect ratio (exact)
- likely text overflow: estimated text height vs frame capacity
  (HEURISTIC — real metrics depend on the font renderer; thresholds are
  conservative, so silence near the boundary is not a guarantee)
- explicit font sizes below a readability floor
- placeholders left empty on slides
- heavily overlapping text-bearing shapes

Findings are leads for review, not verdicts. When LibreOffice is
available, the rendered pages remain authoritative.

Usage:
  python3 audit_pptx.py deck.pptx
  python3 audit_pptx.py deck.pptx --min-font-pt 9 --overflow-ratio 1.5
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

try:
    from pptx import Presentation
    from pptx.util import Emu
except ImportError:
    print("error: python-pptx is required (briglia python-env install)", file=sys.stderr)
    raise SystemExit(1)

EMU_PER_PT = 12700
DEFAULT_FONT_PT = 18.0
LINE_HEIGHT_FACTOR = 1.25
AVG_CHAR_WIDTH_FACTOR = 0.55  # average glyph width as a fraction of font size


def emu_to_in(value) -> float:
    return round(Emu(value).inches, 2) if value is not None else 0.0


def shape_box(shape):
    try:
        if None in (shape.left, shape.top, shape.width, shape.height):
            return None
        return (shape.left, shape.top, shape.left + shape.width, shape.top + shape.height)
    except Exception:
        return None


def check_off_slide(slide_idx, shape, slide_w, slide_h, findings):
    box = shape_box(shape)
    if box is None:
        return
    tolerance = Emu(45720)  # 0.05" — ignore rounding noise; real bleeds exceed it
    overhang = []
    if box[0] < -tolerance:
        overhang.append(f"left by {emu_to_in(-box[0])}in")
    if box[1] < -tolerance:
        overhang.append(f"top by {emu_to_in(-box[1])}in")
    if box[2] > slide_w + tolerance:
        overhang.append(f"right by {emu_to_in(box[2] - slide_w)}in")
    if box[3] > slide_h + tolerance:
        overhang.append(f"bottom by {emu_to_in(box[3] - slide_h)}in")
    if overhang:
        findings.append({
            "slide": slide_idx, "shape": shape.name,
            "detail": "extends beyond slide bounds: " + ", ".join(overhang),
        })


def check_stretched_image(slide_idx, shape, findings):
    if shape.shape_type is None or "PICTURE" not in str(shape.shape_type):
        return
    try:
        native_w, native_h = shape.image.size
        crop_w = max(1e-6, 1.0 - (shape.crop_left or 0) - (shape.crop_right or 0))
        crop_h = max(1e-6, 1.0 - (shape.crop_top or 0) - (shape.crop_bottom or 0))
        source_aspect = (native_w * crop_w) / (native_h * crop_h)
        if not shape.width or not shape.height:
            return
        shape_aspect = shape.width / shape.height
        distortion = shape_aspect / source_aspect
    except Exception:
        return
    if distortion > 1.1 or distortion < 1 / 1.1:
        findings.append({
            "slide": slide_idx, "shape": shape.name,
            "detail": f"image stretched: source aspect {source_aspect:.2f} vs shape aspect {shape_aspect:.2f} "
                      f"({(max(distortion, 1 / distortion) - 1) * 100:.0f}% distortion)",
        })


def paragraph_font_pt(paragraph):
    """Best-known explicit size for a paragraph, plus whether it was assumed."""
    sizes = [run.font.size.pt for run in paragraph.runs if run.font.size is not None]
    if sizes:
        return max(sizes), False
    if paragraph.font.size is not None:
        return paragraph.font.size.pt, False
    return DEFAULT_FONT_PT, True


def check_text_overflow(slide_idx, shape, ratio_known, ratio_assumed, findings):
    if not getattr(shape, "has_text_frame", False):
        return
    tf = shape.text_frame
    if not tf.text.strip():
        return
    box = shape_box(shape)
    if box is None:
        return

    def margin(value, default):
        return value if value is not None else default

    usable_w_pt = (shape.width - margin(tf.margin_left, 91440) - margin(tf.margin_right, 91440)) / EMU_PER_PT
    usable_h_pt = (shape.height - margin(tf.margin_top, 45720) - margin(tf.margin_bottom, 45720)) / EMU_PER_PT
    if usable_w_pt <= 0 or usable_h_pt <= 0:
        return

    total_h_pt = 0.0
    any_assumed = False
    for paragraph in tf.paragraphs:
        size_pt, assumed = paragraph_font_pt(paragraph)
        any_assumed = any_assumed or assumed
        text = "".join(run.text for run in paragraph.runs)
        chars_per_line = max(1.0, usable_w_pt / (AVG_CHAR_WIDTH_FACTOR * size_pt))
        lines = max(1, math.ceil(len(text) / chars_per_line)) if text.strip() else 1
        total_h_pt += lines * LINE_HEIGHT_FACTOR * size_pt

    threshold = ratio_assumed if any_assumed else ratio_known
    if total_h_pt > usable_h_pt * threshold:
        findings.append({
            "slide": slide_idx, "shape": shape.name,
            "detail": f"likely text overflow: ~{total_h_pt:.0f}pt of text in a {usable_h_pt:.0f}pt frame "
                      f"({total_h_pt / usable_h_pt:.1f}x capacity"
                      + (", font sizes partly assumed" if any_assumed else "") + ")",
        })


def check_tiny_fonts(slide_idx, shape, min_pt, findings):
    if not getattr(shape, "has_text_frame", False):
        return
    for paragraph in shape.text_frame.paragraphs:
        for run in paragraph.runs:
            if run.font.size is not None and run.font.size.pt < min_pt and run.text.strip():
                findings.append({
                    "slide": slide_idx, "shape": shape.name,
                    "detail": f"{run.font.size.pt:g}pt text: {run.text.strip()[:40]!r}",
                })
                break  # one finding per shape is enough


def check_empty_placeholder(slide_idx, shape, findings):
    if not shape.is_placeholder or not getattr(shape, "has_text_frame", False):
        return
    ph_type = str(shape.placeholder_format.type)
    if "PICTURE" in ph_type or "OBJECT" in ph_type:
        return
    if not shape.text_frame.text.strip():
        findings.append({
            "slide": slide_idx, "shape": shape.name,
            "detail": f"empty placeholder ({ph_type}) — fill it or remove it from the slide",
        })


def check_overlaps(slide_idx, shapes, findings):
    text_shapes = [s for s in shapes
                   if getattr(s, "has_text_frame", False) and s.text_frame.text.strip() and shape_box(s)]
    for i in range(len(text_shapes)):
        for j in range(i + 1, len(text_shapes)):
            a, b = shape_box(text_shapes[i]), shape_box(text_shapes[j])
            inter_w = min(a[2], b[2]) - max(a[0], b[0])
            inter_h = min(a[3], b[3]) - max(a[1], b[1])
            if inter_w <= 0 or inter_h <= 0:
                continue
            inter = inter_w * inter_h
            smaller = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
            if smaller > 0 and inter / smaller > 0.3:
                findings.append({
                    "slide": slide_idx,
                    "shape": f"{text_shapes[i].name} + {text_shapes[j].name}",
                    "detail": f"text shapes overlap by {inter / smaller * 100:.0f}% of the smaller one",
                })


def main() -> int:
    parser = argparse.ArgumentParser(description="Structural audit of a .pptx (no renderer needed).")
    parser.add_argument("deck", type=Path)
    parser.add_argument("--min-font-pt", type=float, default=10.0, help="Readability floor (default 10pt)")
    parser.add_argument("--overflow-ratio", type=float, default=1.3,
                        help="Flag text frames whose estimated content exceeds capacity by this factor (default 1.3)")
    args = parser.parse_args()

    path = args.deck.expanduser().resolve()
    if not path.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 2

    prs = Presentation(str(path))
    slide_w, slide_h = prs.slide_width, prs.slide_height
    # When font sizes had to be assumed, demand a clearer exceedance before flagging.
    ratio_assumed = max(args.overflow_ratio + 0.3, 1.6)

    off_slide: list = []
    stretched: list = []
    overflow: list = []
    tiny: list = []
    empty_ph: list = []
    overlaps: list = []

    for index, slide in enumerate(prs.slides, 1):
        for shape in slide.shapes:
            check_off_slide(index, shape, slide_w, slide_h, off_slide)
            check_stretched_image(index, shape, stretched)
            check_text_overflow(index, shape, args.overflow_ratio, ratio_assumed, overflow)
            check_tiny_fonts(index, shape, args.min_font_pt, tiny)
            check_empty_placeholder(index, shape, empty_ph)
        check_overlaps(index, list(slide.shapes), overlaps)

    report = {
        "deck": str(path),
        "slides": len(prs.slides),
        "slide_size_in": [emu_to_in(slide_w), emu_to_in(slide_h)],
        "off_slide_shapes": off_slide,
        "stretched_images": stretched,
        "likely_text_overflow": overflow[:25],
        "tiny_fonts": tiny[:25],
        "empty_placeholders": empty_ph,
        "overlapping_text_shapes": overlaps[:25],
        "findings_total": sum(len(x) for x in (off_slide, stretched, overflow, tiny, empty_ph, overlaps)),
        "note": "Geometry checks (off-slide, stretched images) are exact. Overflow is a conservative "
                "estimate — a clean report does not guarantee no overflow; rendered QA stays authoritative. "
                "Group-shape children are not descended into.",
    }
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
