#!/usr/bin/env python3
"""Render HTML to PDF with whatever engine is actually installed.

Resolution order: WeasyPrint (CLI or Python module) -> Chromium ->
Google Chrome -> Microsoft Edge. Prints a JSON result naming the engine
used and any capability warnings, or exits with install guidance when no
engine exists.

Engine differences that matter:
- WeasyPrint implements CSS paged media: @page margin boxes, counter(page),
  running headers/footers. Best for documents.
- Chrome/Chromium headless ignores @page margin boxes — CSS page numbers
  and running footers silently disappear. Best for designs that depend on
  browser layout (complex flex/grid, canvas, web fonts via JS).

Usage:
  python3 render_pdf.py input.html output.pdf
  python3 render_pdf.py input.html output.pdf --engine chrome
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple

CHROME_WARNING = (
    "Rendered with Chrome/Chromium: CSS @page margin boxes are NOT supported — "
    "counter(page) page numbers and running headers/footers were dropped if the CSS used them. "
    "Install WeasyPrint (briglia python-env install) for full paged-media support."
)


def find_weasyprint() -> Optional[List[str]]:
    cli = shutil.which("weasyprint")
    if cli:
        return [cli]
    # Probe the module in a subprocess: a broken install (missing pango/gobject
    # native libs) prints noise and raises on import.
    probe = subprocess.run(
        [sys.executable, "-c", "import weasyprint"],
        capture_output=True,
        timeout=30,
    )
    if probe.returncode == 0:
        return [sys.executable, "-m", "weasyprint"]
    return None


def find_chrome() -> Optional[str]:
    for name in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable"):
        path = shutil.which(name)
        if path:
            return path
    for app in (
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    ):
        if Path(app).exists():
            return app
    return None


def render_weasyprint(cmd: List[str], html: Path, pdf: Path, timeout: int) -> Tuple[bool, str]:
    result = subprocess.run(cmd + [str(html), str(pdf)], capture_output=True, text=True, timeout=timeout)
    return result.returncode == 0 and pdf.exists(), result.stderr.strip()


def render_chrome(binary: str, html: Path, pdf: Path, timeout: int) -> Tuple[bool, str]:
    cmd = [
        binary,
        "--headless",
        "--disable-gpu",
        "--no-sandbox",
        "--no-pdf-header-footer",
        "--virtual-time-budget=10000",
        f"--print-to-pdf={pdf}",
        html.resolve().as_uri(),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return result.returncode == 0 and pdf.exists(), result.stderr.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Render HTML to PDF with the best available engine.")
    parser.add_argument("html", type=Path, help="Input HTML file")
    parser.add_argument("pdf", type=Path, help="Output PDF path")
    parser.add_argument("--engine", choices=["auto", "weasyprint", "chrome"], default="auto",
                        help="Force an engine (default: auto-resolve)")
    parser.add_argument("--timeout", type=int, default=120, help="Render timeout in seconds")
    args = parser.parse_args()

    html = args.html.expanduser().resolve()
    pdf = args.pdf.expanduser().resolve()
    if not html.exists():
        print(f"error: HTML file not found: {html}", file=sys.stderr)
        return 2
    pdf.parent.mkdir(parents=True, exist_ok=True)

    weasy = find_weasyprint() if args.engine in ("auto", "weasyprint") else None
    chrome = find_chrome() if args.engine in ("auto", "chrome") else None

    attempts: List[dict] = []

    if weasy:
        try:
            ok, stderr = render_weasyprint(weasy, html, pdf, args.timeout)
        except subprocess.TimeoutExpired:
            ok, stderr = False, f"timed out after {args.timeout}s"
        if ok:
            print(json.dumps({
                "pdf": str(pdf),
                "engine": "weasyprint",
                "warnings": [w for w in [stderr[:500] if stderr else None] if w],
            }, indent=2))
            return 0
        attempts.append({"engine": "weasyprint", "error": stderr[:500]})

    if chrome:
        try:
            ok, stderr = render_chrome(chrome, html, pdf, args.timeout)
        except subprocess.TimeoutExpired:
            ok, stderr = False, f"timed out after {args.timeout}s"
        if ok:
            print(json.dumps({
                "pdf": str(pdf),
                "engine": f"chrome ({chrome})",
                "warnings": [CHROME_WARNING],
            }, indent=2))
            return 0
        attempts.append({"engine": f"chrome ({chrome})", "error": stderr[:500]})

    if attempts:
        print(json.dumps({"error": "all available engines failed", "attempts": attempts}, indent=2), file=sys.stderr)
        return 1

    print(json.dumps({
        "error": "no HTML-to-PDF engine found",
        "fix": "Install one: 'briglia python-env install' (preferred for documents) "
               "or install Google Chrome / Chromium (fine for browser-layout designs).",
    }, indent=2), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
