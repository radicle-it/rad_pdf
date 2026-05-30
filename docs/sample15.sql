-- =============================================================================
-- sample15.sql  -  Line dash patterns (v1.5.0)
-- =============================================================================
--
-- WHAT THIS SHOWS
--   How to use rad_pdf.set_line_dash to draw dashed and dotted lines,
--   dashed rectangles, and asymmetric patterns, then reset to solid.
--   Also shows that fill is unaffected by the dash state.
--
-- KEY TECHNIQUES
--   - rad_pdf.set_line_dash(l_doc, p_dash, p_gap, p_phase, p_unit)
--     * p_dash  = 0  -> solid reset ([] 0 d)
--     * p_gap   = NULL -> symmetric (gap = dash)
--     * p_unit  defaults to 'pt'; also accepts 'mm', 'cm', 'in'
--   - set_line_dash affects all subsequent stroked paths on the current page
--   - Always call set_line_dash(l_doc, 0) to restore solid lines when done
--   - Fill operations (filled rects, polygon fill) are unaffected by dash state
--   - Colors and line width are passed per-call to each drawing primitive
--
-- HOW TO RUN
--   Option A - SQL*Plus or SQL Developer:
--     Run as-is; the PDF size is printed to DBMS_OUTPUT.
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
--   RAD_PDF v1.5.0+ installed (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_y   NUMBER;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- Draw directly on the canvas (no layout engine needed for pure-canvas demos).
  -- All coordinates are in points (origin = lower-left of page).
  -- A4 page: 595 x 842 pt. Left margin ~50pt, usable width ~480pt.

  l_y := 760;

  -- =========================================================================
  -- Title
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 14);
  rad_pdf_canvas.write_text(l_doc, 'Line Dash Pattern Showcase', 50, l_y);
  l_y := l_y - 30;

  -- =========================================================================
  -- Solid baseline (no set_line_dash call needed; solid is the default)
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'N', 9);
  rad_pdf_canvas.write_text(l_doc, 'Solid (default)', 50, l_y + 4);
  rad_pdf_canvas.line(l_doc, 160, l_y, 530, l_y,
    p_color => '000000', p_width => 1.5);
  l_y := l_y - 20;

  -- =========================================================================
  -- Symmetric dash (dash = gap = 4mm)
  -- =========================================================================
  rad_pdf_canvas.write_text(l_doc, 'Dash 4mm symmetric', 50, l_y + 4);
  rad_pdf.set_line_dash(l_doc, 4, p_unit => 'mm');
  rad_pdf_canvas.line(l_doc, 160, l_y, 530, l_y,
    p_color => '000000', p_width => 1.5);
  rad_pdf.set_line_dash(l_doc, 0);
  l_y := l_y - 20;

  -- =========================================================================
  -- Short dash / long gap (dash=2pt, gap=6pt)
  -- =========================================================================
  rad_pdf_canvas.write_text(l_doc, 'Dash 2pt, gap 6pt', 50, l_y + 4);
  rad_pdf.set_line_dash(l_doc, 2, p_gap => 6);
  rad_pdf_canvas.line(l_doc, 160, l_y, 530, l_y,
    p_color => '000000', p_width => 1.5);
  rad_pdf.set_line_dash(l_doc, 0);
  l_y := l_y - 20;

  -- =========================================================================
  -- Asymmetric pattern with phase offset (dash=8pt, gap=4pt, phase=4pt)
  -- Phase shifts the starting position into the pattern.
  -- =========================================================================
  rad_pdf_canvas.write_text(l_doc, 'Dash 8pt, gap 4pt, phase 4pt', 50, l_y + 4);
  rad_pdf.set_line_dash(l_doc, 8, p_gap => 4, p_phase => 4);
  rad_pdf_canvas.line(l_doc, 160, l_y, 530, l_y,
    p_color => '000000', p_width => 1.5);
  rad_pdf.set_line_dash(l_doc, 0);
  l_y := l_y - 30;

  -- =========================================================================
  -- Dashed rectangle (stroke only — no fill color passed, so fill is absent)
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Dashed rectangle (stroke only, no fill):', 50, l_y);
  l_y := l_y - 20;

  rad_pdf.set_line_dash(l_doc, 3, p_gap => 3, p_unit => 'mm');
  rad_pdf_canvas.rect(l_doc, 50, l_y - 60, 480, 60,
    p_line_color => '000000',
    p_line_width => 1);
  rad_pdf.set_line_dash(l_doc, 0);

  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'N', 9);
  rad_pdf_canvas.write_text(l_doc, 'Content inside a dashed border', 60, l_y - 25);
  l_y := l_y - 80;

  -- =========================================================================
  -- Filled rectangle: the fill area is unaffected by the dash state.
  -- The border (stroke) follows the dash; the interior fill does not.
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Filled rect with dashed outline:', 50, l_y);
  l_y := l_y - 20;

  rad_pdf.set_line_dash(l_doc, 6, p_gap => 3);
  rad_pdf_canvas.rect(l_doc, 50, l_y - 50, 480, 50,
    p_line_color => '003366',
    p_fill_color => 'D0E8FF',
    p_line_width => 1.5);
  rad_pdf.set_line_dash(l_doc, 0);

  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'N', 9);
  rad_pdf_canvas.write_text(l_doc,
    'Fill is solid; only the stroke (border) follows the dash pattern',
    60, l_y - 22);
  l_y := l_y - 70;

  -- =========================================================================
  -- Thick dotted line (very short dash = visual dot)
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Dotted line (dash=1pt, gap=5pt, width=3pt):', 50, l_y);
  l_y := l_y - 20;

  rad_pdf.set_line_dash(l_doc, 1, p_gap => 5);
  rad_pdf_canvas.line(l_doc, 50, l_y, 530, l_y,
    p_color => '000000', p_width => 3);
  rad_pdf.set_line_dash(l_doc, 0);
  l_y := l_y - 30;

  -- =========================================================================
  -- Alternating solid / dashed segments on the same horizontal level
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Alternating solid / dashed segments:', 50, l_y);
  l_y := l_y - 20;

  -- Solid segment
  rad_pdf_canvas.line(l_doc, 50, l_y, 150, l_y,
    p_color => '003366', p_width => 1.5);

  -- Dashed segment
  rad_pdf.set_line_dash(l_doc, 4, p_gap => 4);
  rad_pdf_canvas.line(l_doc, 150, l_y, 300, l_y,
    p_color => '003366', p_width => 1.5);
  rad_pdf.set_line_dash(l_doc, 0);

  -- Solid segment
  rad_pdf_canvas.line(l_doc, 300, l_y, 380, l_y,
    p_color => '003366', p_width => 1.5);

  -- Longer-dash segment
  rad_pdf.set_line_dash(l_doc, 8, p_gap => 3);
  rad_pdf_canvas.line(l_doc, 380, l_y, 530, l_y,
    p_color => '003366', p_width => 1.5);
  rad_pdf.set_line_dash(l_doc, 0);

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B: save to file
  -- rad_pdf.save(l_doc, 'PDF_OUT', 'line_dash.pdf');

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
