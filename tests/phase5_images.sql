-- phase5_images.sql - acceptance tests for Phase 5 (rad_pdf_images)
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  l_ok   PLS_INTEGER := 0;
  l_fail PLS_INTEGER := 0;

  PROCEDURE ok(p_label IN VARCHAR2, p_cond IN BOOLEAN) IS
  BEGIN
    IF p_cond THEN
      DBMS_OUTPUT.PUT_LINE('PASS  ' || p_label); l_ok := l_ok + 1;
    ELSE
      DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_label); l_fail := l_fail + 1;
    END IF;
  END;

  PROCEDURE ok(p_label IN VARCHAR2, p_got IN VARCHAR2, p_exp IN VARCHAR2) IS
  BEGIN
    ok(p_label, NVL(p_got,'<null>') = NVL(p_exp,'<null>'));
  END;

  PROCEDURE ok(p_label IN VARCHAR2, p_got IN NUMBER, p_exp IN NUMBER) IS
  BEGIN
    ok(p_label, p_got = p_exp);
  END;

BEGIN
  -- =========================================================================
  -- 1. set_image_cache_limit and clear_image_cache do not raise
  -- =========================================================================
  BEGIN
    rad_pdf_images.set_image_cache_limit(10485760);   -- 10 MB
    ok('set_image_cache_limit does not raise', TRUE);

    rad_pdf_images.clear_image_cache;
    ok('clear_image_cache does not raise', TRUE);

    -- Restore default
    rad_pdf_images.set_image_cache_limit(52428800);
  END;

  -- =========================================================================
  -- 2. load_image raises on NULL BLOB
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_raised BOOLEAN := FALSE;
    l_dummy  PLS_INTEGER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    BEGIN
      l_dummy := rad_pdf_images.load_image(l_doc, CAST(NULL AS BLOB));
    EXCEPTION WHEN OTHERS THEN
      l_raised := (SQLCODE = rad_pdf_types.c_err_validation);
    END;
    ok('load_image NULL blob raises c_err_validation', l_raised);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 3. load_image raises on empty BLOB
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_blob   BLOB;
    l_raised BOOLEAN := FALSE;
    l_dummy  PLS_INTEGER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    BEGIN
      l_dummy := rad_pdf_images.load_image(l_doc, l_blob);
    EXCEPTION WHEN OTHERS THEN
      l_raised := (SQLCODE = rad_pdf_types.c_err_validation);
    END;
    ok('load_image empty blob raises c_err_validation', l_raised);
    DBMS_LOB.FREETEMPORARY(l_blob);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 4. load_image raises on unrecognised image format
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_blob   BLOB;
    l_raised BOOLEAN := FALSE;
    l_dummy  PLS_INTEGER;
    l_junk   RAW(16) := HEXTORAW('DEADBEEFCAFEBABE0102030405060708');
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob, UTL_RAW.LENGTH(l_junk), l_junk);
    BEGIN
      l_dummy := rad_pdf_images.load_image(l_doc, l_blob);
    EXCEPTION WHEN OTHERS THEN
      l_raised := (SQLCODE = rad_pdf_types.c_err_image);
    END;
    ok('load_image bad format raises c_err_image', l_raised);
    DBMS_LOB.FREETEMPORARY(l_blob);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 5. image_exists returns FALSE for unknown image_id
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    ok('image_exists FALSE for unknown id', NOT rad_pdf_images.image_exists(l_doc, 999));
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 6. write_image_objects returns NULL when no images loaded
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_result VARCHAR2(32767);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    l_result := rad_pdf_images.write_image_objects(l_doc);
    ok('write_image_objects no images returns NULL', l_result IS NULL);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 7. Load a minimal JPEG (1x1 grayscale, 17 bytes).
  --    Hex: FFD8 FFC0 000B 08 0001 0001 01 01 11 00 FFD9
  --    SOI, SOF0 (8-bit, 1x1, 1-component), EOI.
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_blob   BLOB;
    l_id     PLS_INTEGER;
    l_w      NUMBER;
    l_h      NUMBER;
    l_jpeg   RAW(17) := HEXTORAW('FFD8FFC0000B080001000101011100FFD9');
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob, UTL_RAW.LENGTH(l_jpeg), l_jpeg);

    l_id := rad_pdf_images.load_image(l_doc, l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);

    ok('load_image JPEG returns image_id 1',  l_id, 1);
    ok('image_exists after load',  rad_pdf_images.image_exists(l_doc, l_id));

    rad_pdf_images.get_image_dimensions(l_doc, l_id, l_w, l_h);
    ok('JPEG width = 1',  l_w, 1);
    ok('JPEG height = 1', l_h, 1);

    -- Loading the same data again must return the same id (cache hit).
    DECLARE
      l_blob2 BLOB;
      l_id2   PLS_INTEGER;
    BEGIN
      DBMS_LOB.CREATETEMPORARY(l_blob2, TRUE);
      DBMS_LOB.WRITEAPPEND(l_blob2, UTL_RAW.LENGTH(l_jpeg), l_jpeg);
      l_id2 := rad_pdf_images.load_image(l_doc, l_blob2);
      DBMS_LOB.FREETEMPORARY(l_blob2);
      ok('same image returns same id', l_id2, l_id);
    END;

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 8. write_image_objects emits a valid XObject resource fragment for JPEG
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_blob   BLOB;
    l_id     PLS_INTEGER;
    l_result VARCHAR2(32767);
    l_jpeg   RAW(17) := HEXTORAW('FFD8FFC0000B080001000101011100FFD9');
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob, UTL_RAW.LENGTH(l_jpeg), l_jpeg);
    l_id     := rad_pdf_images.load_image(l_doc, l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);

    l_result := rad_pdf_images.write_image_objects(l_doc);

    ok('write_image_objects non-null result',   l_result IS NOT NULL);
    ok('result starts with /I',
       SUBSTR(LTRIM(l_result), 1, 2) = '/I');
    ok('result contains 0 R',
       INSTR(l_result, ' 0 R') > 0);

    -- Doc BLOB should contain 'XObject' keyword (written by rad_pdf_serial).
    DECLARE
      l_copy BLOB;
    BEGIN
      l_copy := rad_pdf_serial.get_doc_copy(l_doc);
      ok('doc blob contains XObject',
         DBMS_LOB.INSTR(l_copy, UTL_RAW.CAST_TO_RAW('XObject')) > 0);
      DBMS_LOB.FREETEMPORARY(l_copy);
    END;

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 9. Two-document isolation: each doc tracks its own images independently
  -- =========================================================================
  DECLARE
    l_doc1   rad_pdf_types.t_doc_handle;
    l_doc2   rad_pdf_types.t_doc_handle;
    l_blob1  BLOB;
    l_blob2  BLOB;
    l_id1    PLS_INTEGER;
    l_id2    PLS_INTEGER;
    -- Two distinct 17-byte JPEG blobs (identical content but different objects).
    l_jpeg   RAW(17) := HEXTORAW('FFD8FFC0000B080001000101011100FFD9');
  BEGIN
    l_doc1 := rad_pdf_ctx.new_doc;
    l_doc2 := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc1);
    rad_pdf_serial.init_doc(l_doc2);

    DBMS_LOB.CREATETEMPORARY(l_blob1, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob1, UTL_RAW.LENGTH(l_jpeg), l_jpeg);
    l_id1 := rad_pdf_images.load_image(l_doc1, l_blob1);
    DBMS_LOB.FREETEMPORARY(l_blob1);

    ok('doc1 has image id 1', l_id1, 1);
    ok('doc1 image exists', rad_pdf_images.image_exists(l_doc1, 1));
    ok('doc2 has no image yet', NOT rad_pdf_images.image_exists(l_doc2, 1));

    DBMS_LOB.CREATETEMPORARY(l_blob2, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob2, UTL_RAW.LENGTH(l_jpeg), l_jpeg);
    l_id2 := rad_pdf_images.load_image(l_doc2, l_blob2);
    DBMS_LOB.FREETEMPORARY(l_blob2);

    ok('doc2 image id also 1 (per-doc counting)', l_id2, 1);
    ok('doc2 image exists', rad_pdf_images.image_exists(l_doc2, 1));

    rad_pdf_ctx.close_doc(l_doc1);
    ok('doc1 closed', NOT rad_pdf_ctx.is_valid(l_doc1));
    ok('doc2 still valid', rad_pdf_ctx.is_valid(l_doc2));
    ok('doc2 image still accessible after doc1 closed',
       rad_pdf_images.image_exists(l_doc2, 1));

    rad_pdf_ctx.close_doc(l_doc2);
  END;

  -- =========================================================================
  -- 10. close_doc via rad_pdf_ctx.close_doc removes per-doc image state
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_blob BLOB;
    l_id   PLS_INTEGER;
    l_jpeg RAW(17) := HEXTORAW('FFD8FFC0000B080001000101011100FFD9');
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob, UTL_RAW.LENGTH(l_jpeg), l_jpeg);
    l_id := rad_pdf_images.load_image(l_doc, l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);

    ok('image visible before close', rad_pdf_images.image_exists(l_doc, l_id));
    rad_pdf_ctx.close_doc(l_doc);
    ok('handle invalid after close', NOT rad_pdf_ctx.is_valid(l_doc));
    -- After close, image_exists on the same (now invalid) handle returns FALSE.
    ok('image_exists returns FALSE after close',
       NOT rad_pdf_images.image_exists(l_doc, l_id));
  END;

  -- =========================================================================
  -- 11. Session cache survives individual document close
  -- =========================================================================
  DECLARE
    l_doc1 rad_pdf_types.t_doc_handle;
    l_doc2 rad_pdf_types.t_doc_handle;
    l_blob BLOB;
    l_id1  PLS_INTEGER;
    l_id2  PLS_INTEGER;
    l_jpeg RAW(17) := HEXTORAW('FFD8FFC0000B080001000101011100FFD9');
  BEGIN
    -- Load image in doc1, close it, then load same image in doc2.
    -- The second load should still work (session cache retained).
    l_doc1 := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc1);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob, UTL_RAW.LENGTH(l_jpeg), l_jpeg);
    l_id1 := rad_pdf_images.load_image(l_doc1, l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);
    rad_pdf_ctx.close_doc(l_doc1);

    l_doc2 := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc2);
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob, UTL_RAW.LENGTH(l_jpeg), l_jpeg);
    l_id2 := rad_pdf_images.load_image(l_doc2, l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);

    ok('session cache hit: same image loads after doc close', l_id2 IS NOT NULL);
    ok('image id resets to 1 in new doc', l_id2, 1);

    rad_pdf_ctx.close_doc(l_doc2);
    rad_pdf_images.clear_image_cache;
    ok('clear_image_cache after test completes', TRUE);
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 5: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 5 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
