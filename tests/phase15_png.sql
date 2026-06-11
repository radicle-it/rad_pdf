-- phase15_png.sql - Acceptance tests for PNG alpha / flate fixes (v1.6.0).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase15_png.sql
--
-- Covers:
--   - pure PL/SQL inflate in rad_pdf_codec.flate_decode (UTL_COMPRESS cannot
--     inflate zlib streams: it validates the gzip CRC32, unavailable for PNG)
--   - flate_encode producing a VALID zlib stream (was: gzip-mangled output)
--   - PNG alpha stripping (RGBA + grey/alpha) producing SMask
--   - clear errors for interlaced and 16-bit-alpha PNGs

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET DEFINE OFF

PROMPT ================================================================
PROMPT  Phase 15 - PNG Alpha / Flate Acceptance Tests (v1.6.0)
PROMPT ================================================================
PROMPT

-- ===========================================================================
-- Test 1: flate_encode -> flate_decode round-trip (pure in-DB validation)
-- ===========================================================================
DECLARE
  l_src  BLOB;
  l_enc  BLOB;
  l_dec  BLOB;
  l_data RAW(2000);
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 1: flate_encode -> flate_decode round-trip');
  l_data := UTL_RAW.CONCAT(
    UTL_RAW.CAST_TO_RAW('RAD_PDF flate round-trip '),
    UTL_RAW.COPIES(HEXTORAW('00FF10E055'), 100));
  DBMS_LOB.CREATETEMPORARY(l_src, TRUE, DBMS_LOB.CALL);
  DBMS_LOB.WRITEAPPEND(l_src, UTL_RAW.LENGTH(l_data), l_data);

  l_enc := rad_pdf_codec.flate_encode(l_src);
  -- zlib header must be 78 9C (CM=8, FCHECK valid)
  assert(RAWTOHEX(DBMS_LOB.SUBSTR(l_enc, 2, 1)) = '789C',
         'zlib header is ' || RAWTOHEX(DBMS_LOB.SUBSTR(l_enc, 2, 1))
         || ' (expected 789C)');
  l_dec := rad_pdf_codec.flate_decode(l_enc, DBMS_LOB.GETLENGTH(l_src));
  assert(DBMS_LOB.GETLENGTH(l_dec) = DBMS_LOB.GETLENGTH(l_src),
         'round-trip length mismatch');
  assert(DBMS_LOB.COMPARE(l_dec, l_src) = 0, 'round-trip content mismatch');
  DBMS_LOB.FREETEMPORARY(l_src);
  DBMS_LOB.FREETEMPORARY(l_enc);
  DBMS_LOB.FREETEMPORARY(l_dec);
  DBMS_OUTPUT.PUT_LINE('  PASS');
END;
/

-- ===========================================================================
-- Test 2: RGBA PNG loads, renders, and produces an SMask
-- ===========================================================================
DECLARE
  l_png BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D4948445200000008000000080806000000C40FBE8B0000'
 || '00124944415478DA63382127D7800F338C0C050022F66101C6FEADF20000000049454E'
 || '44AE426082'));
  l_doc rad_pdf_types.t_doc_handle;
  l_id  PLS_INTEGER;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 2: RGBA PNG -> SMask in output');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_id := rad_pdf_images.load_image(l_doc, l_png);
  rad_pdf_canvas.put_image(l_doc, l_id, 100, 400, 200, 200);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/SMask')) > 0,
         '/SMask missing from output');
  assert(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF',
         'not a PDF');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 3: grey+alpha PNG (color type 4)
-- ===========================================================================
DECLARE
  l_png BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D49484452000000080000000808040000006E0676000000'
 || '00104944415478DA63483E810A1906460000D0054AC16D8F8B2600000000'
 || '49454E44AE426082'));
  l_doc rad_pdf_types.t_doc_handle;
  l_id  PLS_INTEGER;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 3: grey+alpha PNG (type 4)');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_id := rad_pdf_images.load_image(l_doc, l_png);
  rad_pdf_canvas.put_image(l_doc, l_id, 100, 400, 200, 200);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/SMask')) > 0,
         '/SMask missing from output');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 4: multi-IDAT and stored-block PNGs (inflate edge cases)
-- ===========================================================================
DECLARE
  l_multi BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D4948445200000008000000080806000000C40FBE8B0000'
 || '00094944415478DA63E0FAC5F51F1F61C6132800000009494441546618190A00741583'
 || '419D0F75460000000049454E44AE426082'));
  l_stored BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D4948445200000008000000080806000000C40FBE8B0000'
 || '0113494441547801010801F7FE0001020304010203040102030401020304010203040102'
 || '0304010203040102030400010203040102030401020304010203040102030401020304'
 || '0102030401020304000102030401020304010203040102030401020304010203040102'
 || '0304010203040001020304010203040102030401020304010203040102030401020304'
 || '0102030400010203040102030401020304010203040102030401020304010203040102'
 || '0304000102030401020304010203040102030401020304010203040102030401020304'
 || '0001020304010203040102030401020304010203040102030401020304010203040001'
 || '0203040102030401020304010203040102030401020304010203040102030449D70281'
 || '22F30FA90000000049454E44AE426082'));
  l_doc rad_pdf_types.t_doc_handle;
  l_id  PLS_INTEGER;
  l_pdf BLOB;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: multi-IDAT + stored-block PNGs');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_id := rad_pdf_images.load_image(l_doc, l_multi);
  rad_pdf_canvas.put_image(l_doc, l_id, 100, 500, 150, 150);
  l_id := rad_pdf_images.load_image(l_doc, l_stored);
  rad_pdf_canvas.put_image(l_doc, l_id, 300, 500, 150, 150);
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
-- Test 5: interlaced PNG raises a clear c_err_image error
-- ===========================================================================
DECLARE
  l_png BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D49484452000000080000000808020000013C6A194A0000'
 || '00154944415478DA636065656580625C142D38349200007C2503C10F3E6DAA00000000'
 || '49454E44AE426082'));
  l_doc rad_pdf_types.t_doc_handle;
  l_id  PLS_INTEGER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 5: interlaced PNG raises clear error');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    l_id := rad_pdf_images.load_image(l_doc, l_png);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: interlaced PNG accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_image
       AND INSTR(SQLERRM, 'interlaced') > 0 THEN
      DBMS_OUTPUT.PUT_LINE('  PASS  (' || SQLCODE || ' with clear message)');
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
-- Test 6: 16-bit RGBA PNG raises a clear c_err_image error
-- ===========================================================================
DECLARE
  l_png BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D4948445200000008000000081006000000949F62C80000'
 || '00194944415478DA63607EC17E817BC7AB047269865103868301002321F3C11271D446'
 || '0000000049454E44AE426082'));
  l_doc rad_pdf_types.t_doc_handle;
  l_id  PLS_INTEGER;
  l_pdf BLOB;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 6: 16-bit RGBA raises clear error');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  BEGIN
    l_id := rad_pdf_images.load_image(l_doc, l_png);
    rad_pdf_canvas.put_image(l_doc, l_id, 100, 400, 100, 100);
    l_pdf := rad_pdf.finalize(l_doc);
    RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: 16-bit alpha accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = rad_pdf_types.c_err_image
       AND INSTR(SQLERRM, '8-bit') > 0 THEN
      DBMS_OUTPUT.PUT_LINE('  PASS  (' || SQLCODE || ' with clear message)');
    ELSE
      RAISE;
    END IF;
  END;
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 15 complete - all PNG tests passed.
PROMPT ================================================================
