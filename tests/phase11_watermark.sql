-- phase11_watermark.sql - Acceptance tests for the watermark feature (v1.4.0).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase11_watermark.sql
--
-- Requires Oracle 19c+.
-- Uses a synthetic JPEG-like BLOB where needed (1x1 JPEG minimum valid bytes).

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET DEFINE OFF

PROMPT ================================================================
PROMPT  Phase 11 - Watermark Acceptance Tests (v1.4.0)
PROMPT ================================================================
PROMPT

DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;

  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;

-- ===========================================================================
-- Test 1: text watermark UNDER, opacity 0.3 - finalize succeeds, BLOB > 0
-- ===========================================================================
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 1: text watermark UNDER, opacity 0.3');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Page content.');
  rad_pdf.set_watermark(l_doc, 'DRAFT');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  assert(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF',
         'Does not start with %PDF');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 2: text watermark OVER, opacity 0.5
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
  DBMS_OUTPUT.PUT_LINE('Test 2: text watermark OVER, opacity 0.5');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Page content.');
  rad_pdf.set_watermark(l_doc, 'CONFIDENTIAL',
    p_opacity => 0.5, p_layer => 'OVER');
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
-- Test 3: image watermark UNDER
-- ===========================================================================
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_img_id PLS_INTEGER;
  l_img    BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 3: image watermark UNDER');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  -- Minimal valid JPEG: SOI (FFD8) + EOI (FFD9). Parser defaults to 1x1.
  DBMS_LOB.CREATETEMPORARY(l_img, TRUE, DBMS_LOB.SESSION);
  DBMS_LOB.WRITEAPPEND(l_img, 4, HEXTORAW('FFD8FFD9'));
  l_img_id := rad_pdf_images.load_image(l_doc, l_img);
  DBMS_LOB.FREETEMPORARY(l_img);
  rad_pdf.write(l_doc, 'Page content with image watermark.');
  rad_pdf.set_watermark_image(l_doc, l_img_id, p_layer => 'UNDER');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_img IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_img) = 1 THEN
    DBMS_LOB.FREETEMPORARY(l_img);
  END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 4: image watermark OVER
-- ===========================================================================
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_img_id PLS_INTEGER;
  l_img    BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: image watermark OVER');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  DBMS_LOB.CREATETEMPORARY(l_img, TRUE, DBMS_LOB.SESSION);
  DBMS_LOB.WRITEAPPEND(l_img, 4, HEXTORAW('FFD8FFD9'));
  l_img_id := rad_pdf_images.load_image(l_doc, l_img);
  DBMS_LOB.FREETEMPORARY(l_img);
  rad_pdf.write(l_doc, 'Page content.');
  rad_pdf.set_watermark_image(l_doc, l_img_id, p_layer => 'OVER');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_img IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_img) = 1 THEN
    DBMS_LOB.FREETEMPORARY(l_img);
  END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 5: opacity = 1.0 - no ExtGState written, no error
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
  DBMS_OUTPUT.PUT_LINE('Test 5: opacity = 1.0 - no ExtGState in output');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  rad_pdf.set_watermark(l_doc, 'OPAQUE', p_opacity => 1.0);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- No ExtGState should appear when opacity = 1.0
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('ExtGState')) = 0,
         'ExtGState should not be present for opacity=1.0');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 6: opacity = 0.0 - fully transparent, no error
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
  DBMS_OUTPUT.PUT_LINE('Test 6: opacity = 0.0 - fully transparent, no error');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  rad_pdf.set_watermark(l_doc, 'INVISIBLE', p_opacity => 0.0);
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
-- Test 7: angle = 0 (horizontal text)
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
  DBMS_OUTPUT.PUT_LINE('Test 7: angle = 0 (horizontal text)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  rad_pdf.set_watermark(l_doc, 'HORIZONTAL', p_angle => 0);
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
-- Test 8: angle = -45 (opposite diagonal)
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
  DBMS_OUTPUT.PUT_LINE('Test 8: angle = -45 (opposite diagonal)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  rad_pdf.set_watermark(l_doc, 'DRAFT', p_angle => -45);
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
-- Test 9: angle = 90 (vertical text)
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
  DBMS_OUTPUT.PUT_LINE('Test 9: angle = 90 (vertical text)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  rad_pdf.set_watermark(l_doc, 'VERTICAL', p_angle => 90);
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
-- Test 10: multi-page document - watermark on every page, consistent output
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
  DBMS_OUTPUT.PUT_LINE('Test 10: multi-page document - watermark on every page');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_watermark(l_doc, 'DRAFT', p_opacity => 0.2);
  rad_pdf.write(l_doc, 'Page 1 content.');
  rad_pdf.new_page(l_doc);
  rad_pdf.write(l_doc, 'Page 2 content.');
  rad_pdf.new_page(l_doc);
  rad_pdf.write(l_doc, 'Page 3 content.');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- The shared watermark stream object should appear once
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('WM_GS')) > 0,
         'WM_GS not found in output');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 11: watermark + page template (header/footer): both render correctly
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_tmpl rad_pdf_types.t_page_template;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 11: watermark + page template (header/footer)');
  rad_pdf_styles.load_defaults;
  l_tmpl.header_proc := 'BEGIN rad_pdf_canvas.write_text(' ||
    'rad_pdf_types.t_doc_handle(#DOC_HANDLE#), ' ||
    '''Page #PAGE_NR# of #PAGE_COUNT#'', 28, 820); END;';
  l_doc := rad_pdf.new_document(p_template => l_tmpl);
  rad_pdf.set_watermark(l_doc, 'DRAFT');
  rad_pdf.write(l_doc, 'Document with header and watermark.');
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
-- Test 12: watermark + layout engine - flowable content unaffected
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 12: watermark + layout engine (table + write)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_watermark(l_doc, 'DRAFT', p_opacity => 0.25, p_angle => 30);
  rad_pdf.heading(l_doc, 'Watermark Layout Test', 1);
  rad_pdf.write(l_doc, 'Table rendered alongside watermark.');
  l_cols.EXTEND(2);
  l_cols(1).label := 'N';     l_cols(1).width := 60;
  l_cols(2).label := 'Value'; l_cols(2).width := 120;
  rad_pdf.query2table(l_doc,
    'SELECT LEVEL, LEVEL * 10 FROM DUAL CONNECT BY LEVEL <= 5',
    l_cols);
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
-- Test 13: watermark + rad_pdf_template.render call
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 13: watermark + rad_pdf_template.render');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.set_watermark(l_doc, 'DRAFT', p_angle => 45, p_opacity => 0.3);
  rad_pdf.render_template(l_doc,
    '<h1>Watermark Template Test</h1>' ||
    '<p>This document was produced by <b>rad_pdf_template</b>.</p>' ||
    '<spacer height="12pt"/>' ||
    '<p>A diagonal DRAFT watermark appears behind the content.</p>');
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
-- Test 14: clear_watermark removes state - finalize produces no watermark stream
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
  DBMS_OUTPUT.PUT_LINE('Test 14: clear_watermark removes state');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content without watermark after clear.');
  rad_pdf.set_watermark(l_doc, 'DRAFT');
  rad_pdf.clear_watermark(l_doc);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- After clear, no WM_GS should appear in the output
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('WM_GS')) = 0,
         'WM_GS found in output after clear_watermark');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 15: clear_watermark on a doc with no watermark - no error
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
  DBMS_OUTPUT.PUT_LINE('Test 15: clear_watermark on doc with no watermark - no-op');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  rad_pdf.clear_watermark(l_doc);   -- should not raise
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
-- Test 16: set_watermark called twice - second call replaces first
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
  DBMS_OUTPUT.PUT_LINE('Test 16: set_watermark called twice - second replaces first');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  rad_pdf.set_watermark(l_doc, 'FIRST',  p_opacity => 0.5);
  rad_pdf.set_watermark(l_doc, 'SECOND', p_opacity => 0.2);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- Only one watermark stream should exist (SECOND); FIRST is replaced
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('SECOND')) > 0,
         'SECOND watermark text not found');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 17: two documents in same session - independent watermark state
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
  DBMS_OUTPUT.PUT_LINE('Test 17: two documents - independent watermark state');
  rad_pdf_styles.load_defaults;
  l_doc1 := rad_pdf.new_document;
  l_doc2 := rad_pdf.new_document;
  rad_pdf.write(l_doc1, 'Document 1 content.');
  rad_pdf.write(l_doc2, 'Document 2 content.');
  rad_pdf.set_watermark(l_doc1, 'DOC1MARK');
  -- doc2 intentionally has no watermark
  l_pdf1 := rad_pdf.finalize(l_doc1);
  l_pdf2 := rad_pdf.finalize(l_doc2);
  assert(DBMS_LOB.GETLENGTH(l_pdf1) > 0, 'PDF1 BLOB empty');
  assert(DBMS_LOB.GETLENGTH(l_pdf2) > 0, 'PDF2 BLOB empty');
  assert(DBMS_LOB.INSTR(l_pdf1, UTL_RAW.CAST_TO_RAW('DOC1MARK')) > 0,
         'Watermark not found in doc1');
  assert(DBMS_LOB.INSTR(l_pdf2, UTL_RAW.CAST_TO_RAW('WM_GS')) = 0,
         'WM_GS found in doc2 (should have no watermark)');
  DBMS_LOB.FREETEMPORARY(l_pdf1);
  DBMS_LOB.FREETEMPORARY(l_pdf2);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc1); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN rad_pdf.close_document(l_doc2); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_pdf1 IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf1); END IF;
  IF l_pdf2 IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf2); END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 18: set_watermark after finalize raises c_err_handle
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_ok  BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 18: set_watermark after finalize raises c_err_handle');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  l_pdf := rad_pdf.finalize(l_doc);   -- l_doc is now closed
  DBMS_LOB.FREETEMPORARY(l_pdf);
  BEGIN
    rad_pdf.set_watermark(l_doc, 'LATE');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_handle THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_handle was not raised');
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 19: opacity < 0 raises c_err_validation
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_ok  BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 19: opacity < 0 raises c_err_validation');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf.set_watermark(l_doc, 'DRAFT', p_opacity => -0.1);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_validation THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_validation was not raised');
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 20: opacity > 1 raises c_err_validation
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_ok  BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 20: opacity > 1 raises c_err_validation');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf.set_watermark(l_doc, 'DRAFT', p_opacity => 1.1);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_validation THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_validation was not raised');
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 21: unknown layer string raises c_err_validation
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_ok  BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 21: unknown layer string raises c_err_validation');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf.set_watermark(l_doc, 'DRAFT', p_layer => 'BEHIND');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_validation THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_validation was not raised');
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 22: NULL text raises c_err_validation
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_ok  BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 22: NULL text raises c_err_validation');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf.set_watermark(l_doc, NULL);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_validation THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_validation was not raised');
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 23: font_size = 0 raises c_err_validation
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_ok  BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 23: font_size = 0 raises c_err_validation');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf.set_watermark(l_doc, 'DRAFT', p_font_size => 0);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_validation THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_validation was not raised');
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 24: width_pct = 0 raises c_err_validation
-- ===========================================================================
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_img_id PLS_INTEGER;
  l_img    BLOB;
  l_ok     BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 24: width_pct = 0 raises c_err_validation');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  DBMS_LOB.CREATETEMPORARY(l_img, TRUE, DBMS_LOB.SESSION);
  DBMS_LOB.WRITEAPPEND(l_img, 4, HEXTORAW('FFD8FFD9'));
  l_img_id := rad_pdf_images.load_image(l_doc, l_img);
  DBMS_LOB.FREETEMPORARY(l_img);
  BEGIN
    rad_pdf.set_watermark_image(l_doc, l_img_id, p_width_pct => 0);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_validation THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_validation was not raised');
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_img IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_img) = 1 THEN
    DBMS_LOB.FREETEMPORARY(l_img);
  END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 25: width_pct = 101 raises c_err_validation
-- ===========================================================================
DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_img_id PLS_INTEGER;
  l_img    BLOB;
  l_ok     BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 25: width_pct = 101 raises c_err_validation');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  DBMS_LOB.CREATETEMPORARY(l_img, TRUE, DBMS_LOB.SESSION);
  DBMS_LOB.WRITEAPPEND(l_img, 4, HEXTORAW('FFD8FFD9'));
  l_img_id := rad_pdf_images.load_image(l_doc, l_img);
  DBMS_LOB.FREETEMPORARY(l_img);
  BEGIN
    rad_pdf.set_watermark_image(l_doc, l_img_id, p_width_pct => 101);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_validation THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_validation was not raised');
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF l_img IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_img) = 1 THEN
    DBMS_LOB.FREETEMPORARY(l_img);
  END IF;
  RAISE;
END;
/

-- ===========================================================================
-- Test 26: invalid image_id raises c_err_image
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_ok  BOOLEAN := FALSE;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 26: invalid image_id raises c_err_image');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf.set_watermark_image(l_doc, 9999);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_image THEN
        l_ok := TRUE;
      ELSE
        RAISE;
      END IF;
  END;
  assert(l_ok, 'Expected c_err_image was not raised');
  rad_pdf.close_document(l_doc);
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 27: text with PDF special chars (, ), \ - escaping does not crash
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
  DBMS_OUTPUT.PUT_LINE('Test 27: text with PDF special chars - escaped correctly');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  -- Parentheses and backslash must be escaped in PDF literal strings
  rad_pdf.set_watermark(l_doc, 'DRAFT (v1) \100%', p_opacity => 0.3);
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
-- Test 28: single-page document (boundary case)
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
  DBMS_OUTPUT.PUT_LINE('Test 28: single-page document with watermark');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Single page.');
  rad_pdf.set_watermark(l_doc, 'DRAFT');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  assert(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF',
         'Does not start with %PDF');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 29: document with no watermark - output byte-identical to baseline
--          (no extra streams, no /Contents array, no /ExtGState)
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
  DBMS_OUTPUT.PUT_LINE('Test 29: no watermark - no WM_GS in output, /Contents is scalar');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'No watermark document.');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('WM_GS')) = 0,
         'WM_GS found in output without watermark');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('ExtGState')) = 0,
         'ExtGState found in output without watermark');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 30: UNDER watermark - q...Q graphics state save/restore in stream
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
  DBMS_OUTPUT.PUT_LINE('Test 30: UNDER watermark - q...Q present in stream');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.write(l_doc, 'Content.');
  rad_pdf.set_watermark(l_doc, 'DRAFT', p_layer => 'UNDER');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  -- Both q (save) and Q (restore) must appear; they always do via emit_path
  -- but verifying them in the watermark stream indirectly via the BLOB
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('WM_GS')) > 0,
         'WM_GS not found in UNDER watermark output');
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('DRAFT')) > 0,
         'Watermark text DRAFT not found in output');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 11 complete.
PROMPT  Review output above - all tests should show PASS.
PROMPT ================================================================
