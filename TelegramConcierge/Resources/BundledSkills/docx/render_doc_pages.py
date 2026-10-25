#!/usr/bin/env python3
"""Render an office document (docx/pptx/xlsx) to page PNGs for visual QA.

Converts the document to PDF with headless LibreOffice, then rasterizes the
pages using Poppler's `pdftoppm` or PyMuPDF, whichever is available.

Usage:
  python3 render_doc_pages.py output.docx --out-dir doc_qa
  python3 render_doc_pages.py deck.pptx --out-dir deck_qa --dpi 120
  python3 render_doc_pages.py deck.pptx --out-dir deck_qa --sheet
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import List, Optional


def find_soffice() -> Optional[str]:
    for name in ("soffice", "libreoffice"):
        path = shutil.which(name)
        if path:
            return path
    mac_path = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
    if Path(mac_path).exists():
        return mac_path
    return None


def convert_to_pdf(soffice: str, doc: Path, tmp_dir: Path) -> Path:
    subprocess.run(
        [soffice, "--headless", "--convert-to", "pdf", "--outdir", str(tmp_dir), str(doc)],
        check=True,
        capture_output=True,
    )
    pdf = tmp_dir / (doc.stem + ".pdf")
    if not pdf.exists():
        raise RuntimeError("LibreOffice completed but produced no PDF")
    return pdf


def render_with_pdftoppm(pdf: Path, out_dir: Path, dpi: int) -> Optional[List[Path]]:
    if shutil.which("pdftoppm") is None:
        return None
    prefix = out_dir / "page"
    subprocess.run(["pdftoppm", "-png", "-r", str(dpi), str(pdf), str(prefix)], check=True)
    pages = sorted(out_dir.glob("page-*.png"))
    if not pages:
        raise RuntimeError("pdftoppm completed but produced no PNG files")
    return pages


def render_with_pymupdf(pdf: Path, out_dir: Path, dpi: int) -> Optional[List[Path]]:
    try:
        import fitz  # type: ignore
    except Exception:
        return None
    doc = fitz.open(str(pdf))
    zoom = dpi / 72.0
    matrix = fitz.Matrix(zoom, zoom)
    pages: List[Path] = []
    for index in range(len(doc)):
        pix = doc.load_page(index).get_pixmap(matrix=matrix, alpha=False)
        output = out_dir / f"page-{index + 1}.png"
        pix.save(str(output))
        pages.append(output)
    return pages


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


def main() -> int:
    parser = argparse.ArgumentParser(description="Render an office document to page PNGs.")
    parser.add_argument("document", type=Path, help="Input document (docx/pptx/xlsx)")
    parser.add_argument("--out-dir", type=Path, default=Path("doc_qa"), help="Output directory")
    parser.add_argument("--dpi", type=int, default=150, help="Render DPI")
    parser.add_argument("--keep-pdf", action="store_true", help="Also copy the intermediate PDF to the output directory")
    parser.add_argument("--sheet", nargs="?", const=5, default=None, type=int, metavar="COLS",
                        help="Also tile all pages into ONE labelled contact-sheet image (default 5 columns)")
    args = parser.parse_args()

    doc = args.document.expanduser().resolve()
    out_dir = args.out_dir.expanduser().resolve()
    if not doc.exists():
        print(f"error: document not found: {doc}", file=sys.stderr)
        return 2

    soffice = find_soffice()
    if soffice is None:
        print("error: LibreOffice not found. Install it (`brew install --cask libreoffice`).", file=sys.stderr)
        return 1

    out_dir.mkdir(parents=True, exist_ok=True)
    for old_png in out_dir.glob("page-*.png"):
        old_png.unlink()

    try:
        with tempfile.TemporaryDirectory() as tmp:
            pdf = convert_to_pdf(soffice, doc, Path(tmp))
            if args.keep_pdf:
                kept = out_dir / pdf.name
                shutil.copyfile(pdf, kept)
                print(f"PDF: {kept}")
            pages = render_with_pdftoppm(pdf, out_dir, args.dpi)
            renderer = "pdftoppm"
            if pages is None:
                pages = render_with_pymupdf(pdf, out_dir, args.dpi)
                renderer = "pymupdf"
            if pages is None:
                print(
                    "error: no PDF page renderer available. Install Poppler (`brew install poppler`) "
                    "or PyMuPDF (`briglia python-env install`).",
                    file=sys.stderr,
                )
                return 1
    except subprocess.CalledProcessError as error:
        stderr = (error.stderr or b"").decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
        print(f"error: command failed with exit code {error.returncode}: {stderr.strip()}", file=sys.stderr)
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
