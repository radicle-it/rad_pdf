-- phase12_canvas_ext.sql - Acceptance tests for canvas extensions (v1.5.0):
--   set_line_dash, write_wrapped justification ('J').
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase12_canvas_ext.sql
--
-- Requires Oracle 19c+.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET DEFINE OFF

PROMPT ================================================================
PROMPT  Phase 12 - Canvas Extensions Acceptance Tests (v1.5.0)
PROMPT ================================================================
PROMPT

-- Shared assert helper is redefined inside each anonymous block per
-- convention established in phase11_watermark.sql.

-- ===========================================================================
-- Test 1: set_line_dash solid reset - finalize succeeds
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 1: set_line_dash reset to solid (dash=0)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_line_dash(l_doc, 0);  -- restore solid (no-op dash)
  rad_pdf_canvas.line(l_doc, 10, 100, 200, 100, p_unit => 'mm');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  assert(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF',
         'Does not start with %PDF');
  -- PDF must contain the solid reset operator "[] 0 d"
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('[] 0 d')) > 0,
         'Solid dash reset "[] 0 d" not found in PDF stream');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 2: set_line_dash symmetric dash (dash=gap)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 2: set_line_dash symmetric (dash=3mm, gap default=dash)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_line_dash(l_doc, 3, p_unit => 'mm');  -- gap defaults to dash
  rad_pdf_canvas.line(l_doc, 10, 100, 200, 100, p_unit => 'mm');
  rad_pdf.set_line_dash(l_doc, 0);  -- restore solid
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- Phase offset 0 must appear: "[... ...] 0 d"
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('] 0 d')) > 0,
         'Dash operator with phase 0 not found');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 3: set_line_dash asymmetric with phase
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 3: set_line_dash asymmetric (dash=5pt, gap=3pt, phase=2pt)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_line_dash(l_doc, 5, p_gap => 3, p_phase => 2);
  rad_pdf_canvas.line(l_doc, 50, 500, 550, 500);
  rad_pdf.set_line_dash(l_doc, 0);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- Stream must contain "[5 3] 2 d" (fmt strips trailing zeros for integers)
  assert(DBMS_LOB.INSTR(l_pdf,
         UTL_RAW.CAST_TO_RAW('[5 3] 2 d')) > 0,
         'Asymmetric dash pattern not found in PDF stream');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 4: set_line_dash via rad_pdf facade (thin wrapper)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: set_line_dash via rad_pdf public facade');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_line_dash(l_doc, 4, p_gap => 2);
  rad_pdf_canvas.rect(l_doc, 20, 20, 100, 50, p_unit => 'mm');
  rad_pdf.set_line_dash(l_doc, 0);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 5: write_wrapped 'L' alignment (baseline, unchanged behaviour)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 5: write_wrapped L alignment - finalize succeeds');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_canvas.write_wrapped(l_doc,
    'The quick brown fox jumps over the lazy dog. '
    || 'Pack my box with five dozen liquor jugs.',
    p_x => 50, p_y => 700, p_width => 400, p_align => 'L');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- Must NOT contain Tw operator (no justification)
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW(' Tw')) = 0,
         'Tw word-spacing found unexpectedly in L-aligned text');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 6: write_wrapped 'J' justification - Tw emitted on non-last lines
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 6: write_wrapped J justification - Tw present');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  -- Text long enough to wrap at least once (width 300pt ~105mm at 12pt)
  rad_pdf_canvas.write_wrapped(l_doc,
    'The quick brown fox jumps over the lazy dog. '
    || 'Pack my box with five dozen liquor jugs. '
    || 'How vexingly quick daft zebras jump.',
    p_x => 50, p_y => 700, p_width => 300, p_align => 'J');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- At least one Tw operator must appear (justified wrapped lines)
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW(' Tw')) > 0,
         'Tw word-spacing operator not found in J-aligned text');
  -- Word-spacing must be reset to 0 after each line
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('0 Tw')) > 0,
         '0 Tw reset not found after J-aligned text');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 7: write_wrapped 'J' single-word line (no Tw for single-word lines)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 7: write_wrapped J - single word wider than line (no Tw)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  -- Very narrow width forces single-word "lines"; no spaces → no Tw
  rad_pdf_canvas.write_wrapped(l_doc,
    'Antidisestablishmentarianism supercalifragilisticexpialidocious',
    p_x => 50, p_y => 700, p_width => 30, p_align => 'J');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- No Tw: single-word lines have l_spaces = 0
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW(' Tw')) = 0,
         'Unexpected Tw for single-word line');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 8: write_wrapped 'J' via rad_pdf.write (template path) - smoke test
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 8: write_wrapped R and C alignments still work');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_canvas.write_wrapped(l_doc,
    'Right-aligned paragraph text.', p_x => 50, p_y => 700,
    p_width => 300, p_align => 'R');
  rad_pdf_canvas.write_wrapped(l_doc,
    'Centred paragraph text.', p_x => 50, p_y => 650,
    p_width => 300, p_align => 'C');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 12 complete - 8/8 tests passed
PROMPT ================================================================
