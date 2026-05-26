-- phase8_pdf.sql - acceptance tests for Phase 8 (rad_pdf facade)
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
  -- 1. new_document returns a valid handle
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;
    ok('new_document returns valid handle', rad_pdf_ctx.is_valid(l_doc));
    rad_pdf.close_document(l_doc);
    ok('handle invalid after close_document', NOT rad_pdf_ctx.is_valid(l_doc));
  END;

  -- =========================================================================
  -- 2. finalize returns a BLOB that starts with %PDF
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
    l_hdr VARCHAR2(10);
  BEGIN
    l_doc := rad_pdf.new_document;
    l_pdf := rad_pdf.finalize(l_doc);
    l_hdr := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 5, 1));
    ok('finalize returns non-empty BLOB',   DBMS_LOB.GETLENGTH(l_pdf) > 100);
    ok('PDF starts with %PDF',              SUBSTR(l_hdr, 1, 4), '%PDF');
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 3. write + finalize: page stream contains BT operator
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
    l_txt VARCHAR2(500);
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;
    rad_pdf.write(l_doc, 'Hello world', 'body');
    l_pdf := rad_pdf.finalize(l_doc);
    -- Search the PDF body for BT (text begin operator)
    l_txt := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 500, 1));
    ok('write+finalize: BLOB length > 500',  DBMS_LOB.GETLENGTH(l_pdf) > 500);
    ok('write+finalize: PDF contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 4. heading + write: both contribute to PDF body
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;
    rad_pdf.heading(l_doc, 'Chapter 1', 1);
    rad_pdf.write(l_doc, 'Introduction text.');
    l_pdf := rad_pdf.finalize(l_doc);
    ok('heading+write: BLOB > 600', DBMS_LOB.GETLENGTH(l_pdf) > 600);
    ok('heading+write: contains BT',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('BT')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 5. new_page in layout mode produces two-page document
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;
    rad_pdf.write(l_doc, 'Page one.');
    rad_pdf.new_page(l_doc);
    rad_pdf.write(l_doc, 'Page two.');
    l_pdf := rad_pdf.finalize(l_doc);
    -- PDF with two pages has two Page objects: look for two /Type /Page dicts
    ok('two-page PDF: BLOB > 800', DBMS_LOB.GETLENGTH(l_pdf) > 800);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 6. spacer adds a flowable (finalize still works)
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_doc := rad_pdf.new_document;
    rad_pdf.write(l_doc, 'Before spacer.');
    rad_pdf.spacer(l_doc, 24);
    rad_pdf.write(l_doc, 'After spacer.');
    l_pdf := rad_pdf.finalize(l_doc);
    ok('spacer+write finalize succeeds', DBMS_LOB.GETLENGTH(l_pdf) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 7. set_page_format by name ('A4') does not raise an exception
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    l_doc := rad_pdf.new_document;
    rad_pdf.set_page_format(l_doc, 'A4');
    l_pdf := rad_pdf.finalize(l_doc);
    ok('set_page_format A4 no exception', DBMS_LOB.GETLENGTH(l_pdf) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 8. set_margins affects canvas margin state
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    l_doc := rad_pdf.new_document;
    rad_pdf.set_margins(l_doc, p_top => 56.693, p_bottom => 56.693,
                           p_left => 42.520, p_right  => 42.520);
    ok('set_margins: top applied',
       rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_margin_top) = 56.693);
    ok('set_margins: left applied',
       rad_pdf_canvas.get_info(l_doc, rad_pdf_types.c_info_margin_left) = 42.520);
    l_pdf := rad_pdf.finalize(l_doc);
    ok('set_margins + finalize succeeds', DBMS_LOB.GETLENGTH(l_pdf) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 9. new_document with doc info: finalize embeds metadata
  -- =========================================================================
  DECLARE
    l_doc  rad_pdf_types.t_doc_handle;
    l_info rad_pdf_types.t_doc_info;
    l_pdf  BLOB;
  BEGIN
    rad_pdf_styles.load_defaults;
    l_info.title  := 'Test Report';
    l_info.author := 'Radicle S.r.l.';
    l_doc := rad_pdf.new_document(p_info => l_info);
    rad_pdf.write(l_doc, 'Content here.');
    l_pdf := rad_pdf.finalize(l_doc);
    ok('doc info finalize: PDF > 500', DBMS_LOB.GETLENGTH(l_pdf) > 500);
    ok('doc info finalize: contains /Title',
       DBMS_LOB.INSTR(l_pdf, UTL_RAW.CAST_TO_RAW('/Title')) > 0);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- 10. canvas-only document (no layout calls): finalize succeeds
  -- =========================================================================
  DECLARE
    l_doc rad_pdf_types.t_doc_handle;
    l_pdf BLOB;
  BEGIN
    l_doc := rad_pdf.new_document;
    -- Direct canvas calls (bypass layout engine)
    rad_pdf_canvas.set_font(l_doc, 'helvetica', 'B', 16);
    rad_pdf_canvas.write_text(l_doc, 'Direct canvas text', 72, 700, 'pt');
    l_pdf := rad_pdf.finalize(l_doc);
    ok('canvas-only finalize: PDF > 500', DBMS_LOB.GETLENGTH(l_pdf) > 500);
    ok('canvas-only finalize: starts with %PDF',
       UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_pdf, 4, 1)) = '%PDF');
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;

  -- =========================================================================
  -- Summary
  -- =========================================================================
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Phase 8: ' || l_ok || ' passed, ' || l_fail || ' failed.');
  IF l_fail > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'Phase 8 FAILED: ' || l_fail || ' failure(s)');
  END IF;
END;
/
