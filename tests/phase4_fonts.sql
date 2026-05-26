-- phase4_fonts.sql - acceptance tests for Phase 4 (rad_pdf_fonts)
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
  -- 1. load_standard_fonts is idempotent; standard fonts load at index 1-14
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_idx PLS_INTEGER;
  BEGIN
    rad_pdf_fonts.load_standard_fonts;
    rad_pdf_fonts.load_standard_fonts;  -- second call must be a no-op

    l_doc := rad_pdf_ctx.new_doc;
    ok('new_doc valid', rad_pdf_ctx.is_valid(l_doc));

    l_idx := rad_pdf_fonts.find_font(l_doc, 'helvetica', 'N');
    ok('find_font helvetica N = 1', l_idx, 1);

    l_idx := rad_pdf_fonts.find_font(l_doc, 'helvetica', 'B');
    ok('find_font helvetica B = 3', l_idx, 3);

    l_idx := rad_pdf_fonts.find_font(l_doc, 'times', 'N');
    ok('find_font times N = 5', l_idx, 5);

    l_idx := rad_pdf_fonts.find_font(l_doc, 'courier', 'N');
    ok('find_font courier N = 9', l_idx, 9);

    l_idx := rad_pdf_fonts.find_font(l_doc, 'symbol', 'N');
    ok('find_font symbol N = 13', l_idx, 13);

    l_idx := rad_pdf_fonts.find_font(l_doc, 'zapfdingbats', 'N');
    ok('find_font zapfdingbats N = 14', l_idx, 14);

    rad_pdf_ctx.close_doc(l_doc);
    ok('doc closed after phase1 block', NOT rad_pdf_ctx.is_valid(l_doc));
  END;

  -- =========================================================================
  -- 2. text_width returns a positive value for non-empty strings
  -- =========================================================================
  DECLARE
  BEGIN
    ok('text_width Hello Helvetica > 0',
       rad_pdf_fonts.text_width('Hello', 1, 12) > 0);
    ok('text_width empty = 0',
       rad_pdf_fonts.text_width('', 1, 12) = 0);
    ok('text_width Courier monospaced',
       rad_pdf_fonts.text_width('ABC', 9, 10) > 0);
  END;

  -- =========================================================================
  -- 3. text_to_pdf_string for standard (non-CID) fonts
  -- =========================================================================
  DECLARE
  BEGIN
    ok('text_to_pdf_string Hello',
       rad_pdf_fonts.text_to_pdf_string('Hello', 1),
       '(Hello)');
    ok('text_to_pdf_string empty',
       rad_pdf_fonts.text_to_pdf_string('', 1),
       '()');
    ok('text_to_pdf_string escapes backslash',
       rad_pdf_fonts.text_to_pdf_string('a\b', 1),
       '(a\\b)');
    ok('text_to_pdf_string escapes parens',
       rad_pdf_fonts.text_to_pdf_string('(x)', 1),
       '(\(x\))');
  END;

  -- =========================================================================
  -- 4. mark_char_used does not raise for standard fonts (no-op guard)
  -- =========================================================================
  DECLARE
    l_raised BOOLEAN := FALSE;
  BEGIN
    BEGIN
      rad_pdf_fonts.mark_char_used(1, 65);  -- font 1 is standard; should be a no-op
    EXCEPTION WHEN OTHERS THEN
      l_raised := TRUE;
    END;
    ok('mark_char_used on standard font does not raise', NOT l_raised);
  END;

  -- =========================================================================
  -- 5. Accessor: font_exists, is_cid, unit_norm, font_pdf_name
  -- =========================================================================
  DECLARE
  BEGIN
    ok('font_exists(1) is TRUE',   rad_pdf_fonts.font_exists(1));
    ok('font_exists(999) is FALSE', NOT rad_pdf_fonts.font_exists(999));
    ok('is_cid(1) is FALSE',        NOT rad_pdf_fonts.is_cid(1));
    ok('font_pdf_name(1)',
       rad_pdf_fonts.font_pdf_name(1), 'Helvetica');
    ok('font_pdf_name(5)',
       rad_pdf_fonts.font_pdf_name(5), 'Times-Roman');
    ok('font_pdf_name(9)',
       rad_pdf_fonts.font_pdf_name(9), 'Courier');
  END;

  -- =========================================================================
  -- 6. mark_font_used + write_font_objects for standard fonts
  -- =========================================================================
  DECLARE
    l_doc     rad_pdf_types.t_doc_handle;
    l_result  VARCHAR2(32767);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    -- Mark Helvetica (font 1) as used in this document
    rad_pdf_fonts.mark_font_used(l_doc, 1);

    -- write_font_objects must emit the Type1 font object and return a resource string
    l_result := rad_pdf_fonts.write_font_objects(l_doc);

    ok('write_font_objects non-null', l_result IS NOT NULL);
    ok('write_font_objects starts with /F',
       SUBSTR(LTRIM(l_result), 1, 2) = '/F');
    ok('write_font_objects contains 0 R',
       INSTR(l_result, ' 0 R') > 0);

    -- Mark a second font and write again from scratch on a fresh doc
    rad_pdf_ctx.close_doc(l_doc);
    ok('doc closed after write test', NOT rad_pdf_ctx.is_valid(l_doc));
  END;

  -- =========================================================================
  -- 7. mark_font_used for multiple fonts
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_result VARCHAR2(32767);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    rad_pdf_fonts.mark_font_used(l_doc, 1);   -- Helvetica
    rad_pdf_fonts.mark_font_used(l_doc, 5);   -- Times-Roman
    rad_pdf_fonts.mark_font_used(l_doc, 9);   -- Courier

    l_result := rad_pdf_fonts.write_font_objects(l_doc);

    ok('multi-font resource has /F1', INSTR(l_result, '/F1 ') > 0);
    ok('multi-font resource has /F5', INSTR(l_result, '/F5 ') > 0);
    ok('multi-font resource has /F9', INSTR(l_result, '/F9 ') > 0);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 8. write_font_objects on a doc with no used fonts returns empty string
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_result VARCHAR2(32767);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    l_result := rad_pdf_fonts.write_font_objects(l_doc);
    ok('write_font_objects no used fonts returns empty', l_result IS NULL);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 9. close_doc via rad_pdf_ctx.close_doc marks handle as invalid
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    rad_pdf_fonts.mark_font_used(l_doc, 1);
    ok('handle valid before close', rad_pdf_ctx.is_valid(l_doc));

    rad_pdf_ctx.close_doc(l_doc);
    ok('handle invalid after close', NOT rad_pdf_ctx.is_valid(l_doc));
  END;

  -- =========================================================================
  -- 10. find_font raises c_err_font for unknown family
  -- =========================================================================
  DECLARE
    l_doc    rad_pdf_types.t_doc_handle;
    l_raised BOOLEAN := FALSE;
    l_dummy  PLS_INTEGER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    BEGIN
      l_dummy := rad_pdf_fonts.find_font(l_doc, 'nonexistentfamily_xyz', 'N');
    EXCEPTION
      WHEN OTHERS THEN
        l_raised := (SQLCODE = rad_pdf_types.c_err_font);
    END;
    ok('find_font unknown family raises c_err_font', l_raised);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 11. Multiple documents are independent (font marking is per-doc)
  -- =========================================================================
  DECLARE
    l_doc1 rad_pdf_types.t_doc_handle;
    l_doc2 rad_pdf_types.t_doc_handle;
    l_res1 VARCHAR2(32767);
    l_res2 VARCHAR2(32767);
  BEGIN
    l_doc1 := rad_pdf_ctx.new_doc;
    l_doc2 := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc1);
    rad_pdf_serial.init_doc(l_doc2);

    rad_pdf_fonts.mark_font_used(l_doc1, 1);   -- Helvetica in doc1 only
    rad_pdf_fonts.mark_font_used(l_doc2, 9);   -- Courier in doc2 only

    l_res1 := rad_pdf_fonts.write_font_objects(l_doc1);
    l_res2 := rad_pdf_fonts.write_font_objects(l_doc2);

    ok('doc1 has Helvetica (/F1)', INSTR(l_res1, '/F1 ') > 0);
    ok('doc1 does not have Courier', INSTR(l_res1, '/F9 ') = 0);
    ok('doc2 has Courier (/F9)',    INSTR(l_res2, '/F9 ') > 0);
    ok('doc2 does not have Helvetica', INSTR(l_res2, '/F1 ') = 0);

    rad_pdf_ctx.close_doc(l_doc1);
    rad_pdf_ctx.close_doc(l_doc2);
  END;

  -- =========================================================================
  -- 12. Standard fonts survive close_doc on other documents
  -- =========================================================================
  DECLARE
    l_doc1 rad_pdf_types.t_doc_handle;
    l_doc2 rad_pdf_types.t_doc_handle;
    l_idx  PLS_INTEGER;
  BEGIN
    l_doc1 := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc1);
    rad_pdf_ctx.close_doc(l_doc1);

    -- Standard fonts must still be accessible after a doc is closed
    l_doc2 := rad_pdf_ctx.new_doc;
    l_idx := rad_pdf_fonts.find_font(l_doc2, 'helvetica', 'N');
    ok('standard font still accessible after other doc closed', l_idx = 1);
    ok('font_exists(1) after close_doc', rad_pdf_fonts.font_exists(1));

    rad_pdf_ctx.close_doc(l_doc2);
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 4: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 4 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
