-- phase14_bookmark.sql - Acceptance tests for bookmarks / outline (v1.6.0).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase14_bookmark.sql

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET DEFINE OFF

PROMPT ================================================================
PROMPT  Phase 14 - Bookmarks / Outline Acceptance Tests (v1.6.0)
PROMPT ================================================================
PROMPT

-- ===========================================================================
-- Test 1: heading p_bookmark - outline tree in the PDF, /PageMode set
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
  DBMS_OUTPUT.PUT_LINE('Test 1: bookmarked headings produce /Outlines');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.heading(l_doc, 'Chapter 1', 1, p_bookmark => TRUE);
  rad_pdf.write  (l_doc, 'Body.');
  rad_pdf.heading(l_doc, 'Section 1.1', 2, p_bookmark => TRUE);
  rad_pdf.new_page(l_doc);
  rad_pdf.heading(l_doc, 'Chapter 2', 1, p_bookmark => TRUE);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Type /Outlines')) > 0,
         '/Outlines missing');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/PageMode /UseOutlines')) > 0,
         '/PageMode missing');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Title (Chapter 1)')) > 0,
         'Chapter 1 title missing');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Count 3')) > 0,
         'root /Count 3 missing');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 2: no bookmarks - catalog has NO /Outlines (behaviour unchanged)
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
  DBMS_OUTPUT.PUT_LINE('Test 2: no bookmarks - no /Outlines in catalog');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.heading(l_doc, 'Plain heading', 1);   -- p_bookmark defaults FALSE
  rad_pdf.write(l_doc, 'Body.');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Outlines')) = 0,
         'unexpected /Outlines');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Type /Catalog')) > 0,
         'catalog missing');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 3: canvas mode - add_bookmark with explicit y and mm units
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
  DBMS_OUTPUT.PUT_LINE('Test 3: canvas mode, explicit y in mm');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_canvas.write_text(l_doc, 'Canvas content', 20, 250, 'mm');
  rad_pdf.add_bookmark(l_doc, 'Canvas anchor', 1, p_y => 250, p_unit => 'mm');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Title (Canvas anchor)')) > 0,
         'bookmark missing');
  -- 250 mm = 708.66 pt
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/XYZ null 708.66 null')) > 0,
         'dest y not converted from mm');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 4: NULL title raises c_err_validation
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: NULL title raises error');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf.add_bookmark(l_doc, NULL);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: NULL title accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_validation THEN
      DBMS_OUTPUT.PUT_LINE('  PASS  (' || SQLCODE || ' raised as expected)');
    ELSE
      RAISE;
    END IF;
  END;
  rad_pdf.close_document(l_doc);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 5: level clamping (0 -> 1, 99 -> 6) - no error, flat-ish tree
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
  DBMS_OUTPUT.PUT_LINE('Test 5: out-of-range levels are clamped');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_canvas.write_text(l_doc, 'x', 72, 700, 'pt');
  rad_pdf.add_bookmark(l_doc, 'Clamped low',  0);    -- -> 1
  rad_pdf.add_bookmark(l_doc, 'Clamped high', 99);   -- -> 6, nests under prev
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Title (Clamped low)')) > 0,
         'low bookmark missing');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Title (Clamped high)')) > 0,
         'high bookmark missing');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 6: non-ASCII title written as UTF-16BE hex string (<FEFF...>)
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
  DBMS_OUTPUT.PUT_LINE('Test 6: UTF-16BE outline title for non-ASCII');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_canvas.write_text(l_doc, 'x', 72, 700, 'pt');
  rad_pdf.add_bookmark(l_doc, UNISTR('Citt\00E0'));   -- "Città"
  l_pdf := rad_pdf.finalize(l_doc);
  -- C i t t à in UTF-16BE: 0043 0069 0074 0074 00E0
  assert(DBMS_LOB.INSTR(l_pdf,
         UTL_RAW.CAST_TO_RAW('<FEFF004300690074007400E0>')) > 0,
         'UTF-16BE title not found');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 7: two documents - independent bookmark state
-- ===========================================================================
DECLARE
  l_doc1 rad_pdf_types.t_doc_handle;
  l_doc2 rad_pdf_types.t_doc_handle;
  l_pdf1 BLOB;
  l_pdf2 BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 7: independent bookmark state across documents');
  rad_pdf_styles.load_defaults;
  l_doc1 := rad_pdf.new_document;
  l_doc2 := rad_pdf.new_document;
  rad_pdf_canvas.write_text(l_doc1, 'doc1', 72, 700, 'pt');
  rad_pdf_canvas.write_text(l_doc2, 'doc2', 72, 700, 'pt');
  rad_pdf.add_bookmark(l_doc1, 'Doc1 only');
  l_pdf1 := rad_pdf.finalize(l_doc1);
  l_pdf2 := rad_pdf.finalize(l_doc2);
  assert(DBMS_LOB.INSTR(l_pdf1, UTL_RAW.CAST_TO_RAW('/Outlines')) > 0,
         'doc1 outline missing');
  assert(DBMS_LOB.INSTR(l_pdf2, UTL_RAW.CAST_TO_RAW('/Outlines')) = 0,
         'doc2 has unexpected outline');
  DBMS_LOB.FREETEMPORARY(l_pdf1);
  DBMS_LOB.FREETEMPORARY(l_pdf2);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc1); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN rad_pdf.close_document(l_doc2); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 8: bookmarks + watermark + QR code coexist
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
  DBMS_OUTPUT.PUT_LINE('Test 8: bookmarks + watermark + QR coexistence');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_watermark(l_doc, 'DEMO');
  rad_pdf.heading(l_doc, 'Report', 1, p_bookmark => TRUE);
  rad_pdf.write(l_doc, 'Body.');
  rad_pdf.qrcode(l_doc, 'https://radicle.it', 400, 100, 100);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Type /Outlines')) > 0,
         'outline missing');
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 2000, 'BLOB too small');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 14 complete - all bookmark tests passed.
PROMPT ================================================================
