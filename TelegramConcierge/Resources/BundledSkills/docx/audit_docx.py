#!/usr/bin/env python3
"""Audit a .docx structurally, without any renderer.

Two tiers, separated in the report:

EXACT (fix these):
- stretched images: inline shape display aspect vs the embedded image's
  native pixel aspect
- table rows with height rule EXACTLY — they clip wrapped text
- heading hierarchy jumps (Heading 1 -> Heading 3 with no Heading 2)
- placeholder leftovers (lorem ipsum, TODO/TBD/FIXME/XXX, [ALL-CAPS])
  in body, tables, headers, and footers
- tables declared wider than the printable page

HEURISTIC (judge these):
- fake headings: short, fully bold, Normal-styled paragraphs that should
  be real Heading styles (these empty Word's navigation pane)
- manual list markers typed as text ("1.", "•", "-") instead of list styles
- spacing built from stacks of empty paragraphs

Findings are leads for review, not verdicts. When LibreOffice is
available, the rendered pages remain authoritative.

Usage:
  python3 audit_docx.py document.docx
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    from docx import Document
    from docx.enum.table import WD_ROW_HEIGHT_RULE
except ImportError:
    print("error: python-docx is required (briglia python-env install)", file=sys.stderr)
    raise SystemExit(1)

PLACEHOLDER_RE = re.compile(
    r"lorem ipsum|\bTODO\b|\bTBD\b|\bFIXME\b|XXX|\[[A-Z][A-Z0-9 _-]{2,}\]"
    r"|\[DA VERIFICARE[^\]]*\]",  # unresolved legal-draft markers (atti-legali skill)
    re.IGNORECASE,
)
MANUAL_LIST_RE = re.compile(r"^\s*(?:[-•*‣◦]|\d{1,2}[.)])\s+\S")


def heading_level(paragraph) -> int | None:
    name = paragraph.style.name if paragraph.style is not None else ""
    match = re.fullmatch(r"Heading (\d+)", name)
    return int(match.group(1)) if match else None


def check_stretched_images(doc, findings):
    for index, shape in enumerate(doc.inline_shapes, 1):
        try:
            rId = shape._inline.graphic.graphicData.pic.blipFill.blip.embed
            image = doc.part.related_parts[rId].image
            native_aspect = image.px_width / image.px_height
            display_aspect = shape.width / shape.height
            distortion = display_aspect / native_aspect
        except Exception:
            continue
        if distortion > 1.1 or distortion < 1 / 1.1:
            findings.append({
                "image": index, "filename": getattr(image, "filename", None),
                "detail": f"native aspect {native_aspect:.2f} vs display aspect {display_aspect:.2f} "
                          f"({(max(distortion, 1 / distortion) - 1) * 100:.0f}% distortion)",
            })


def check_fixed_rows(doc, findings):
    for t_index, table in enumerate(doc.tables, 1):
        for r_index, row in enumerate(table.rows, 1):
            if row.height_rule == WD_ROW_HEIGHT_RULE.EXACTLY:
                findings.append({
                    "table": t_index, "row": r_index,
                    "detail": "row height rule is EXACTLY — wrapped text in this row will clip; "
                              "use AT_LEAST or no fixed height",
                })


def check_heading_jumps(doc, findings):
    previous = None
    for paragraph in doc.paragraphs:
        level = heading_level(paragraph)
        if level is None:
            continue
        if previous is not None and level > previous + 1:
            findings.append({
                "heading": paragraph.text[:60],
                "detail": f"jumps from Heading {previous} to Heading {level} — breaks navigation/TOC structure",
            })
        previous = level


def iter_all_paragraph_texts(doc):
    for paragraph in doc.paragraphs:
        yield "body", paragraph.text
    for t_index, table in enumerate(doc.tables, 1):
        for row in table.rows:
            for cell in row.cells:
                yield f"table {t_index}", cell.text
    for s_index, section in enumerate(doc.sections, 1):
        try:
            for paragraph in section.header.paragraphs:
                yield f"header (section {s_index})", paragraph.text
            for paragraph in section.footer.paragraphs:
                yield f"footer (section {s_index})", paragraph.text
        except Exception:
            continue


def check_placeholders(doc, findings):
    seen = set()
    for location, text in iter_all_paragraph_texts(doc):
        if not text:
            continue
        for match in PLACEHOLDER_RE.finditer(text):
            key = (location, match.group(0).lower())
            if key in seen:
                continue
            seen.add(key)
            findings.append({
                "location": location,
                "detail": f"placeholder text {match.group(0)!r} in: {text.strip()[:60]!r}",
            })


def check_table_widths(doc, findings):
    section = doc.sections[0]
    if None in (section.page_width, section.left_margin, section.right_margin):
        return
    printable = section.page_width - section.left_margin - section.right_margin
    for t_index, table in enumerate(doc.tables, 1):
        widths = [column.width for column in table.columns]
        if not widths or any(w is None for w in widths):
            continue
        total = sum(widths)
        if total > printable * 1.02:
            findings.append({
                "table": t_index,
                "detail": f"declared width {total / 914400:.2f}in exceeds printable width "
                          f"{printable / 914400:.2f}in — the table will run off the page",
            })


def check_fake_headings(doc, findings):
    for paragraph in doc.paragraphs:
        if heading_level(paragraph) is not None:
            continue
        style = paragraph.style.name if paragraph.style is not None else ""
        if style not in ("Normal", "Body Text"):
            continue
        text = paragraph.text.strip()
        if not text or len(text) > 60 or text.endswith((".", ":", ";", ",")):
            continue
        runs = [run for run in paragraph.runs if run.text.strip()]
        if runs and all(run.bold for run in runs):
            findings.append({
                "text": text[:60],
                "detail": "short, fully bold, Normal-styled — should probably be a real Heading style",
            })


def check_manual_lists(doc, findings):
    for paragraph in doc.paragraphs:
        style = paragraph.style.name if paragraph.style is not None else ""
        if "List" in style or heading_level(paragraph) is not None:
            continue
        if MANUAL_LIST_RE.match(paragraph.text or ""):
            findings.append({
                "text": paragraph.text.strip()[:60],
                "detail": f"manual list marker in a {style!r} paragraph — use a real list style "
                          "so numbering survives edits",
            })


def check_empty_stacks(doc, findings):
    streak = 0
    last_text = ""
    for paragraph in doc.paragraphs:
        if paragraph.text.strip():
            if streak >= 3:
                findings.append({
                    "after": last_text[:50],
                    "detail": f"{streak} consecutive empty paragraphs used as spacing — "
                              "use paragraph spacing or page breaks instead",
                })
            streak = 0
            last_text = paragraph.text.strip()
        else:
            streak += 1
    if streak >= 3:
        findings.append({
            "after": last_text[:50],
            "detail": f"{streak} consecutive empty paragraphs at the end of the document",
        })


def main() -> int:
    parser = argparse.ArgumentParser(description="Structural audit of a .docx (no renderer needed).")
    parser.add_argument("document", type=Path)
    args = parser.parse_args()

    path = args.document.expanduser().resolve()
    if not path.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 2

    doc = Document(str(path))

    stretched: list = []
    fixed_rows: list = []
    heading_jumps: list = []
    placeholders: list = []
    wide_tables: list = []
    fake_headings: list = []
    manual_lists: list = []
    empty_stacks: list = []

    check_stretched_images(doc, stretched)
    check_fixed_rows(doc, fixed_rows)
    check_heading_jumps(doc, heading_jumps)
    check_placeholders(doc, placeholders)
    check_table_widths(doc, wide_tables)
    check_fake_headings(doc, fake_headings)
    check_manual_lists(doc, manual_lists)
    check_empty_stacks(doc, empty_stacks)

    exact = {
        "stretched_images": stretched,
        "fixed_height_rows": fixed_rows,
        "heading_jumps": heading_jumps,
        "placeholder_text": placeholders[:25],
        "tables_exceeding_page": wide_tables,
    }
    heuristic = {
        "fake_headings": fake_headings[:25],
        "manual_list_markers": manual_lists[:25],
        "empty_paragraph_stacks": empty_stacks[:25],
    }
    report = {
        "document": str(path),
        "exact": exact,
        "heuristic": heuristic,
        "findings_total": sum(len(v) for v in exact.values()) + sum(len(v) for v in heuristic.values()),
        "note": "Fix exact findings; judge heuristic ones against the document's intent. "
                "When LibreOffice is available, rendered pages remain authoritative.",
    }
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
