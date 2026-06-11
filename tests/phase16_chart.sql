-- phase16_chart.sql - Acceptance tests for rad_pdf_chart (v1.7.0).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase16_chart.sql

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET DEFINE OFF

PROMPT ================================================================
PROMPT  Phase 16 - Chart Acceptance Tests (v1.7.0)
PROMPT ================================================================
PROMPT

-- ===========================================================================
-- Test 1: all three chart types render into a valid PDF (facade shortcuts)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_v   rad_pdf_types.t_number_list;
  l_l   rad_pdf_types.t_text_list;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 1: bar + line + pie via facade');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_v(1) := 120; l_v(2) := 340; l_v(3) := 90;
  l_l(1) := 'A'; l_l(2) := 'B'; l_l(3) := 'C';
  rad_pdf.bar_chart (l_doc, l_v, 60, 560, 220, 150, p_labels => l_l,
                     p_title => 'Bars');
  rad_pdf.line_chart(l_doc, l_v, 320, 560, 220, 150, p_labels => l_l);
  rad_pdf.pie_chart (l_doc, l_v, 160, 380, 70, p_labels => l_l,
                     p_title => 'Pie');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 3000, 'BLOB too small');
  assert(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF',
         'not a PDF');
  -- pie slices use Bézier curves: 'c' operator must appear in the stream
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW(' c' || CHR(10))) > 0,
         'no Bézier curve operators found');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 2: line chart with negative values (zero axis inside the plot)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_v   rad_pdf_types.t_number_list;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 2: line chart with negative values');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_v(1) := 15; l_v(2) := -8; l_v(3) := 22; l_v(4) := -3;
  rad_pdf.line_chart(l_doc, l_v, 60, 500, 300, 200);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 1000, 'BLOB too small');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 3: validation errors (empty, sparse, negative bar, zero pie total,
--          box too small)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_v   rad_pdf_types.t_number_list;
  l_ok  PLS_INTEGER := 0;

  PROCEDURE expect_err(p_what VARCHAR2) IS
  BEGIN
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: no error for ' || p_what);
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 3: validation errors');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  BEGIN  -- empty values
    rad_pdf.bar_chart(l_doc, l_v, 60, 500, 200, 150);
    expect_err('empty values');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_validation THEN l_ok := l_ok + 1;
    ELSE RAISE; END IF;
  END;

  BEGIN  -- sparse values
    l_v(1) := 10; l_v(3) := 20;
    rad_pdf.bar_chart(l_doc, l_v, 60, 500, 200, 150);
    expect_err('sparse values');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_validation THEN l_ok := l_ok + 1;
    ELSE RAISE; END IF;
  END;

  BEGIN  -- negative bar value
    l_v.DELETE; l_v(1) := 10; l_v(2) := -5;
    rad_pdf.bar_chart(l_doc, l_v, 60, 500, 200, 150);
    expect_err('negative bar value');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_validation THEN l_ok := l_ok + 1;
    ELSE RAISE; END IF;
  END;

  BEGIN  -- pie total zero
    l_v.DELETE; l_v(1) := 0; l_v(2) := 0;
    rad_pdf.pie_chart(l_doc, l_v, 200, 400, 60);
    expect_err('zero pie total');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_validation THEN l_ok := l_ok + 1;
    ELSE RAISE; END IF;
  END;

  BEGIN  -- box too small
    l_v.DELETE; l_v(1) := 10;
    rad_pdf.bar_chart(l_doc, l_v, 60, 500, 40, 20);
    expect_err('box too small');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_validation THEN l_ok := l_ok + 1;
    ELSE RAISE; END IF;
  END;

  IF l_ok = 5 THEN
    DBMS_OUTPUT.PUT_LINE('  PASS  (5 validation errors raised as expected)');
  ELSE
    RAISE_APPLICATION_ERROR(-20999, 'only ' || l_ok || '/5 validations fired');
  END IF;
  rad_pdf.close_document(l_doc);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 4: custom colours, colour cycling, mm units, font state restored
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_v    rad_pdf_types.t_number_list;
  l_c    rad_pdf_types.t_rgb_list;
  l_size NUMBER;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: custom colours, mm units, font restore');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_canvas.set_font(l_doc, 'Times', 'B', 14);
  FOR i IN 1 .. 6 LOOP l_v(i) := i * 10; END LOOP;
  l_c(1) := '003366'; l_c(2) := 'CC0000';   -- 2 colours over 6 bars: cycle
  rad_pdf.bar_chart(l_doc, l_v, 20, 150, 120, 70,
                    p_colors => l_c, p_unit => 'mm');
  l_size := rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_font_size);
  assert(l_size = 14, 'font size not restored: ' || l_size);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 1000, 'BLOB too small');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 5: charts + table + QR + bookmark coexist in one document
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_v   rad_pdf_types.t_number_list;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 5: charts coexist with QR + bookmark');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_v(1) := 30; l_v(2) := 70;
  rad_pdf.pie_chart(l_doc, l_v, 150, 650, 60);
  rad_pdf.qrcode(l_doc, 'https://radicle.it', 400, 600, 100);
  rad_pdf.add_bookmark(l_doc, 'Dashboard', 1, p_y => 750);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 2000, 'BLOB too small');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Outlines')) > 0,
         'bookmark missing');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 16 complete - all chart tests passed.
PROMPT ================================================================
