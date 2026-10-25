---
name: xlsx
description: Create and edit Microsoft Excel .xlsx workbooks with reliable data types, formulas, formatting, tables, multiple sheets, and programmatic verification. Use for spreadsheets, budgets, reports, invoices, CSV conversions, trackers, and structured data.
---

# XLSX Skill

Use this skill when the user needs a real spreadsheet. Spreadsheet quality starts with data integrity: correct sheets, headers, rows, data types, formulas, ranges, and formats. Visual polish matters after the workbook is structurally correct.

Do not fake spreadsheet verification with screenshots alone. Open the workbook programmatically and inspect cells, dimensions, formulas, and types.

**Dependencies**: openpyxl (required); the `formulas` package for true formula evaluation in `check` (recommended); LibreOffice optional for visual rendering. On an unfamiliar machine, run `python3 ${CLAUDE_SKILL_DIR}/skills_doctor.py` once — it reports every dependency of the document/media skills with install commands. Ask the user before starting large installs (LibreOffice is ~600 MB). Python packages live in Briglia's private environment: run these helpers — and any script of yours that imports python-docx, python-pptx, openpyxl, pillow, formulas, PyMuPDF or WeasyPrint — with `briglia-python` instead of `python3`; if it says the environment is not set up, run `briglia python-env install`. Never `pip install` into the system Python.

`${CLAUDE_SKILL_DIR}/reference.md` holds the detail: schema planning checklist, common formulas, CSV import rules, full verification checklists, and the symptom→fix table. Read it when planning a non-trivial workbook or debugging a defect.

## Reliable Workflow

1. Decide the mode: create new workbook, edit existing workbook, template-follow, or CSV/data conversion.
2. For existing workbooks, inspect and preserve before editing. Never rebuild unless asked.
3. Define the workbook schema: sheets, columns, row counts, formulas, formats, validation, charts/tables.
4. Write typed values, formulas, widths, formats, freeze panes, filters, and sheets with `openpyxl`.
5. Reopen the saved file and verify structure programmatically (helper below).
6. Run `verify_xlsx.py check` — formula lint plus, when the `formulas` package is installed, full evaluation of every formula. Fix every error; judge every warning.
7. If visual layout matters, convert to PDF (`libreoffice --headless --convert-to pdf output.xlsx`) and inspect.
8. Fix objective defects and repeat up to 3 times.

Do not overwrite the user's original workbook unless explicitly asked.

## Verification Helper

```bash
briglia-python ${CLAUDE_SKILL_DIR}/verify_xlsx.py manifest book.xlsx              # sheets, dims, tables, charts, named ranges, hidden sheets
briglia-python ${CLAUDE_SKILL_DIR}/verify_xlsx.py inspect book.xlsx --rows 3      # headers + sample rows with types and number formats
briglia-python ${CLAUDE_SKILL_DIR}/verify_xlsx.py diff before.xlsx after.xlsx     # cell-by-cell diff of an edit
briglia-python ${CLAUDE_SKILL_DIR}/verify_xlsx.py check book.xlsx                 # formula lint + evaluation + data-integrity lint
```

For existing-workbook edits: run `manifest` before and after — any sheet, table, chart, image, named-range, or hidden-sheet change must be intentional. Run `diff` to confirm edits touched only the intended cells.

`check` is the formula safety net — run it on every workbook that contains formulas:

- Errors (always fix): references to nonexistent sheets, `#REF!` in formula text, formulas stored as text that will never calculate.
- Warnings (judge): aggregation ranges that stop short of adjacent data (`SUM(B2:B9)` while B10 holds data — the classic bug from writing formulas before appending rows), references to empty areas.
- Evaluation (when the `formulas` package is installed): every formula is actually computed — `error_cells` lists `#REF!`/`#DIV/0!`/`#N/A`/`#NAME?` results and must be empty; sanity-check the computed totals against what the data implies. An `#N/A` from a lookup means the key genuinely is not in the lookup table.
- Data lint: numbers/dates stored as text, header whitespace, blank rows inside data, merged cells in data regions. Leading-zero IDs are correctly text and not flagged.

## Existing Workbook Edits — Hard Rules

This mode overrides creation guidance. These mistakes silently destroy user data:

- Do not start from `Workbook()` — load the existing file (copy it to the output path first, then `load_workbook`).
- Do not export an existing workbook through pandas `to_excel()`; it drops formulas, formatting, charts, images, tables, filters, hidden sheets, named ranges, and workbook properties. pandas is for new workbooks, new sheets, or raw data imports only.
- Do not recreate sheets that already exist unless the user asks for a rebuild.
- Save to a new output path unless the user explicitly asks to overwrite.
- Edit only the requested cells/ranges/sheets; preserve everything else — formulas, formatting, widths, filters, freeze panes, hidden rows/columns/sheets, charts, images, comments, validation, merged cells, named ranges, protection.

## Data Integrity Rules

- Write numbers as numbers, dates as `datetime.date`/`datetime.datetime` — never strings — then set number formats. (`openpyxl` stores what you give it; numbers-as-text break SUM, dates-as-text sort alphabetically.)
- Write formulas as strings beginning with `=`. `openpyxl` writes formulas but does not calculate them — verify formula text and ranges, or recalculate headlessly: `libreoffice --headless --convert-to xlsx --outdir recalculated output.xlsx`.
- Use absolute references (`$A$1`) where copied formulas should not shift.
- Store IDs with leading zeros (ZIP codes, phone numbers, SKUs, account numbers) as text.
- One header row, no leading/trailing whitespace in headers, no merged cells or blank rows inside data tables (they break sorting/filtering).
- Keep raw data separate from summaries in analytical workbooks. Freeze panes and add filters for tables users will scan.
- Set column widths explicitly — openpyxl has no auto-fit.
- Use explicit number formats for currency, percentages, dates, and decimals.

## When To Redirect

Narrative reports → DOCX or PDF. Fixed printable invoices/statements → PDF unless formulas/editing matter. Heavy interactive dashboards → a BI tool or app.

## Stopping Criterion

Ship when the workbook opens cleanly, has the expected sheets and schema, stores values with correct data types, contains correct formulas/ranges, preserves requested template behavior, and passes programmatic verification. If print layout or visual polish matters, also verify the rendered output.
