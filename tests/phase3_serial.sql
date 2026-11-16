-- phase3_serial.sql - acceptance tests for Phase 3 (rad_pdf_serial)
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

    rad_pdf_doc.close_doc(l_doc);
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

    rad_pdf_doc.close_doc(l_doc);
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

    rad_pdf_doc.close_doc(l_doc);
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

    rad_pdf_doc.close_doc(l_doc);
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

    rad_pdf_doc.close_doc(l_doc);
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

    rad_pdf_doc.close_doc(l_doc);
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
    rad_pdf_doc.close_doc(l_doc);
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
    rad_pdf_doc.close_doc(l_doc);
  END;

  -- =========================================================================
  -- A6: begin_obj with a CLOB dictionary at the boundaries -- 27000 (the switch to the chunked path), 32767/32768
  -- (the VARCHAR2 limit), multiples of 8000 (the chunk): the same bytes as the VARCHAR2 form where that exists, and
  -- beyond it every xref offset points to its object and the dictionary is written exactly
  -- =========================================================================
  DECLARE
    TYPE t_lens IS TABLE OF PLS_INTEGER;
    l_cmp  t_lens := t_lens(100, 26999, 27000, 27001, 32000);
    l_big  t_lens := t_lens(32767, 32768, 40000, 48000, 48001, 100000);
    l_v    BLOB;
    l_c    BLOB;
    l_objs PLS_INTEGER;

    FUNCTION dict_of(p_len PLS_INTEGER) RETURN CLOB IS
      l_d CLOB;
    BEGIN
      DBMS_LOB.CREATETEMPORARY(l_d, TRUE);
      DBMS_LOB.WRITEAPPEND(l_d, 7, '/Junk (');
      FOR i IN 1 .. TRUNC((p_len - 8) / 10) LOOP
        DBMS_LOB.WRITEAPPEND(l_d, 10, '0123456789');
      END LOOP;
      IF MOD(p_len - 8, 10) > 0 THEN
        DBMS_LOB.WRITEAPPEND(l_d, MOD(p_len - 8, 10), SUBSTR('0123456789', 1, MOD(p_len - 8, 10)));
      END IF;
      DBMS_LOB.WRITEAPPEND(l_d, 1, ')');
      RETURN l_d;
    END dict_of;

    -- a document: the big object first, then pages and catalog; finished
    FUNCTION doc_with(p_len PLS_INTEGER, p_clob BOOLEAN, p_objs OUT PLS_INTEGER) RETURN BLOB IS
      l_doc rad_pdf_types.t_doc_handle;
      l_d   CLOB := dict_of(p_len);
      l_n   NUMBER;
      l_pg  NUMBER;
      l_cat NUMBER;
      l_out BLOB;
    BEGIN
      l_doc := rad_pdf_ctx.new_doc;
      rad_pdf_serial.init_doc(l_doc);
      rad_pdf_serial.new_page(l_doc);
      IF p_clob THEN
        l_n := rad_pdf_serial.begin_obj(l_doc, l_d);
      ELSE
        l_n := rad_pdf_serial.begin_obj(l_doc, DBMS_LOB.SUBSTR(l_d, 32767, 1));
      END IF;
      l_pg  := rad_pdf_serial.begin_obj(l_doc, '/Type /Pages /Count 0 /Kids []');
      l_cat := rad_pdf_serial.begin_obj(l_doc, '/Type /Catalog /Pages ' || l_pg || ' 0 R');
      rad_pdf_serial.finish_doc(l_doc, l_cat, NULL, 0);
      l_out := rad_pdf_serial.get_doc_copy(l_doc);
      rad_pdf_doc.close_doc(l_doc);
      DBMS_LOB.FREETEMPORARY(l_d);
      p_objs := l_cat;
      RETURN l_out;
    END doc_with;

    -- every in-use xref entry points to 'N 0 obj'; the dictionary of object 1 is exactly dict_of(p_len)
    FUNCTION xref_ok(p_pdf BLOB, p_objs PLS_INTEGER, p_len PLS_INTEGER) RETURN BOOLEAN IS
      l_first PLS_INTEGER;
      l_off   PLS_INTEGER;
      l_d     CLOB := dict_of(p_len);
      l_db    BLOB;
      l_do    INTEGER := 1; l_so INTEGER := 1; l_lc INTEGER := 0; l_w INTEGER;
      l_ok    BOOLEAN := TRUE;
    BEGIN
      l_first := DBMS_LOB.INSTR(p_pdf, UTL_RAW.CAST_TO_RAW('0000000000 65535 f'));
      FOR k IN 1 .. p_objs LOOP
        l_off := TO_NUMBER(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(p_pdf, 10, l_first + 20 * k)));
        IF UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(p_pdf, LENGTH(k || ' 0 obj'), l_off + 1)) != k || ' 0 obj' THEN
          l_ok := FALSE;
        END IF;
      END LOOP;
      l_off := TO_NUMBER(UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(p_pdf, 10, l_first + 20)));
      DBMS_LOB.CREATETEMPORARY(l_db, TRUE);
      DBMS_LOB.CONVERTTOBLOB(l_db, l_d, DBMS_LOB.LOBMAXSIZE, l_do, l_so, DBMS_LOB.DEFAULT_CSID, l_lc, l_w);
      l_ok := l_ok AND DBMS_LOB.COMPARE(p_pdf, l_db, p_len,
                DBMS_LOB.INSTR(p_pdf, UTL_RAW.CAST_TO_RAW('<<'), l_off + 1) + 2, 1) = 0
                   AND DBMS_LOB.SUBSTR(p_pdf, 2, DBMS_LOB.INSTR(p_pdf, UTL_RAW.CAST_TO_RAW('<<'), l_off + 1) + 2 + p_len)
                       = UTL_RAW.CAST_TO_RAW('>>');
      DBMS_LOB.FREETEMPORARY(l_db);
      DBMS_LOB.FREETEMPORARY(l_d);
      RETURN l_ok;
    END xref_ok;
  BEGIN
    FOR i IN 1 .. l_cmp.COUNT LOOP
      l_v := doc_with(l_cmp(i), FALSE, l_objs);
      l_c := doc_with(l_cmp(i), TRUE, l_objs);
      ok('begin_obj CLOB = VARCHAR2 bytes, dictionary of ' || l_cmp(i),
         DBMS_LOB.GETLENGTH(l_v) = DBMS_LOB.GETLENGTH(l_c) AND DBMS_LOB.COMPARE(l_v, l_c) = 0);
      ok('xref and dictionary exact, ' || l_cmp(i), xref_ok(l_c, l_objs, l_cmp(i)));
      DBMS_LOB.FREETEMPORARY(l_v);
      DBMS_LOB.FREETEMPORARY(l_c);
    END LOOP;
    FOR i IN 1 .. l_big.COUNT LOOP
      l_c := doc_with(l_big(i), TRUE, l_objs);
      ok('begin_obj CLOB beyond VARCHAR2: xref and dictionary exact, ' || l_big(i), xref_ok(l_c, l_objs, l_big(i)));
      DBMS_LOB.FREETEMPORARY(l_c);
    END LOOP;
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
