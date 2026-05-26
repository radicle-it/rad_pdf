-- phase6_canvas.sql - acceptance tests for Phase 6 (rad_pdf_canvas)
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
  -- 1. new_page initialises canvas state and creates page 0
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    rad_pdf_fonts.load_standard_fonts;
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);

    rad_pdf_canvas.new_page(l_doc);

    ok('page_count = 1 after new_page', rad_pdf_serial.page_count(l_doc), 1);
    ok('get_info page_width = 595',
       rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_page_width) > 590);
    ok('get_info page_height = 841',
       rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_page_height) > 840);
    ok('get_info page_nr = 1',
       rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_page_nr), 1);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 2. set_font changes font index and size; text_width is consistent
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_w1  NUMBER;
    l_w2  NUMBER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);

    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 12);
    ok('get_info font_idx = 1', rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_font_idx), 1);
    ok('get_info font_size = 12', rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_font_size), 12);

    l_w1 := rad_pdf_canvas.text_width(l_doc, 'Hello');
    ok('text_width Hello > 0', l_w1 > 0);

    -- Bold Helvetica is wider than normal for the same text
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'B', 12);
    l_w2 := rad_pdf_canvas.text_width(l_doc, 'Hello');
    ok('bold wider than normal (or equal)', l_w2 >= l_w1);

    -- set_font by index
    rad_pdf_canvas.set_font(l_doc, 9, 10);  -- Courier
    ok('set_font by index: font_idx = 9',
       rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_font_idx), 9);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 3. write_text emits content to the page stream
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_blob BLOB;
    l_txt  VARCHAR2(100);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 12);

    rad_pdf_canvas.write_text(l_doc, 'Test', 72, 700, 'pt');

    -- Flush and inspect page content
    rad_pdf_serial.page_flush(l_doc);
    l_blob := rad_pdf_serial.get_page_blob(l_doc, 0);
    l_txt  := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_blob, 200, 1));

    ok('page blob non-empty', DBMS_LOB.GETLENGTH(l_blob) > 0);
    ok('page contains BT',   INSTR(l_txt, 'BT') > 0);
    ok('page contains Tj',   INSTR(l_txt, 'Tj') > 0);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 4. set_color / write_text uses current colour in stream
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_blob BLOB;
    l_txt  VARCHAR2(200);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 10);
    rad_pdf_canvas.set_color(l_doc, 'ff0000');  -- red

    rad_pdf_canvas.write_text(l_doc, 'Red', 72, 700);
    rad_pdf_serial.page_flush(l_doc);
    l_blob := rad_pdf_serial.get_page_blob(l_doc, 0);
    l_txt  := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_blob, 300, 1));

    -- Red = 1 0 0 rg (from rgb_to_pdf)
    ok('red colour in stream', INSTR(l_txt, '1 0 0 rg') > 0);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 5. rect emits q...re...Q block
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_blob BLOB;
    l_txt  VARCHAR2(200);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);

    rad_pdf_canvas.rect(l_doc, 72, 600, 200, 50, '000000', 'e0e0e0', 1, 'pt');
    rad_pdf_serial.page_flush(l_doc);
    l_blob := rad_pdf_serial.get_page_blob(l_doc, 0);
    l_txt  := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_blob, 300, 1));

    ok('rect emits q',  INSTR(l_txt, 'q') > 0);
    ok('rect emits re', INSTR(l_txt, ' re') > 0);
    ok('rect emits B',  INSTR(l_txt, CHR(10) || 'B' || CHR(10)) > 0
                     OR INSTR(l_txt, CHR(10) || 'B') > 0);
    ok('rect emits Q',  INSTR(l_txt, 'Q') > 0);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 6. h_line and v_line emit line operators
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_blob BLOB;
    l_txt  VARCHAR2(300);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);

    rad_pdf_canvas.h_line(l_doc, 72, 720, 400, 1, '000000', 'pt');
    rad_pdf_canvas.v_line(l_doc, 72, 720,  50, 1, '000000', 'pt');
    rad_pdf_serial.page_flush(l_doc);
    l_blob := rad_pdf_serial.get_page_blob(l_doc, 0);
    l_txt  := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_blob, 400, 1));

    ok('h_line emits m', INSTR(l_txt, ' m') > 0);
    ok('lines emit S',   INSTR(l_txt, CHR(10) || 'S') > 0);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 7. write_wrapped - wraps text into multiple lines (cursor moves down)
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_y0   NUMBER;
    l_y1   NUMBER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 10);

    l_y0 := rad_pdf_canvas.get_y(l_doc);

    -- A very long string forces at least two lines within 100pt width
    rad_pdf_canvas.write_wrapped(l_doc,
      'The quick brown fox jumps over the lazy dog. ' ||
      'Pack my box with five dozen liquor jugs.',
      72, l_y0, 150, 'L', 'pt');

    l_y1 := rad_pdf_canvas.get_y(l_doc);

    ok('write_wrapped moves cursor down', l_y1 < l_y0);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 8. add_page_proc + run_page_procs - token substitution
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_blob BLOB;
    l_txt  VARCHAR2(500);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 10);
    rad_pdf_canvas.write_text(l_doc, 'Content', 72, 700);

    rad_pdf_canvas.add_page_proc(l_doc,
      'BEGIN'                                                          || CHR(10) ||
      '  rad_pdf_canvas.set_font(#DOC_HANDLE#, ''helvetica'', ''N'', 8);' || CHR(10) ||
      '  rad_pdf_canvas.write_text(#DOC_HANDLE#,'                         || CHR(10) ||
      '    ''Pg #PAGE_NR#/#PAGE_COUNT#'', 72, 30);'                   || CHR(10) ||
      'END;');

    -- run_page_procs adds the footer to each page
    rad_pdf_canvas.run_page_procs(l_doc, rad_pdf_serial.page_count(l_doc));

    l_blob := rad_pdf_serial.get_page_blob(l_doc, 0);
    l_txt  := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_blob, 500, 1));

    ok('page_proc content in page blob', DBMS_LOB.GETLENGTH(l_blob) > 0);
    ok('multiple BT in page (content + proc)',
       (LENGTH(l_txt) - LENGTH(REPLACE(l_txt, 'BT', ''))) / 2 >= 2);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 9. write_page_objects returns a positive obj number
  -- =========================================================================
  DECLARE
    l_doc      rad_pdf_types.t_doc_handle;
    l_font_res VARCHAR2(32767);
    l_img_res  VARCHAR2(32767);
    l_pages    NUMBER;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 12);
    rad_pdf_canvas.write_text(l_doc, 'Hello PDF', 72, 700);
    rad_pdf_fonts.mark_font_used(l_doc, 1);

    rad_pdf_canvas.run_page_procs(l_doc, rad_pdf_serial.page_count(l_doc));
    l_font_res := rad_pdf_fonts.write_font_objects(l_doc);
    l_img_res  := rad_pdf_images.write_image_objects(l_doc);
    l_pages    := rad_pdf_canvas.write_page_objects(l_doc, l_font_res, l_img_res);

    ok('write_page_objects returns > 0', l_pages > 0);
    ok('font resource non-null', l_font_res IS NOT NULL);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 10. Two-page document: page_count = 2, both get page-proc footer
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_b0   BLOB;
    l_b1   BLOB;
    l_t0   VARCHAR2(500);
    l_t1   VARCHAR2(500);
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_fonts.load_standard_fonts;

    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 14);
    rad_pdf_canvas.write_text(l_doc, 'Page One', 72, 700);

    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.write_text(l_doc, 'Page Two', 72, 700);

    ok('two-page count = 2', rad_pdf_serial.page_count(l_doc), 2);

    rad_pdf_canvas.add_page_proc(l_doc,
      'BEGIN rad_pdf_canvas.write_text(#DOC_HANDLE#,''footer'',72,30); END;');
    rad_pdf_canvas.run_page_procs(l_doc, 2);

    l_b0 := rad_pdf_serial.get_page_blob(l_doc, 0);
    l_b1 := rad_pdf_serial.get_page_blob(l_doc, 1);
    l_t0 := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_b0, 400, 1));
    l_t1 := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_b1, 400, 1));

    ok('page 0 has footer', INSTR(l_t0, 'BT') > 0);
    ok('page 1 has footer', INSTR(l_t1, 'BT') > 0);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 11. _close_doc frees state; subsequent get_info returns NULL
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_raised BOOLEAN := FALSE;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);

    -- Normal close
    rad_pdf_ctx.close_doc(l_doc);
    ok('handle invalid after close_doc', NOT rad_pdf_ctx.is_valid(l_doc));
  END;

  -- =========================================================================
  -- 12. set_page_format and set_margins affect get_info
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_fmt rad_pdf_types.t_page_format;
    l_mar rad_pdf_types.t_margins;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);

    l_fmt.width  := 841.890;  -- A4 landscape width
    l_fmt.height := 595.276;
    rad_pdf_canvas.set_page_format(l_doc, l_fmt);
    ok('set_page_format width = 841',
       rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_page_width) = 841.890);

    l_mar.top    := 56.693;  -- ~2cm
    l_mar.left   := 56.693;
    l_mar.bottom := 56.693;
    l_mar.right  := 56.693;
    rad_pdf_canvas.set_margins(l_doc, l_mar);
    ok('set_margins top = 56.693',
       rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_margin_top) = 56.693);

    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 6: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 6 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
