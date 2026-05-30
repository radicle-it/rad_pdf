-- =============================================================================
-- sample13.sql  -  Text watermark: "DRAFT" diagonal, semi-transparent
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A grey diagonal "DRAFT" watermark drawn BEHIND the page content using
--   rad_pdf.set_watermark. The watermark appears on every page, is centred on
--   the page, and is rendered at 30% opacity so the table content is easy to
--   read through it.
--
-- KEY TECHNIQUES
--   - rad_pdf.set_watermark: register a text watermark before finalize
--   - p_angle => 45: counter-clockwise rotation in degrees
--   - p_opacity => 0.3: 0 = invisible, 1 = fully opaque
--   - p_layer => 'UNDER': watermark drawn before page content (default)
--   - p_color => 'C0C0C0': light grey (6-char uppercase hex RGB)
--   - p_font_size in points only (no unit conversion)
--   - Calling set_watermark twice replaces the first registration
--   - rad_pdf.clear_watermark removes the watermark if it should not appear
--
-- DATA
--   Uses the classic Oracle EMP table (Scott schema).
--   Replace with your own query if EMP is not available.
--
-- HOW TO RUN
--   Option A - SQL*Plus or SQL Developer:
--     Run as-is; the PDF size is printed to DBMS_OUTPUT to confirm success.
--
--   Option B - Save to file via Oracle Directory:
--     Uncomment the rad_pdf.save() call and set your directory name.
--     CREATE OR REPLACE DIRECTORY PDF_OUT AS '/tmp/rad_pdf';
--     GRANT WRITE ON DIRECTORY PDF_OUT TO your_schema;
--
--   Option C - SQL Developer bind variable:
--     Uncomment the ":rad_pdf := l_pdf" line, then right-click the result
--     and choose Save As.
--
-- PREREQUISITES
--   RAD_PDF v1.4.0+ installed (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  l_clr  rad_pdf_types.t_color_scheme;
  i      PLS_INTEGER;
BEGIN
  rad_pdf_styles.load_defaults;

  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Watermark: "DRAFT" in light grey, 45 degrees, 30% opacity, behind content
  -- =========================================================================
  rad_pdf.set_watermark(
    p_doc       => l_doc,
    p_text      => 'DRAFT',
    p_font_name => 'Helvetica',
    p_font_size => 72,         -- large enough to span the page diagonally
    p_color     => 'C0C0C0',   -- light grey
    p_opacity   => 0.3,
    p_angle     => 45,
    p_layer     => 'UNDER');

  -- =========================================================================
  -- Column definitions (EMP report)
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(5);

  FOR i IN 1..5 LOOP
    l_cols(i).data_fmt.margin_top    := 4;
    l_cols(i).data_fmt.margin_bot    := 4;
    l_cols(i).data_fmt.margin_left   := 6;
    l_cols(i).data_fmt.margin_rgt    := 6;
    l_cols(i).header_fmt.margin_top  := 4;
    l_cols(i).header_fmt.margin_bot  := 4;
    l_cols(i).header_fmt.margin_left := 6;
    l_cols(i).header_fmt.margin_rgt  := 6;
    l_cols(i).header_fmt.font_style  := 'B';
  END LOOP;

  l_cols(1).label              := 'No';
  l_cols(1).width              := 45;
  l_cols(1).header_fmt.align_h := 'C';
  l_cols(1).data_fmt.align_h   := 'C';

  l_cols(2).label := 'Name';
  l_cols(2).width := 90;

  l_cols(3).label := 'Job';
  l_cols(3).width := 90;

  l_cols(4).label              := 'Hired';
  l_cols(4).width              := 80;
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.align_h   := 'C';

  l_cols(5).label                  := 'Salary';
  l_cols(5).width                  := 72;
  l_cols(5).header_fmt.align_h     := 'R';
  l_cols(5).data_fmt.align_h       := 'R';
  l_cols(5).data_fmt.num_format    := '999,990.00';

  -- =========================================================================
  -- Color scheme: navy header, light alternating rows
  -- =========================================================================
  l_clr.header_paper  := '1A3A5C';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '1A3A5C';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.even_border   := 'CCCCCC';
  l_clr.odd_paper     := 'EEF2F8';
  l_clr.odd_border    := 'CCCCCC';

  -- =========================================================================
  -- Document content
  -- =========================================================================
  rad_pdf.heading(l_doc, 'Employee Roster', 1);
  rad_pdf.write  (l_doc,
    'This report is in DRAFT state. The watermark is drawn behind the '    ||
    'table content at 30% opacity using rad_pdf.set_watermark. It appears ' ||
    'on every page without any per-page callback.');
  rad_pdf.spacer (l_doc, 10);

  rad_pdf.query2table(l_doc,
    'SELECT empno, ename, job, ' ||
    '       TO_CHAR(hiredate, ''DD-Mon-YYYY''), sal ' ||
    '  FROM emp ORDER BY ename',
    l_cols,
    p_colors => l_clr);

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B: save to file
  -- rad_pdf.save(l_doc, 'PDF_OUT', 'draft_watermark.pdf');

  -- Option C: SQL Developer bind variable
  -- :rad_pdf := l_pdf;

  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
