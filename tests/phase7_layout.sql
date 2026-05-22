-- phase7_layout.sql — acceptance tests for Phase 7 (rad_pdf_layout + rad_pdf_table)
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
  -- 1. paragraph flowable: flow_type = PARAGRAPH, text CLOB contains input
  -- =========================================================================
  DECLARE
    l_f   rad_pdf_types.t_flowable;
    l_txt VARCHAR2(100);
  BEGIN
    l_f   := rad_pdf_layout.paragraph('Hello world', 'body');
    l_txt := DBMS_LOB.SUBSTR(l_f.text, 100, 1);
    ok('paragraph flow_type = PARAGRAPH', l_f.flow_type, rad_pdf_types.c_flow_paragraph);
    ok('paragraph style_name = body',     l_f.style_name, 'body');
    ok('paragraph text matches',          l_txt, 'Hello world');
    DBMS_LOB.FREETEMPORARY(l_f.text);
  END;

  -- =========================================================================
  -- 2. heading flowable: flow_type = HEADING, level set, text preserved
  -- =========================================================================
  DECLARE
    l_f   rad_pdf_types.t_flowable;
    l_txt VARCHAR2(100);
  BEGIN
    l_f   := rad_pdf_layout.heading('My Report', 2);
    l_txt := DBMS_LOB.SUBSTR(l_f.text, 100, 1);
    ok('heading flow_type = HEADING', l_f.flow_type, rad_pdf_types.c_flow_heading);
    ok('heading level = 2',           l_f.level, 2);
    ok('heading text matches',        l_txt, 'My Report');
    DBMS_LOB.FREETEMPORARY(l_f.text);
  END;

  -- =========================================================================
  -- 3. spacer, h_rule, page_break constructors set flow_type correctly
  -- =========================================================================
  DECLARE
    l_sp rad_pdf_types.t_flowable;
    l_hr rad_pdf_types.t_flowable;
    l_pb rad_pdf_types.t_flowable;
  BEGIN
    l_sp := rad_pdf_layout.spacer(20);
    l_hr := rad_pdf_layout.h_rule('336699', 1);
    l_pb := rad_pdf_layout.page_break;
    ok('spacer flow_type = SPACER',        l_sp.flow_type, rad_pdf_types.c_flow_spacer);
    ok('spacer height = 20',               l_sp.spacer_h, 20);
    ok('h_rule flow_type = HLINE',         l_hr.flow_type, rad_pdf_types.c_flow_hline);
    ok('h_rule color in style_name',       l_hr.style_name, '336699');
    ok('h_rule width in img_width',        l_hr.img_width, 1);
    ok('page_break flow_type = PAGEBREAK', l_pb.flow_type, rad_pdf_types.c_flow_pagebreak);
  END;

  -- =========================================================================
  -- 4. add() accumulates flowables; has_flowables returns TRUE
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    ok('has_flowables FALSE before add', NOT rad_pdf_layout.has_flowables(l_doc));
    rad_pdf_layout.add(l_doc, rad_pdf_layout.paragraph('First'));
    rad_pdf_layout.add(l_doc, rad_pdf_layout.paragraph('Second'));
    ok('has_flowables TRUE after add', rad_pdf_layout.has_flowables(l_doc));
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 5. set_template stores template values
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_tpl  rad_pdf_types.t_page_template;
  BEGIN
    l_doc            := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    l_tpl.margin_top := 56.693;
    l_tpl.margin_left := 42.520;
    -- set_template should not raise
    rad_pdf_layout.set_template(l_doc, l_tpl);
    ok('set_template no exception', TRUE);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 6. register_table + get_table_def round-trip
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_def  rad_pdf_types.t_table_def;
    l_ref  PLS_INTEGER;
    l_got  rad_pdf_types.t_table_def;
  BEGIN
    l_doc          := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    l_def.query_txt := 'SELECT 1 FROM DUAL';
    l_ref := rad_pdf_layout.register_table(l_doc, l_def);
    l_got := rad_pdf_layout.get_table_def(l_doc, l_ref);
    ok('register_table returns positive ref', l_ref >= 1);
    ok('get_table_def round-trip query_txt',  l_got.query_txt, 'SELECT 1 FROM DUAL');
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 7. render with paragraphs only: no exception, page_count >= 1
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    rad_pdf_fonts.load_standard_fonts;
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 12);
    rad_pdf_layout.add(l_doc, rad_pdf_layout.paragraph('Hello world'));
    rad_pdf_layout.render(l_doc);
    ok('render paragraphs: page_count >= 1', rad_pdf_serial.page_count(l_doc) >= 1);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 8. explicit page_break causes two pages
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    rad_pdf_fonts.load_standard_fonts;
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 12);
    rad_pdf_layout.add(l_doc, rad_pdf_layout.paragraph('Page one content'));
    rad_pdf_layout.add(l_doc, rad_pdf_layout.page_break);
    rad_pdf_layout.add(l_doc, rad_pdf_layout.paragraph('Page two content'));
    rad_pdf_layout.render(l_doc);
    ok('page_break causes page_count = 2', rad_pdf_serial.page_count(l_doc), 2);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 9. render with heading + paragraph: page stream contains BT operator
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_blob BLOB;
    l_txt  VARCHAR2(500);
  BEGIN
    rad_pdf_fonts.load_standard_fonts;
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 12);
    rad_pdf_layout.add(l_doc, rad_pdf_layout.heading('Section Title', 1));
    rad_pdf_layout.add(l_doc, rad_pdf_layout.paragraph('Body text for section.'));
    rad_pdf_layout.render(l_doc);
    rad_pdf_serial.page_flush(l_doc);
    l_blob := rad_pdf_serial.get_page_blob(l_doc, 0);
    l_txt  := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_blob, 500, 1));
    ok('heading+paragraph stream contains BT', INSTR(l_txt, 'BT') > 0);
    rad_pdf_ctx.close_doc(l_doc);
  END;

  -- =========================================================================
  -- 10. close_doc cleans up: handle invalid after rad_pdf_ctx.close_doc
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    rad_pdf_fonts.load_standard_fonts;
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf_ctx.new_doc;
    rad_pdf_serial.init_doc(l_doc);
    rad_pdf_canvas.new_page(l_doc);
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'N', 12);
    rad_pdf_layout.add(l_doc, rad_pdf_layout.paragraph('Cleanup test'));
    rad_pdf_layout.render(l_doc);
    rad_pdf_ctx.close_doc(l_doc);
    ok('handle invalid after close_doc', NOT rad_pdf_ctx.is_valid(l_doc));
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 7: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 7 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
