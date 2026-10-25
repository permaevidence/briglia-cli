#!/usr/bin/env python3
"""Dependency doctor for the bundled document/media skills.

Checks every external tool the pdf, docx, xlsx, pptx, and video-edit
skills (and the transcribe_media tool) rely on, and prints one JSON
report: what is present, what is missing, the exact install command,
and which skills degrade without it.

Run once when working on an unfamiliar machine, then batch the installs.
Ask the user before starting large installs (LibreOffice is ~600 MB).

Python packages are checked in Briglia's private environment (security
plan v24 §7.9.4): the interpreter named by BRIGLIA_PYTHON_ENV (Briglia's
doctor sets it; empty = not set up), else `briglia-python` (BRIGLIA_PYTHON in
Briglia's shell), else this interpreter. A package importable only from the
shared python3 is never reported as present for Briglia.

Usage:
  python3 skills_doctor.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

BINARIES = [
    {
        "name": "ffmpeg",
        "install": "brew install ffmpeg",
        "skills": ["video-edit", "transcribe_media tool"],
        "impact": "required for all video editing; without it transcribe_media only accepts plain audio files",
    },
    {
        "name": "ffprobe",
        "install": "brew install ffmpeg (included)",
        "skills": ["video-edit"],
        "impact": "required for media inspection and QA",
    },
    {
        "name": "pdftoppm",
        "install": "brew install poppler",
        "skills": ["pdf", "docx", "pptx"],
        "impact": "page rasterization for visual QA (PyMuPDF is the fallback)",
    },
    {
        "name": "pdftotext",
        "install": "brew install poppler (included)",
        "skills": ["pdf"],
        "impact": "required for audit_pdf.py text-density and completeness checks",
    },
    {
        "name": "pdfinfo",
        "install": "brew install poppler (included)",
        "skills": ["pdf"],
        "impact": "required for audit_pdf.py page geometry report",
    },
    {
        "name": "pandoc",
        "install": "brew install pandoc",
        "skills": ["docx"],
        "impact": "optional: quick Markdown-to-DOCX drafts",
    },
]

PYTHON_PACKAGES = [
    {
        "module": "openpyxl",
        "install": "briglia python-env install",
        "skills": ["xlsx"],
        "impact": "required for all spreadsheet work",
    },
    {
        "module": "docx",
        "package": "python-docx",
        "install": "briglia python-env install",
        "skills": ["docx"],
        "impact": "required for all Word-document work",
    },
    {
        "module": "pptx",
        "package": "python-pptx",
        "install": "briglia python-env install",
        "skills": ["pptx"],
        "impact": "required for all PowerPoint work",
    },
    {
        "module": "PIL",
        "package": "pillow",
        "install": "briglia python-env install",
        "skills": ["pdf"],
        "impact": "required for the page contact sheet (render_pdf_pages.py --sheet)",
    },
    {
        "module": "formulas",
        "install": "briglia python-env install",
        "skills": ["xlsx"],
        "impact": "optional but recommended: enables true formula evaluation in verify_xlsx.py check",
    },
    {
        "module": "fitz",
        "package": "pymupdf",
        "install": "briglia python-env install",
        "skills": ["pdf", "docx", "pptx"],
        "impact": "optional: page-rasterization fallback when Poppler is absent",
    },
]


def check_binary(name: str) -> bool:
    return shutil.which(name) is not None


def briglia_interpreter() -> str | None:
    """The interpreter whose packages count: Briglia's private environment."""
    if "BRIGLIA_PYTHON_ENV" in os.environ:
        return os.environ["BRIGLIA_PYTHON_ENV"] or None
    return os.environ.get("BRIGLIA_PYTHON") or shutil.which("briglia-python") or sys.executable


ENV_NOT_SET_UP = "Briglia's Python environment is not set up (run `briglia python-env install`)"


def check_module(module: str) -> str:
    """Return ok | missing | broken | unavailable. Probe in a subprocess so
    partially installed packages (e.g. weasyprint without native libs) can't
    crash or pollute this process. Runs from a neutral cwd and rejects bare
    namespace packages — otherwise a stray directory named like the
    module (e.g. a skill folder called 'pptx') counts as installed."""
    interpreter = briglia_interpreter()
    if interpreter is None:
        return "unavailable"
    probe = subprocess.run(
        [
            interpreter, "-c",
            f"import {module}, sys; "
            f"sys.exit(0 if getattr(sys.modules['{module}'], '__file__', None) else 3)",
        ],
        capture_output=True,
        timeout=60,
        cwd="/",
    )
    if probe.returncode == 0:
        return "ok"
    if probe.returncode == 3:
        return "missing"
    stderr = probe.stderr.decode(errors="replace")
    if "Python environment" in stderr and probe.returncode == 1:
        return "unavailable"
    return "missing" if "ModuleNotFoundError" in stderr else "broken"


def find_chrome() -> str | None:
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


def find_libreoffice() -> str | None:
    for name in ("soffice", "libreoffice"):
        path = shutil.which(name)
        if path:
            return path
    mac_path = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
    if Path(mac_path).exists():
        return mac_path
    return None


def main() -> int:
    present: list = []
    missing: list = []

    for spec in BINARIES:
        entry = {
            "name": spec["name"],
            "kind": "binary",
            "install": spec["install"],
            "skills": spec["skills"],
            "impact": spec["impact"],
        }
        (present if check_binary(spec["name"]) else missing).append(entry)

    for spec in PYTHON_PACKAGES:
        status = check_module(spec["module"])
        entry = {
            "name": spec.get("package", spec["module"]),
            "kind": "python",
            "install": spec["install"],
            "skills": spec["skills"],
            "impact": spec["impact"],
        }
        if status == "ok":
            present.append(entry)
        else:
            if status == "unavailable":
                entry["impact"] = ENV_NOT_SET_UP + ". " + entry["impact"]
            if status == "broken":
                advice = "BROKEN INSTALL (imports but fails): reinstall."
                if spec["module"] in ("weasyprint", "fitz"):
                    advice += " On macOS, import failures right after install usually mean " \
                              "missing native libraries (e.g. `brew install pango` for weasyprint) — " \
                              "rebuilding Briglia's environment alone won't fix it."
                entry["impact"] = advice + " " + entry["impact"]
            missing.append(entry)

    # HTML -> PDF engines: one of the two is enough.
    weasy_status = check_module("weasyprint")
    chrome = find_chrome()
    engine_entry = {
        "name": "html-to-pdf engine",
        "kind": "engine",
        "weasyprint": weasy_status,
        "chrome": chrome or "not found",
        "skills": ["pdf"],
    }
    if weasy_status == "ok" or chrome:
        notes = []
        if weasy_status == "broken":
            notes.append(
                "WeasyPrint is installed but fails to import — on macOS this almost always means "
                "missing native libraries: run `brew install pango` (Briglia's environment already "
                "has the Python part). Chrome works meanwhile "
                "but drops CSS @page margin boxes (page numbers/running footers)."
            )
        elif weasy_status != "ok":
            notes.append(
                f"WeasyPrint {weasy_status} — Chrome works but drops CSS @page margin boxes "
                "(page numbers/running footers). For full paged-media support: "
                "briglia python-env install  (on macOS also `brew install pango`)"
            )
        engine_entry["impact"] = " ".join(notes) if notes else "fully covered"
        present.append(engine_entry)
    else:
        engine_entry["install"] = ("briglia python-env install  (on macOS also "
                                   "`brew install pango`; or install Google Chrome)")
        engine_entry["impact"] = "pdf skill cannot render at all without one of these"
        missing.append(engine_entry)

    libre = find_libreoffice()
    libre_entry = {
        "name": "libreoffice",
        "kind": "binary",
        "install": "brew install --cask libreoffice",
        "skills": ["docx", "pptx", "xlsx"],
        "impact": "render-to-PDF visual QA for Office documents; without it docx/pptx ship on structural checks only",
        "warning": "LARGE install (~600 MB) — tell the user before starting it",
    }
    if libre:
        libre_entry["path"] = libre
        present.append(libre_entry)
    else:
        missing.append(libre_entry)

    required_missing = [
        m["name"] for m in missing
        if "required" in str(m.get("impact", "")) or m["kind"] == "engine"
    ]
    print(json.dumps({
        "present": present,
        "missing": missing,
        "summary": {
            "missing_total": len(missing),
            "missing_required": required_missing,
            "advice": "Batch the installs in one command where possible. "
                      "Ask the user before large installs (LibreOffice). "
                      "Optional tools can wait until a task actually needs them.",
        },
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
