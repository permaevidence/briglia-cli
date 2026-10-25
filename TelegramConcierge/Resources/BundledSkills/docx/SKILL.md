---
name: docx
description: Create and edit Microsoft Word .docx documents with real Word structure, template-aware styling, tables/forms/comments, and rendered QA. Use for editable reports, memos, proposals, letters, contracts, forms, CVs, and Google Docs-ready documents.
---

# DOCX Skill

Use this skill when the user needs an editable Word document, not a fixed-layout PDF. A good DOCX is built from real Word structures: styles, paragraphs, lists, tables, sections, headers, footers, images, and comments. It should survive editing in Word or Google Docs.

This skill is not a house style. Preserve supplied templates and choose formatting that fits the document's purpose.

**Dependencies**: python-docx (required); LibreOffice plus Poppler or PyMuPDF for render-to-PDF visual QA; Pandoc optional for Markdown drafts. On an unfamiliar machine, run `python3 ${CLAUDE_SKILL_DIR}/skills_doctor.py` once — it reports every dependency of the document/media skills with install commands. Ask the user before starting large installs (LibreOffice is ~600 MB). Python packages live in Briglia's private environment: run these helpers — and any script of yours that imports python-docx, python-pptx, openpyxl, pillow, formulas, PyMuPDF or WeasyPrint — with `briglia-python` instead of `python3`; if it says the environment is not set up, run `briglia python-env install`. Never `pip install` into the system Python.

`${CLAUDE_SKILL_DIR}/reference.md` holds the detail: task modes, planning checklist, tables/forms craft, full QA checklist, and the symptom→fix table. Read it when building anything non-trivial or debugging a defect.

## Reliable Workflow

1. Decide the task mode: create, targeted edit, template-follow, redline/comment, or Google Docs-ready (see reference.md).
2. Separate source content from reference/style material.
3. Choose the authoring path: `python-docx` for precise work, Pandoc for straightforward prose drafts (`pandoc input.md --reference-doc=template.docx -o output.docx`), or template editing when the user supplied a DOCX. Avoid GUI automation; LibreOffice is for conversion/QA, not authoring.
4. Build real Word structure, not visual fakes.
5. Inspect the package: `briglia-python ${CLAUDE_SKILL_DIR}/inspect_docx.py output.docx` (headings, tables, sections, styles in use). Use it on input documents too, before editing them.
6. Audit structurally: `briglia-python ${CLAUDE_SKILL_DIR}/audit_docx.py output.docx` — exact checks (stretched images, table rows that clip, heading-level jumps, placeholder leftovers, tables wider than the page) plus conservative heuristics (fake bold headings, manual list markers, spacing via empty paragraphs). Fix everything exact; judge the heuristics. This needs no renderer, so it is the primary QA when LibreOffice is unavailable.
7. Render and look when LibreOffice is available: `briglia-python ${CLAUDE_SKILL_DIR}/render_doc_pages.py output.docx --out-dir doc_qa --sheet` converts via LibreOffice, rasterizes every page, and tiles them into one labelled contact-sheet image. Check page rhythm and accidental blanks on the sheet; read full pages where it shows problems. Rendered output stays authoritative — a clean audit does not guarantee a clean render.
8. Fix objective defects and repeat up to 3 times.

Do not overwrite the user's original file. Create a new output file unless explicitly asked otherwise.

## Structure Rules

- Use real Heading styles for headings. Faked bold-body headings break the navigation pane and TOC generation.
- Use real list/numbering behavior. Do not type manual numbers or repeated spaces for alignment.
- Use tables for repeated comparable records, forms, schedules, budgets, and matrices — not for ordinary prose.
- Set page size, orientation, margins, header/footer distance, and section breaks intentionally.
- Preserve image aspect ratios. Do not stretch logos, signatures, screenshots, or diagrams.
- Do not invent legal clauses, signatures, citations, metrics, logos, tax IDs, or organizational claims.

## Editing Existing Documents

- Preserve the original; save a new file.
- Inspect styles, headings, tables, sections, headers, and footers first (use the inspect script).
- Make the smallest change that satisfies the request. Do not restyle unrelated sections.
- Preserve existing styles, numbering, headers, footers, and table geometry.
- For comments/reviews, attach feedback near the relevant passage, not only in a final summary. If true tracked changes are not available, use comments, visible markers, or a companion change summary.

## When To Redirect

Pixel-perfect final layout → PDF. Slide-native storytelling → PPTX. Interactive formulas and grids → XLSX. "Editable PDF" needs clarification: DOCX, PDF form, or annotated PDF. Legal/contracts need provided or user-approved language.

## Stopping Criterion

Ship when the DOCX opens cleanly, uses real Word structure, preserves any requested template, renders cleanly page by page, and has no clipped content, broken tables, accidental restyling, or unresolved placeholders.
