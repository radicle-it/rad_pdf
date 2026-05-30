-- =============================================================================
-- sample16.sql  -  Justified text with write_wrapped 'J' (v1.5.0)
-- =============================================================================
--
-- WHAT THIS SHOWS
--   How to produce fully-justified paragraphs using rad_pdf_canvas.write_wrapped
--   with p_align => 'J'. Justified text distributes extra horizontal space across
--   all inter-word gaps on non-final lines so both edges align to the column
--   boundaries. The final line of each paragraph is always left-aligned.
--   The demo compares all four alignment modes side-by-side.
--
-- KEY TECHNIQUES
--   - rad_pdf_canvas.write_wrapped(p_doc, p_text, p_x, p_y, p_width,
--                                  p_align, p_unit, p_leading)
--     p_align: 'L' left (default)  'C' centre  'R' right  'J' justified
--   - 'J' uses the PDF Tw (word-spacing) operator; last line is left-aligned
--   - p_width controls the text block width; p_x/p_y set the top-left origin
--   - write_wrapped is a canvas primitive; use it for absolute-positioned text,
--     not for layout-engine (rad_pdf.write) mode
--   - To get justified paragraphs through the layout engine, define a custom
--     style with align_h = 'J' (see apex_sample12.sql)
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
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_y     NUMBER;
  l_x     CONSTANT NUMBER := 50;
  l_w     CONSTANT NUMBER := 495;   -- content width in pt (A4 minus margins)

  -- Sample text long enough to fill several lines at 11pt / 495pt wide.
  c_lorem CONSTANT VARCHAR2(4000) :=
    'The quick brown fox jumps over the lazy dog. '
    || 'Pack my box with five dozen liquor jugs. '
    || 'How vexingly quick daft zebras jump! '
    || 'The five boxing wizards jump quickly. '
    || 'Sphinx of black quartz, judge my vow. '
    || 'Two driven jocks help fax my big quiz.';

  c_lorem2 CONSTANT VARCHAR2(4000) :=
    'Oracle PL/SQL is a powerful block-structured language designed for '
    || 'the Oracle Database. It combines SQL with procedural features such as '
    || 'conditions and loops. It can handle exceptions, define and call stored '
    || 'procedures, and interact with the database efficiently from within '
    || 'application code or server-side logic.';

BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  l_y := 780;

  -- =========================================================================
  -- Page title
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 14);
  rad_pdf_canvas.write_text(l_doc, 'Text Alignment Comparison', l_x, l_y);
  l_y := l_y - 6;

  -- Underline rule (pass p_color directly; no persistent state setter needed)
  rad_pdf_canvas.h_line(l_doc, l_x, l_y, l_w,
    p_line_width => 1.5, p_color => '003366');
  l_y := l_y - 20;

  -- =========================================================================
  -- LEFT alignment ('L' - default)
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Left-aligned (p_align => ''L'')', l_x, l_y);
  l_y := l_y - 14;

  rad_pdf_canvas.set_font(l_doc, 'Times', 'N', 11);
  rad_pdf_canvas.write_wrapped(l_doc, c_lorem,
    p_x => l_x, p_y => l_y, p_width => l_w, p_align => 'L');
  l_y := l_y - 70;

  -- =========================================================================
  -- JUSTIFIED alignment ('J')
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Justified (p_align => ''J'') - last line stays left', l_x, l_y);
  l_y := l_y - 14;

  rad_pdf_canvas.set_font(l_doc, 'Times', 'N', 11);
  rad_pdf_canvas.write_wrapped(l_doc, c_lorem,
    p_x => l_x, p_y => l_y, p_width => l_w, p_align => 'J');
  l_y := l_y - 70;

  -- =========================================================================
  -- RIGHT alignment ('R')
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Right-aligned (p_align => ''R'')', l_x, l_y);
  l_y := l_y - 14;

  rad_pdf_canvas.set_font(l_doc, 'Times', 'N', 11);
  rad_pdf_canvas.write_wrapped(l_doc, c_lorem,
    p_x => l_x, p_y => l_y, p_width => l_w, p_align => 'R');
  l_y := l_y - 70;

  -- =========================================================================
  -- CENTRE alignment ('C')
  -- =========================================================================
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Centred (p_align => ''C'')', l_x, l_y);
  l_y := l_y - 14;

  rad_pdf_canvas.set_font(l_doc, 'Times', 'N', 11);
  rad_pdf_canvas.write_wrapped(l_doc, c_lorem,
    p_x => l_x, p_y => l_y, p_width => l_w, p_align => 'C');

  -- =========================================================================
  -- Page 2: longer justified passage, narrow column
  -- =========================================================================
  rad_pdf.new_page(l_doc);
  l_y := 780;

  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'B', 14);
  rad_pdf_canvas.write_text(l_doc, 'Multi-paragraph Justified Text', l_x, l_y);
  l_y := l_y - 6;
  rad_pdf_canvas.h_line(l_doc, l_x, l_y, l_w,
    p_line_width => 1.5, p_color => '003366');
  l_y := l_y - 22;

  -- Full-width justified paragraph
  rad_pdf_canvas.set_font(l_doc, 'Times', 'N', 12);
  rad_pdf_canvas.write_wrapped(l_doc, c_lorem2,
    p_x => l_x, p_y => l_y, p_width => l_w, p_align => 'J');
  l_y := l_y - 90;

  -- Narrow-column justified paragraph (240pt) to emphasise justification
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'I', 9);
  rad_pdf_canvas.write_text(l_doc, 'Same text in a narrow 240pt column:', l_x, l_y);
  l_y := l_y - 14;

  rad_pdf_canvas.set_font(l_doc, 'Times', 'N', 11);
  rad_pdf_canvas.write_wrapped(l_doc, c_lorem2,
    p_x => l_x, p_y => l_y, p_width => 240, p_align => 'J');
  l_y := l_y - 190;

  -- Reminder note
  rad_pdf_canvas.set_font(l_doc, 'Helvetica', 'I', 9);
  rad_pdf_canvas.write_text(l_doc,
    'Note: p_align=''J'' is a canvas (write_wrapped) parameter only.',
    l_x, l_y);
  l_y := l_y - 14;
  rad_pdf_canvas.write_text(l_doc,
    'For layout-engine paragraphs (rad_pdf.write), define a style with align_h=''J''.',
    l_x, l_y);

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B: save to file
  -- rad_pdf.save(l_doc, 'PDF_OUT', 'justified_text.pdf');

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
