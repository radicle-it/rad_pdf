# The first gate of the Word evolution (middleware-docs 96a §10)

| File | What |
|---|---|
| `sal_quote_v1.docx` | the quote template, conforming to 96a §6-§7: one section, first-page header different, footer `Pagina {PAGE} di {NUMPAGES}` (Word fields), Heading 1, right and decimal tab stops, justified paragraphs, a lines table with a repeated header row (`tblHeader`, `cantSplit`) and one row repeated by `{#lines}…{/lines}` (open in the first cell, close in the last), cell shading and borders, `{#has_discount}…{/has_discount}`, keep-with-next on the totals |
| `sal_quote_v1.json` | data conforming to the quote schema v1 (96a §5.3): 40 lines, values already formatted |
| `sal_quote_v1_neg_*.json` | negative cases: `lines` not an array, a required object missing (`totals`), `has_discount` of the wrong type |
| `sal_quote_v1_merged.docx` | the same document with the data substituted by `make_quote_sample.py` (plain substitution, only to let Word render it) |
| `sal_quote_v1_schema.json` | the print schema `SAL_QUOTE` v1 of 96a §5.3 (nullable by the rule of §5.1), for the merge (`rad_pdf_merge.schema_from_json`) |
| `sal_quote_v1_ri.json` | step B1: the RI of the template built by hand (`tests/word/quote_ri.sql`), canonical dump; since B4 the reader (`rad_pdf_docx`) must give the same text from `sal_quote_v1.docx` |
| `sal_quote_v1_ri.pdf` | step B1: that RI merged with the data by `rad_pdf_merge` (since B2) and rendered through the existing engine by a test-only bridge (fixed clock: same bytes at every run); 3 pages like Word |
| `sal_quote_v1_pager.pdf` | the same instance drawn by the paginator `rad_pdf_pager` (B3) with Liberation Sans 2.1.5 (`tests/word/load_fonts.py`): the reference of `quote_ri.py` (same bytes), within the fidelity thresholds of 96a §10 against Word |
| `sal_quote_v1_word.pdf` | **Word's own export** of the merged document: the fidelity reference |

Fixed for the reference: Microsoft Word for Mac **16.111.2**, *Save as → PDF* with default options, font **Arial**
(regular, bold, italic: embedded subsets in the PDF), A4, margins 2/2/2.5/2 cm; **3 pages**. Our engine renders Arial
with its metric twin **Liberation Sans** (D3), so the comparison measures the substitution as well.

Regenerate: `python3 tests/word/make_quote_sample.py`, then export `sal_quote_v1_merged.docx` from Word as PDF.
