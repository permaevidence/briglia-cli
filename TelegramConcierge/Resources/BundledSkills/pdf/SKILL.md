---
name: pdf
description: Create polished PDF documents with HTML/CSS source, renderer-aware layout, and visual QA by rendering pages to images. Use for fixed-layout reports, essays, invoices, letters, printable handouts, slide-style PDFs, and other final PDFs.
---

# PDF Skill

PDF quality comes from judgment plus inspection. Use this skill to make final fixed-layout documents that survive printing, sharing, and close reading.

This skill is deliberately not a design template. Do not force every PDF into the same visual style. Choose the structure, density, typography, and amount of visual treatment that fits the user's intent, source material, audience, and any supplied reference.

**Dependencies**: an HTML-to-PDF engine (WeasyPrint preferred, else Chrome/Chromium — the render helper resolves this) plus Poppler or PyMuPDF for page rasterization; Pillow for the contact sheet. On an unfamiliar machine, run `python3 ${CLAUDE_SKILL_DIR}/skills_doctor.py` once — it reports every dependency of the document/media skills with install commands. Ask the user before starting large installs (LibreOffice is ~600 MB). Python packages live in Briglia's private environment: run these helpers — and any script of yours that imports python-docx, python-pptx, openpyxl, pillow, formulas, PyMuPDF or WeasyPrint — with `briglia-python` instead of `python3`; if it says the environment is not set up, run `briglia python-env install`. Never `pip install` into the system Python.

`${CLAUDE_SKILL_DIR}/reference.md` holds the detail: document-type guidance (essay/report/transactional/letter/slide/flyer), typography and layout defaults, a starter CSS foundation for both flowing and slide-style pages, the full QA checklist, and the symptom→fix table. Read it before designing, and again when fixing layout defects.

## Non-Negotiable Workflow

1. Identify the document type and audience (classify before designing — see reference.md).
2. Choose a source format. Default to HTML/CSS for new PDFs.
3. Build the document with reusable CSS and intentional page geometry.
4. Render: `briglia-python ${CLAUDE_SKILL_DIR}/render_pdf.py input.html output.pdf`.
5. Audit programmatically: `briglia-python ${CLAUDE_SKILL_DIR}/audit_pdf.py output.pdf --source input.html`.
6. Inspect visually: `briglia-python ${CLAUDE_SKILL_DIR}/render_pdf_pages.py output.pdf --out-dir pdf_qa --sheet`.
7. Fix objective defects and re-render. Repeat up to 3 times.

The file existing is not enough. Text extraction is not enough. A PDF is ready only when the rendered pages look correct.

## Render

`render_pdf.py` resolves whichever engine is installed — WeasyPrint, else Chromium/Chrome/Edge headless — and reports which one it used. Heed its warnings: Chrome does not support CSS @page margin boxes, so `counter(page)` page numbers and running headers/footers silently vanish; if the document needs page furniture and only Chrome is available, either put the furniture in the body flow or suggest setting up Briglia's Python environment (`briglia python-env install`; on macOS WeasyPrint also needs `brew install pango`). Prefer WeasyPrint for documents; prefer Chrome (`--engine chrome`) when the design depends on browser layout behavior such as complex flex/grid or canvas.

Avoid imperative PDF libraries such as reportlab/fpdf for flowing documents — fine for precise generated forms or labels, harder than HTML/CSS for everything else.

Keep scratch files in a task-specific folder such as `tmp/pdfs/<task-slug>/`. Unless the user asks for internals, deliver the final PDF.

## Audit Before Looking

`audit_pdf.py` catches objective failures cheaply, before any image is read:

- Page count, page size, per-page text density, and near-empty-page flags (accidental blanks show up numerically; covers and dividers are legitimately sparse).
- With `--source input.html`: a text-completeness check — chunks of source text that never made it into the PDF mean content was silently clipped (the classic `overflow: hidden` failure on fixed-size slide pages, invisible in a dense thumbnail). Clusters of consecutive missing chunks are almost always real clipping; isolated ones may be hyphenation artifacts — verify those visually.

## Design Judgment

Before writing the source, make a short internal plan:

- Document type and audience.
- Page size and likely page count.
- Reading density: sparse, normal, dense, or appendix-like.
- Typography: body size, heading ladder, line height, and font fallbacks.
- Main content forms: prose, table, figure, chart, callout, form field, image, appendix.
- Risk areas: long tables, footnotes, narrow columns, images, page breaks, legal text, totals, source notes.

Use the simplest layout that expresses the content well. Prefer clear hierarchy over decoration. If the user provides a reference, template, brand guide, or explicit preference, follow that unless it causes objective quality problems.

Do not invent facts, citations, logos, signatures, legal terms, tax IDs, payment information, customer names, partner marks, product screenshots, or data. If placeholders are needed, make them obvious.

## Visual QA

Start with the contact sheet (`render_pdf_pages.py output.pdf --sheet`): one labelled image of every page, enough to judge page rhythm, accidental blanks, density balance, and thumbnail legibility for slide-style PDFs. Then read full-size page images only where the sheet or the audit flagged problems — plus, for long documents, every distinct layout type, first/last pages, and any page with tables, figures, footnotes, or dense content.

Check for: clipped/overlapping text, accidental blank pages, stranded headings, separated captions, overflowing tables, distorted images, inconsistent page furniture, and leftover placeholders. The full checklist and the common-fixes table are in reference.md.

Fix objective defects first. Do not spend iterations on subjective polish while there are still layout errors.

## Stopping Criterion

Ship when the rendered pages match the user's intent and have no objective layout defects. The design does not need to follow a house style; it needs to be clear, complete, visually stable, and appropriate for the document type.
