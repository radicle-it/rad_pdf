CREATE OR REPLACE PACKAGE rad_pdf_pager AUTHID DEFINER AS
-- =============================================================================
-- RAD_PDF_PAGER: the single paginator of the Word evolution (doc 96 §11.9 B2+B3; middleware-docs 96a §1b, §7.1, §9).
-- It consumes an INSTANCE (rad_pdf_merge.merge: a sealed RI, data in runs) and draws it with the low-level engine
-- (rad_pdf_canvas, rad_pdf_fonts, rad_pdf_images) only: no flowables, no rad_pdf_layout, no rad_pdf_table, no page
-- procedure in a string (E6). No package state: the document, its fonts and its plan are local to one call.
--
--   text     words and spaces measured with the font's own advances; tab stops left, right and decimal (the
--            decimal character an option), default stops every default_tab points; justify; line break nodes
--   lines    Word's single line = (ascender - descender + line gap) / unitsPerEm of the font (hhea), times the
--            multiple; the extra of a multiple goes BELOW the text (the baseline at line top + ascender)
--   blocks   between two paragraphs the LARGER of space_after and space_before (measured on Word's export of the
--            quote); at the top of a page after an automatic break that gap is dropped; keep_next chains; a chain
--            taller than the page is [PDF_LAYOUT]
--   tables   the grid in points, cell margins, shading, borders (cell over table), the row height = the top border +
--            the tallest cell (as Word: 0.5 pt per row); header rows repeated on every page; a row is never split
--            (v1), a row taller than the page is [PDF_LAYOUT]
--   zones    header and footer per page (first page different when title_page), measured per page: a header taller
--            than the top margin pushes the body down, a footer taller than the bottom margin pushes it up
--   fields   PAGE and NUMPAGES: the body is paginated with a guess of the page count and paginated again when the
--            count has more digits than the guess (the double pass)
--   fonts    D3: the font a run asks for, else its fixed substitute (Arial -> Liberation Sans ...), loaded from the
--            files given, embedded as a subset (CID); fsType forbidding embedding or subsetting refused
-- =============================================================================

  c_err_layout CONSTANT PLS_INTEGER := -20844;          -- [PDF_LAYOUT]
  c_err_font   CONSTANT PLS_INTEGER := -20845;          -- [PDF_FONT]
  c_err_budget CONSTANT PLS_INTEGER := -20842;          -- [PDF_BUDGET] (the code of rad_pdf_merge too)
  c_max_pages  CONSTANT PLS_INTEGER := 500;             -- 96a §8

  -- a font file: a family in one variant R (regular) B (bold) I (italic) X (bold italic)
  TYPE t_font_file IS RECORD (family VARCHAR2(100), variant CHAR(1), bytes BLOB);
  TYPE t_font_files IS TABLE OF t_font_file;

  TYPE t_options IS RECORD (
    decimal_char VARCHAR2(1) := ',',                     -- the character a decimal tab aligns on (Word: the locale)
    default_tab  NUMBER      := 36,                      -- Word's default tab stops (720 twips)
    title        VARCHAR2(200));

  -- D3 (96a §9): the free substitute of a font a template asks for, or the name itself
  FUNCTION substitute(p_family IN VARCHAR2) RETURN VARCHAR2;

  -- the PDF of an instance; the caller frees the BLOB
  FUNCTION render(p_inst IN rad_pdf_ri.t_ri, p_fonts IN t_font_files, p_options IN t_options DEFAULT NULL) RETURN BLOB;

  -- the layout as text, for the tests (like rad_pdf_ri.to_json): 'PAGES n', then per page its operations in order,
  -- '<page> T <x> <y> <text> [<size> #<colour>]' (y from the top of the page: the baseline), L lines, F fills, I images
  FUNCTION layout_dump(p_inst IN rad_pdf_ri.t_ri, p_fonts IN t_font_files, p_options IN t_options DEFAULT NULL) RETURN CLOB;

END rad_pdf_pager;
/
