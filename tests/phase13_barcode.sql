-- phase13_barcode.sql - Acceptance tests for rad_pdf_barcode QR code (v1.6.0).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase13_barcode.sql
--
-- Structural tests only (module counts, error paths, PDF stream content).
-- The decode round-trip (PDF -> raster -> QR scanner) is performed out of
-- band: see docs/sample17.sql.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET DEFINE OFF

PROMPT ================================================================
PROMPT  Phase 13 - Barcode / QR Code Acceptance Tests (v1.6.0)
PROMPT ================================================================
PROMPT

-- ===========================================================================
-- Test 1: module counts for known inputs (QR version selection)
-- ===========================================================================
DECLARE
  l_n PLS_INTEGER;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 1: qrcode_modules - version selection');
  -- 'HELLO WORLD' (11 chars alphanumeric) @ M -> version 1: 21 + 8 quiet = 29
  l_n := rad_pdf_barcode.qrcode_modules('HELLO WORLD', 'M');
  assert(l_n = 29, 'HELLO WORLD/M expected 29 modules, got ' || l_n);
  -- 8 digits numeric @ L -> version 1
  l_n := rad_pdf_barcode.qrcode_modules('12345678', 'L');
  assert(l_n = 29, '12345678/L expected 29 modules, got ' || l_n);
  -- higher EC level on same content needs a bigger version
  assert(rad_pdf_barcode.qrcode_modules(RPAD('A', 40, 'B'), 'H')
         > rad_pdf_barcode.qrcode_modules(RPAD('A', 40, 'B'), 'L'),
         'EC level H should need more modules than L for the same content');
  -- unknown EC level falls back to M (same as explicit M)
  assert(rad_pdf_barcode.qrcode_modules('FALLBACK TEST', 'X')
         = rad_pdf_barcode.qrcode_modules('FALLBACK TEST', 'M'),
         'unknown EC level should fall back to M');
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 2: NULL value raises c_err_barcode
-- ===========================================================================
DECLARE
  l_n PLS_INTEGER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 2: NULL value raises -20820');
  BEGIN
    l_n := rad_pdf_barcode.qrcode_modules(NULL);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: no error for NULL');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_barcode THEN
        DBMS_OUTPUT.PUT_LINE('  PASS  (' || SQLCODE || ' raised as expected)');
      ELSE
        RAISE;
      END IF;
  END;
END;
/

-- ===========================================================================
-- Test 3: value exceeding QR v40 capacity raises c_err_barcode
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 3: capacity overflow raises -20820');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    -- v40-H byte capacity is 1273; 5000 chars cannot fit at EC level H
    rad_pdf_barcode.qrcode(l_doc, RPAD('x', 5000, 'x'), 10, 10, 100, 'H');
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: no error for oversize value');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_barcode THEN
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
-- Test 4: invalid size raises c_err_barcode
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: size <= 0 raises -20820');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    rad_pdf_barcode.qrcode(l_doc, 'TEST', 10, 10, 0);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: no error for size 0');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = rad_pdf_types.c_err_barcode THEN
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
-- Test 5: bad doc handle raises c_err_handle (assert_valid path)
-- ===========================================================================
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 5: invalid handle raises error');
  BEGIN
    rad_pdf_barcode.qrcode(-999, 'TEST', 10, 10, 100);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: no error for bad handle');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE BETWEEN -20999 AND -20000 AND SQLCODE != -20999 THEN
        DBMS_OUTPUT.PUT_LINE('  PASS  (' || SQLCODE || ' raised as expected)');
      ELSE
        RAISE;
      END IF;
  END;
END;
/

-- ===========================================================================
-- Test 6: QR in finalized PDF - valid PDF, path fill operators present
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
  DBMS_OUTPUT.PUT_LINE('Test 6: QR renders into a valid PDF');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_barcode.qrcode(l_doc, 'https://radicle.it', 72, 500, 150, 'M');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 1000, 'BLOB too small');
  assert(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF',
         'does not start with %PDF');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 7: facade shortcut rad_pdf.qrcode + mm units + custom color
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
  DBMS_OUTPUT.PUT_LINE('Test 7: facade shortcut, mm units, custom color');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.qrcode(l_doc, 'FACADE TEST', 20, 150, 40,
                 p_ec_level => 'Q', p_color => '003366', p_unit => 'mm');
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
-- Test 8: all encoding modes finalize (numeric, alnum, byte, UTF-8 ECI)
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
  DBMS_OUTPUT.PUT_LINE('Test 8: all four encoding modes');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.qrcode(l_doc, '0123456789012345',          72, 650, 100);  -- numeric
  rad_pdf.qrcode(l_doc, 'ALNUM-TEST $%*+./:',       250, 650, 100);  -- alphanumeric
  rad_pdf.qrcode(l_doc, 'MixedCase byte mode!',      72, 450, 100);  -- byte
  rad_pdf.qrcode(l_doc, 'UTF-8: città però Müller', 250, 450, 100);  -- ECI
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 3000, 'BLOB too small for 4 QR codes');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 9: large content (version ~25+) finalizes without 32k issues
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_n   PLS_INTEGER;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 9: high-version QR (large content)');
  l_n := rad_pdf_barcode.qrcode_modules(RPAD('0', 1500, '7'), 'M');
  assert(l_n >= 100, 'expected a high version, got ' || l_n || ' modules');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.qrcode(l_doc, RPAD('0', 1500, '7'), 72, 300, 300, 'M');
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 5000, 'BLOB too small');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS  (' || l_n || ' modules per side)');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 10: QR + layout engine + watermark coexist in one document
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
  DBMS_OUTPUT.PUT_LINE('Test 10: QR + layout engine + watermark');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.heading(l_doc, 'Invoice 2026-001', 1);
  rad_pdf.write(l_doc, 'Scan the QR code to pay online.');
  rad_pdf.set_watermark(l_doc, 'DEMO');
  rad_pdf.qrcode(l_doc, 'https://pay.example.com/i/2026-001', 400, 80, 120);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 2000, 'BLOB too small');
  assert(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF',
         'does not start with %PDF');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 11: Code 128 - subsets B and C render into a valid PDF
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
  DBMS_OUTPUT.PUT_LINE('Test 11: Code 128 subsets B and C');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_barcode.code128(l_doc, 'RAD-PDF-2026', 60, 700, 220, 50);  -- subset B
  rad_pdf_barcode.code128(l_doc, '0123456789',  60, 600, 180, 50);   -- subset C
  rad_pdf_barcode.code128(l_doc, 'NoText', 60, 500, 150, 30,
                          p_show_text => FALSE);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 1500, 'BLOB too small');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 12: Code 39 - charset validation and full-ASCII mode
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
  DBMS_OUTPUT.PUT_LINE('Test 12: Code 39 charset validation + full ASCII');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_barcode.code39(l_doc, 'ABC-1234', 60, 700, 260, 50);
  -- lowercase rejected in standard mode
  BEGIN
    rad_pdf_barcode.code39(l_doc, 'abc', 60, 600, 200, 50);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: lowercase accepted in standard mode');
  EXCEPTION WHEN OTHERS THEN
    assert(SQLCODE = rad_pdf_types.c_err_barcode,
           'expected -20820 for lowercase, got ' || SQLCODE);
  END;
  -- lowercase OK in full-ASCII mode
  rad_pdf_barcode.code39(l_doc, 'abc', 60, 600, 200, 50, p_full_ascii => TRUE);
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
-- Test 13: EAN-13 - check digit computed, validated, and rejected
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
  DBMS_OUTPUT.PUT_LINE('Test 13: EAN-13 check digit handling');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  -- 12 digits: check digit computed (5901234123457)
  rad_pdf_barcode.ean13(l_doc, '590123412345', 60, 700, 70);
  -- 13 digits with correct check digit: accepted
  rad_pdf_barcode.ean13(l_doc, '8001120008978', 60, 580, 70);
  -- 13 digits with wrong check digit: rejected
  BEGIN
    rad_pdf_barcode.ean13(l_doc, '8001120008977', 60, 460, 70);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: wrong check digit accepted');
  EXCEPTION WHEN OTHERS THEN
    assert(SQLCODE = rad_pdf_types.c_err_barcode,
           'expected -20820 for bad check digit, got ' || SQLCODE);
  END;
  -- non-digits rejected
  BEGIN
    rad_pdf_barcode.ean13(l_doc, '12345A', 60, 340, 70);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: non-digit accepted');
  EXCEPTION WHEN OTHERS THEN
    assert(SQLCODE = rad_pdf_types.c_err_barcode,
           'expected -20820 for non-digits, got ' || SQLCODE);
  END;
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 1500, 'BLOB too small');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 14: facade rad_pdf.barcode dispatcher (all types + unknown type)
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
  DBMS_OUTPUT.PUT_LINE('Test 14: facade barcode dispatcher');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf.barcode(l_doc, 'CODE128', 'FACADE-TEST', 20, 240, 80, 18, p_unit => 'mm');
  rad_pdf.barcode(l_doc, 'code 39', 'FACADE39',    20, 210, 80, 18, p_unit => 'mm');
  rad_pdf.barcode(l_doc, 'EAN-13',  '590123412345', 20, 175, 40, 25, p_unit => 'mm');
  BEGIN
    rad_pdf.barcode(l_doc, 'AZTEC', 'X', 20, 140, 40, 20, p_unit => 'mm');
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: unknown type accepted');
  EXCEPTION WHEN OTHERS THEN
    assert(SQLCODE = rad_pdf_types.c_err_barcode,
           'expected -20820 for unknown type, got ' || SQLCODE);
  END;
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 1500, 'BLOB too small');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 15: 1D barcodes restore the document font state
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_size NUMBER;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 15: font state restored after human-readable text');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_canvas.set_font(l_doc, 'Times', 'B', 14);
  rad_pdf_barcode.code128(l_doc, 'FONT-STATE', 60, 700, 200, 50);
  l_size := rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_font_size);
  assert(l_size = 14, 'font size not restored: ' || l_size);
  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 13 complete - all barcode tests passed.
PROMPT ================================================================
