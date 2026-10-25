#!/usr/bin/env python3
"""Render PDF pages to PNGs for visual QA.

This helper is intentionally small and dependency-light. It first tries
Poppler's `pdftoppm`; if that is unavailable, it falls back to PyMuPDF when
the `fitz` package is installed.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render PDF pages to PNG files.")
    parser.add_argument("pdf", type=Path, help="Input PDF path")
    parser.add_argument("--out-dir", type=Path, default=Path("pdf_qa"), help="Output directory")
    parser.add_argument("--dpi", type=int, default=180, help="Render DPI")
    parser.add_argument("--first-page", type=int, help="First 1-indexed page to render")
    parser.add_argument("--last-page", type=int, help="Last 1-indexed page to render")
    parser.add_argument("--sheet", nargs="?", const=5, default=None, type=int, metavar="COLS",
                        help="Also tile all rendered pages into ONE labelled contact-sheet image "
                             "(default 5 columns). Inspect the sheet first; read full pages only "
                             "where it shows problems.")
    return parser.parse_args()


def build_contact_sheet(pages: List[Path], out_dir: Path, cols: int) -> dict:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return {"error": "contact sheet needs Pillow (briglia python-env install)"}

    cols = max(1, cols)
    rows = (len(pages) + cols - 1) // cols
    thumb_width = 280
    label_height = 18
    gap = 6

    thumbs = []
    for page in pages:
        with Image.open(page) as img:
            ratio = thumb_width / img.width
            thumb = img.resize((thumb_width, max(1, int(img.height * ratio))))
            thumbs.append(thumb.copy())

    cell_height = max(t.height for t in thumbs) + label_height
    sheet = Image.new(
        "RGB",
        (cols * (thumb_width + gap) + gap, rows * (cell_height + gap) + gap),
        "#666666",
    )
    draw = ImageDraw.Draw(sheet)
    for index, thumb in enumerate(thumbs):
        x = gap + (index % cols) * (thumb_width + gap)
        y = gap + (index // cols) * (cell_height + gap)
        sheet.paste(thumb, (x, y))
        draw.rectangle([x, y + cell_height - label_height, x + thumb_width, y + cell_height], fill="#222222")
        draw.text((x + 6, y + cell_height - label_height + 3), f"p{index + 1}", fill="white")

    out = out_dir / "contact_sheet.png"
    sheet.save(out)
    for thumb in thumbs:
        thumb.close()
    return {"image": str(out), "pages": len(pages), "grid": f"{cols}x{rows}"}


def render_with_pdftoppm(
    pdf: Path,
    out_dir: Path,
    dpi: int,
    first: Optional[int],
    last: Optional[int],
) -> Optional[List[Path]]:
    if shutil.which("pdftoppm") is None:
        return None

    prefix = out_dir / "page"
    cmd = ["pdftoppm", "-png", "-r", str(dpi)]
    if first is not None:
        cmd.extend(["-f", str(first)])
    if last is not None:
        cmd.extend(["-l", str(last)])
    cmd.extend([str(pdf), str(prefix)])

    subprocess.run(cmd, check=True)
    pages = sorted(out_dir.glob("page-*.png"))
    if not pages:
        raise RuntimeError("pdftoppm completed but produced no PNG files")
    return pages


def render_with_pymupdf(
    pdf: Path,
    out_dir: Path,
    dpi: int,
    first: Optional[int],
    last: Optional[int],
) -> Optional[List[Path]]:
    try:
        import fitz  # type: ignore
    except Exception:
        return None

    doc = fitz.open(str(pdf))
    start = 0 if first is None else max(first - 1, 0)
    stop = len(doc) if last is None else min(last, len(doc))
    if start >= stop:
        raise RuntimeError(f"empty page range: first={first}, last={last}, pages={len(doc)}")

    zoom = dpi / 72.0
    matrix = fitz.Matrix(zoom, zoom)
    pages: List[Path] = []
    for index in range(start, stop):
        page = doc.load_page(index)
        pix = page.get_pixmap(matrix=matrix, alpha=False)
        output = out_dir / f"page-{index + 1}.png"
        pix.save(str(output))
        pages.append(output)
    return pages


def main() -> int:
    args = parse_args()
    pdf = args.pdf.expanduser().resolve()
    out_dir = args.out_dir.expanduser().resolve()

    if not pdf.exists():
        print(f"error: PDF not found: {pdf}", file=sys.stderr)
        return 2
    if args.first_page is not None and args.first_page < 1:
        print("error: --first-page must be >= 1", file=sys.stderr)
        return 2
    if args.last_page is not None and args.last_page < 1:
        print("error: --last-page must be >= 1", file=sys.stderr)
        return 2
    if args.first_page and args.last_page and args.first_page > args.last_page:
        print("error: --first-page cannot be greater than --last-page", file=sys.stderr)
        return 2

    out_dir.mkdir(parents=True, exist_ok=True)
    for old_png in out_dir.glob("page-*.png"):
        old_png.unlink()

    try:
        pages = render_with_pdftoppm(pdf, out_dir, args.dpi, args.first_page, args.last_page)
        renderer = "pdftoppm"
        if pages is None:
            pages = render_with_pymupdf(pdf, out_dir, args.dpi, args.first_page, args.last_page)
            renderer = "pymupdf"
        if pages is None:
            print(
                "error: no PDF page renderer available. Install Poppler (`brew install poppler`) "
                "or PyMuPDF (`briglia python-env install`).",
                file=sys.stderr,
            )
            return 1
    except subprocess.CalledProcessError as error:
        print(f"error: renderer command failed with exit code {error.returncode}", file=sys.stderr)
        return error.returncode or 1
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Rendered {len(pages)} page(s) with {renderer}:")
    for page in pages:
        print(page)

    if args.sheet is not None:
        result = build_contact_sheet(pages, out_dir, args.sheet)
        if "error" in result:
            print(f"contact sheet: {result['error']}", file=sys.stderr)
        else:
            print(f"Contact sheet ({result['grid']}, {result['pages']} pages): {result['image']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
