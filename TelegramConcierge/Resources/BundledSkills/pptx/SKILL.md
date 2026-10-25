---
name: pptx
description: Create and edit editable PowerPoint .pptx decks with native slides, template-aware structure, visual proof objects, and rendered QA. Use for slide decks, presentations, pitch decks, board decks, and Google Slides/Keynote-ready editable slides.
---

# PPTX Skill

Use this skill when the user needs editable slides. A good PPTX is made of native slide objects: layouts, placeholders, text boxes, shapes, tables, charts, images, speaker notes, and theme-aware styling where possible.

This skill is not a single deck style. Follow the user's template, reference, audience, and content. Use presentation craft to make the deck clear, not to force every deck into the same consulting format.

**Dependencies**: python-pptx (required); LibreOffice plus Poppler or PyMuPDF for render-to-PDF visual QA. On an unfamiliar machine, run `python3 ${CLAUDE_SKILL_DIR}/skills_doctor.py` once — it reports every dependency of the document/media skills with install commands. Ask the user before starting large installs (LibreOffice is ~600 MB). Python packages live in Briglia's private environment: run these helpers — and any script of yours that imports python-docx, python-pptx, openpyxl, pillow, formulas, PyMuPDF or WeasyPrint — with `briglia-python` instead of `python3`; if it says the environment is not set up, run `briglia python-env install`. Never `pip install` into the system Python.

`${CLAUDE_SKILL_DIR}/reference.md` holds the detail: planning checklist, slide craft defaults, geometry rules, template handling, full QA checklist, and the symptom→fix table. Read it before building a deck of any substance.

## Reliable Workflow

1. Decide the mode: create, targeted edit, template-follow, or content-to-deck.
2. Separate source facts from visual/style references.
3. Author with `python-pptx`. When the user supplied a template or source deck, inspect it first: `briglia-python ${CLAUDE_SKILL_DIR}/inspect_pptx.py template.pptx --layouts` lists layouts and placeholders; without the flag it summarizes slides, titles, and shapes. Reuse the template's layouts and styles instead of rebuilding the look. Pandoc is only for quick outline drafts.
4. Plan the slide sequence and what each slide needs to prove or communicate. Not every deck needs aggressive "claim/proof" titles, but every important slide needs a reason to exist — a slide that is only a topic label plus generic bullets should be improved, merged, or made an intentional agenda/divider.
5. Build editable native slides. Do not invent metrics, logos, customer marks, product UI, citations, or financial data.
6. Audit structurally: `briglia-python ${CLAUDE_SKILL_DIR}/audit_pptx.py output.pptx` — exact geometry checks (shapes off the slide, stretched images) plus conservative heuristics (likely text overflow, tiny fonts, empty placeholders, overlapping text). Fix everything exact; judge the heuristics. This needs no renderer, so it is the primary QA when LibreOffice is unavailable.
7. Render and look when LibreOffice is available: `briglia-python ${CLAUDE_SKILL_DIR}/render_doc_pages.py output.pptx --out-dir deck_qa --sheet` rasterizes every slide AND tiles them into one labelled contact-sheet image. Judge sequence and thumbnail rhythm on the sheet; read full-size slides where the sheet or audit flagged problems. Rendered output stays authoritative — a clean audit does not guarantee a clean render.
8. Fix objective defects and repeat up to 3 times.

Do not overwrite source decks. Save a new output file unless the user explicitly asks otherwise.

## Hard Rules

- One main idea per slide is the default; split or move detail to appendix rather than overcrowding.
- Text boxes need enough internal margin and height — text overflow is the most common defect.
- Preserve template conventions (theme fonts, colors, logo placement, footers, page numbers) and do not restyle unrelated slides during targeted edits.
- Preserve image aspect ratios; crop deliberately instead of stretching.
- Charts need honest scales, units, source notes, and legible labels.

## When To Redirect

Final non-editable handout → PDF. Text-heavy reports → DOCX or PDF. Data-heavy workbooks → XLSX. Complex animation/video → the video skill or a real editor.

## Stopping Criterion

Ship when the PPTX opens without repair prompts, uses editable native slides, preserves any requested template, renders cleanly, has the expected slide count, and contains no clipped text, distorted images, broken charts, accidental blank slides, or unresolved placeholders.
