-- phase3_serial.sql — acceptance tests for Phase 3 (rad_pdf_serial)
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
  -- Basic init / close lifecycle
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    ok('new_doc valid', rad_pdf_ctx.is_valid(l_doc));

    rad_pdf_serial.init_doc(l_doc);
    ok('page_count after init', rad_pdf_serial.page_count(l_doc), 0);

    rad_pdf_serial.new_page(l_doc);
    ok('page_count after new_page', rad_pdf_serial.page_count(l_doc), 1);
    ok('current_page 0-based',      rad_pdf_serial.current_page(l_doc), 0);

    rad_pdf_ctx.close_doc(l_doc);
    ok('closed after close_doc', NOT rad_pdf_ctx.is_valid(l_doc));
  END;

  -- =========================================================================
  -- Multi-page: page blobs are distinct and retain correct content
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_b0   BLOB;
    l_b1   BLOB;
    l_h0   VARCHAR2(16);
    l_h1   VARCHAR2(16);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    rad_pdf_serial.new_page(l_doc);
    rad_pdf_serial.page_write(l_doc, 'PAGE0');

    rad_pdf_serial.new_page(l_doc);
    rad_pdf_serial.page_write(l_doc, 'PAGE1');

    ok('page_count 2', rad_pdf_serial.page_count(l_doc), 2);
    ok('current_page 1', rad_pdf_serial.current_page(l_doc), 1);

    -- Flush remaining buffer then read page blobs.
    rad_pdf_serial.page_flush(l_doc);

    l_b0 := rad_pdf_serial.get_page_blob(l_doc, 0);
    l_b1 := rad_pdf_serial.get_page_blob(l_doc, 1);

    -- Page 0 blob contains 'PAGE0', page 1 blob contains 'PAGE1'.
    l_h0 := RAWTOHEX(DBMS_LOB.SUBSTR(l_b0, 5, 1));
    l_h1 := RAWTOHEX(DBMS_LOB.SUBSTR(l_b1, 5, 1));
    ok('page0 content', l_h0, RAWTOHEX(UTL_RAW.CAST_TO_RAW('PAGE0')));
    ok('page1 content', l_h1, RAWTOHEX(UTL_RAW.CAST_TO_RAW('PAGE1')));
    ok('pages distinct', l_h0 != l_h1);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- goto_page switches active page; content goes to correct blob
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_b   BLOB;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    rad_pdf_serial.new_page(l_doc);   -- page 0
    rad_pdf_serial.page_write(l_doc, 'A');

    rad_pdf_serial.new_page(l_doc);   -- page 1
    rad_pdf_serial.page_write(l_doc, 'B');

    -- Go back to page 0 and append more content.
    rad_pdf_serial.goto_page(l_doc, 0);
    rad_pdf_serial.page_write(l_doc, 'C');
    rad_pdf_serial.page_flush(l_doc);

    l_b := rad_pdf_serial.get_page_blob(l_doc, 0);
    ok('goto_page appends to page0',
       DBMS_LOB.INSTR(l_b, UTL_RAW.CAST_TO_RAW('AC')) > 0
       OR ( DBMS_LOB.INSTR(l_b, UTL_RAW.CAST_TO_RAW('A')) > 0
            AND DBMS_LOB.INSTR(l_b, UTL_RAW.CAST_TO_RAW('C')) > 0 ));

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- goto_page raises on invalid page number
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_raised BOOLEAN := FALSE;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_serial.new_page(l_doc);

    BEGIN
      rad_pdf_serial.goto_page(l_doc, 99);
    EXCEPTION WHEN OTHERS THEN l_raised := TRUE;
    END;
    ok('goto_page raises on bad nr', l_raised);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- PDF object numbering: begin_obj returns sequential numbers
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_n1  NUMBER;
    l_n2  NUMBER;
    l_n3  NUMBER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    -- obj 0 is the free-list head (pre-seeded); first explicit object = 1.
    l_n1 := rad_pdf_serial.begin_obj(l_doc, '/Type /Catalog');
    l_n2 := rad_pdf_serial.begin_obj(l_doc, '/Type /Pages /Count 0 /Kids []');
    l_n3 := rad_pdf_serial.begin_obj(l_doc);
    rad_pdf_serial.end_obj(l_doc);

    ok('obj1 number', l_n1, 1);
    ok('obj2 number', l_n2, 2);
    ok('obj3 number', l_n3, 3);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- write_stream_obj: produces a non-null doc BLOB, object number >= 1
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_data BLOB;
    l_obj  NUMBER;
    l_len  NUMBER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    DBMS_LOB.CREATETEMPORARY(l_data, TRUE);
    DECLARE l_r RAW(100) := UTL_RAW.CAST_TO_RAW('BT /F1 12 Tf 100 700 Td (Hello) Tj ET'); BEGIN
      DBMS_LOB.WRITEAPPEND(l_data, UTL_RAW.LENGTH(l_r), l_r);
    END;
    l_obj := rad_pdf_serial.write_stream_obj(l_doc, l_data, NULL, TRUE);
    DBMS_LOB.FREETEMPORARY(l_data);

    ok('stream obj number >= 1', l_obj >= 1);

    -- Doc BLOB should contain 'stream' keyword.
    DECLARE
      l_copy BLOB;
    BEGIN
      l_copy := rad_pdf_serial.get_doc_copy(l_doc);
      ok('doc contains stream',
         DBMS_LOB.INSTR(l_copy,
           UTL_RAW.CAST_TO_RAW('stream')) > 0);
      DBMS_LOB.FREETEMPORARY(l_copy);
    END;

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- finish_doc produces a valid PDF header + xref structure
  -- =========================================================================
  DECLARE
    l_doc      rad_pdf_types.t_doc_handle;
    l_copy     BLOB;
    l_data     BLOB;
    l_page_obj NUMBER;
    l_cat_obj  NUMBER;
    l_inf_obj  NUMBER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    rad_pdf_serial.new_page(l_doc);
    rad_pdf_serial.page_write(l_doc, 'BT (Test) Tj ET');

    -- Minimal PDF structure: write three objects.
    l_page_obj := rad_pdf_serial.begin_obj(l_doc,
                    '/Type /Pages /Count 1 /Kids [3 0 R]');
    l_cat_obj  := rad_pdf_serial.begin_obj(l_doc,
                    '/Type /Catalog /Pages ' || l_page_obj || ' 0 R');

    DBMS_LOB.CREATETEMPORARY(l_data, TRUE);
    l_inf_obj  := rad_pdf_serial.write_stream_obj(l_doc, l_data, NULL, FALSE);
    DBMS_LOB.FREETEMPORARY(l_data);

    rad_pdf_serial.finish_doc(l_doc, l_cat_obj, l_inf_obj, 1);

    l_copy := rad_pdf_serial.get_doc_copy(l_doc);

    ok('starts with %PDF',
       RAWTOHEX(DBMS_LOB.SUBSTR(l_copy, 4, 1)) =
       RAWTOHEX(UTL_RAW.CAST_TO_RAW('%PDF')));

    ok('contains xref',
       DBMS_LOB.INSTR(l_copy, UTL_RAW.CAST_TO_RAW('xref')) > 0);

    ok('contains %%EOF',
       DBMS_LOB.INSTR(l_copy, UTL_RAW.CAST_TO_RAW('%%EOF')) > 0);

    ok('contains startxref',
       DBMS_LOB.INSTR(l_copy, UTL_RAW.CAST_TO_RAW('startxref')) > 0);

    ok('doc length > 100', DBMS_LOB.GETLENGTH(l_copy) > 100);

    DBMS_LOB.FREETEMPORARY(l_copy);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- get_doc_copy returns a fresh temporary BLOB (caller-owned)
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_c1   BLOB;
    l_c2   BLOB;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    l_c1 := rad_pdf_serial.get_doc_copy(l_doc);
    l_c2 := rad_pdf_serial.get_doc_copy(l_doc);

    ok('get_doc_copy is temp', DBMS_LOB.ISTEMPORARY(l_c1) = 1);
    ok('two copies independent', DBMS_LOB.GETLENGTH(l_c1) = DBMS_LOB.GETLENGTH(l_c2));

    DBMS_LOB.FREETEMPORARY(l_c1);
    DBMS_LOB.FREETEMPORARY(l_c2);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 3: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 3 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
