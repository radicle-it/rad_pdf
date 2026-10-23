-- Regression tests for layout, LOB ownership, limits, encoding and image cache.
-- Run after src/install.sql: @tests/phase18_robustness.sql
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_other rad_pdf_types.t_doc_handle;
  l_src CLOB;
  l_pdf BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  l_opts rad_pdf_types.t_template_options;
  l_binds rad_pdf_types.t_bind_array;
  l_tpl rad_pdf_types.t_page_template;
  l_rc SYS_REFCURSOR;
  l_img PLS_INTEGER;
  l_other_img PLS_INTEGER;
  l_count PLS_INTEGER;
  l_len PLS_INTEGER;
  l_idx PLS_INTEGER;
  l_pass PLS_INTEGER := 0;
  l_width NUMBER;
  l_png BLOB := TO_BLOB(HEXTORAW(
    '89504E470D0A1A0A0000000D4948445200000008000000080806000000C40FBE8B0000'
    ||'00124944415478DA63382127D7800F338C0C050022F66101C6FEADF20000000049454E'
    ||'44AE426082'));
  l_gif BLOB := TO_BLOB(HEXTORAW(
    '47494638396101000100800000000000FFFFFF21F90401000000002C00000000010001000002024401003B'));

  PROCEDURE assert_ok(p_ok BOOLEAN,p_message VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_ok,FALSE) THEN RAISE_APPLICATION_ERROR(-20999,p_message); END IF;
    l_pass := l_pass+1;
    DBMS_OUTPUT.PUT_LINE('PASS  '||p_message);
  END;
  FUNCTION has(p_page PLS_INTEGER,p_text VARCHAR2) RETURN BOOLEAN IS
    l_page BLOB;
  BEGIN
    l_page := rad_pdf_serial.get_page_blob(l_doc,p_page);
    RETURN DBMS_LOB.INSTR(l_page,UTL_RAW.CAST_TO_RAW(p_text))>0;
  END;
  PROCEDURE tiny_document IS
  BEGIN
    l_tpl.page_width := 300; l_tpl.page_height := 200;
    l_tpl.margin_top := 20; l_tpl.margin_bottom := 20;
    l_tpl.margin_left := 20; l_tpl.margin_right := 20;
    l_tpl.footer_proc := 'BEGIN rad_pdf_canvas.write_text(#DOC_HANDLE#,'
      ||'''FOOTER #PAGE_NR#/#PAGE_COUNT#'',20,5); END;';
    l_doc := rad_pdf.new_document(p_template=>l_tpl);
  END;
  PROCEDURE check_footers IS
  BEGIN
    l_count := rad_pdf_serial.page_count(l_doc);
    FOR pg IN 0..l_count-1 LOOP
      assert_ok(has(pg,'FOOTER '||(pg+1)||'/'||l_count),'correct footer on page '||(pg+1));
    END LOOP;
  END;
BEGIN
  rad_pdf_styles.load_defaults;
  l_cols.EXTEND(1);
  l_cols(1).label := 'Header'; l_cols(1).width := 260;
  rad_pdf_template.register_columns('ROBUSTNESS',l_cols);

  -- Every character is retained, all pages receive the actual page count,
  -- and temporary input remains usable after repeated render calls.
  DBMS_LOB.CREATETEMPORARY(l_src,TRUE);
  DBMS_LOB.WRITEAPPEND(l_src,3,'<P>');
  FOR i IN 1..1800 LOOP
    DBMS_LOB.WRITEAPPEND(l_src,24,'Complete paragraph text. ');
  END LOOP;
  DBMS_LOB.WRITEAPPEND(l_src,15,'TAIL_MARKER</P>');
  l_len := DBMS_LOB.GETLENGTH(l_src);
  tiny_document;
  rad_pdf_template.render(l_doc,l_src);
  assert_ok(DBMS_LOB.GETLENGTH(l_src)=l_len,'render retains caller-owned temporary CLOB');
  rad_pdf_layout.render(l_doc);
  l_count := rad_pdf_serial.page_count(l_doc);
  assert_ok(l_count>1,'long paragraph spans pages');
  assert_ok(has(l_count-1,'TAIL_MARKER'),'long paragraph retains final marker');
  check_footers;
  rad_pdf.close_document(l_doc);
  DBMS_LOB.FREETEMPORARY(l_src);

  -- Regression: after wrapping, the next word must not reset accumulated width.
  tiny_document;
  DECLARE
    l_fmt rad_pdf_types.t_page_format;
    l_page BLOB;
    l_content VARCHAR2(32767);
    l_line VARCHAR2(4000);
    l_occ PLS_INTEGER;
  BEGIN
    l_tpl.page_width := 90;
    rad_pdf_layout.set_template(l_doc,l_tpl);
    rad_pdf.write(l_doc,'ABCD EFGH IJKL MNOP QRST UVWX YZAB CDEF GHIJ KLMN');
    rad_pdf_layout.render(l_doc);
    FOR pg IN 0..rad_pdf_serial.page_count(l_doc)-1 LOOP
      l_page := rad_pdf_serial.get_page_blob(l_doc,pg);
      l_content := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_page,32767,1));
      l_occ := 1;
      LOOP
        l_line := REGEXP_SUBSTR(l_content,'\(([^()]*)\) Tj',1,l_occ,NULL,1);
        EXIT WHEN l_line IS NULL;
        IF l_line NOT LIKE 'FOOTER %' THEN
          assert_ok(rad_pdf_canvas.text_width(l_doc,l_line)<=50,
                    'wrapped line stays inside the content width: '||l_line);
        END IF;
        l_occ := l_occ+1;
      END LOOP;
    END LOOP;
  END;
  rad_pdf.close_document(l_doc);

  tiny_document;
  rad_pdf.spacer(l_doc,128);
  rad_pdf.heading(l_doc,'TITLE',1);
  rad_pdf.write(l_doc,'FIRST_DETAIL');
  rad_pdf_layout.render(l_doc);
  assert_ok(rad_pdf_serial.page_count(l_doc)=2 AND has(1,'TITLE') AND has(1,'FIRST_DETAIL'),
            'heading stays with the following text line');
  rad_pdf.close_document(l_doc);

  -- SQL and refcursor sources must leave the same final position/page count.
  FOR source_kind IN 1..2 LOOP
    tiny_document;
    IF source_kind=1 THEN
      rad_pdf.query2table(l_doc,'select ''DATA_''||level from dual connect by level<=36',l_cols);
    ELSE
      OPEN l_rc FOR SELECT 'DATA_'||LEVEL FROM dual CONNECT BY LEVEL<=36;
      rad_pdf.refcursor2table(l_doc,l_rc,l_cols);
    END IF;
    rad_pdf.write(l_doc,'AFTER_TABLE');
    rad_pdf_layout.render(l_doc);
    l_count := rad_pdf_serial.page_count(l_doc);
    assert_ok(l_count=4,'table uses four pages, source '||source_kind);
    assert_ok(has(l_count-1,'DATA_36') AND has(l_count-1,'AFTER_TABLE'),
          'paragraph follows final table row, source '||source_kind);
    check_footers;
    rad_pdf.close_document(l_doc);
  END LOOP;

  -- Template cap cannot be raised by a tag. Mixed-case tags and real SQL binds.
  tiny_document;
  l_opts.allow_queries := TRUE; l_opts.max_rows := 2;
  l_binds(1).key := 'FILTER'; l_binds(1).value := 'O''Reilly';
  rad_pdf_template.render(l_doc,
    '<TaBlE columns="ROBUSTNESS" query="select ''ROW_LIMIT_''||level from dual '
    ||'where #FILTER# = #FILTER# connect by level<=5" max_rows="50" allow_query="true"/>',
    l_binds,l_opts);
  rad_pdf_layout.render(l_doc);
  assert_ok(has(0,'ROW_LIMIT_2') AND NOT has(0,'ROW_LIMIT_3'),'global row cap enforced over tag cap');
  rad_pdf.close_document(l_doc);

  -- Entity-encoded SQL identifiers remain quoted while tokens become SQL binds.
  tiny_document;
  l_opts.max_rows := 1;
  rad_pdf_template.render(l_doc,
    '<table columns="ROBUSTNESS" query="select #FILTER# as &quot;Display Name&quot; from dual"'
    ||' allow_query="true"/>',l_binds,l_opts);
  rad_pdf_layout.render(l_doc);
  assert_ok(has(0,'O''Reilly'),'SQL bind shielding preserves encoded identifier quotes');
  rad_pdf.close_document(l_doc);

  -- Attribute names must match exactly (line_width is not width).
  tiny_document;
  rad_pdf_template.render(l_doc,'<HR line_width="8pt"/>');
  rad_pdf_layout.render(l_doc);
  assert_ok(has(0,'0.5 w'),'attribute suffix does not match a shorter attribute name');
  rad_pdf.close_document(l_doc);

  -- Font encodings: WinAnsi euro/accent bytes and widths agree.
  l_doc := rad_pdf.new_document;
  l_idx := rad_pdf_fonts.find_font(l_doc,'Helvetica','N');
  assert_ok(rad_pdf_fonts.text_to_pdf_string(UNISTR('\00E8\20AC'),l_idx)='(\350\200)',
        'accent and euro encoded as WinAnsi bytes');
  l_width := rad_pdf_fonts.text_width(UNISTR('\00E8'),l_idx,10);
  assert_ok(l_width>0,'accent contributes to measured text width');
  rad_pdf.close_document(l_doc);

  -- Pinned images survive eviction and cache clearing, including another doc.
  rad_pdf_images.set_image_cache_limit(1);
  l_doc := rad_pdf.new_document;
  l_img := rad_pdf_images.load_image(l_doc,l_png);
  l_other := rad_pdf.new_document;
  l_other_img := rad_pdf_images.load_image(l_other,l_png);
  l_idx := rad_pdf_images.load_image(l_other,l_gif);
  rad_pdf_images.clear_image_cache;
  rad_pdf_canvas.put_image(l_doc,l_img,20,180,40,40);
  l_pdf := rad_pdf.finalize(l_doc);
  assert_ok(DBMS_LOB.INSTR(l_pdf,UTL_RAW.CAST_TO_RAW('/SMask'))>0,'pinned alpha PNG survives eviction');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  rad_pdf_canvas.put_image(l_other,l_other_img,20,180,40,40);
  l_pdf := rad_pdf.finalize(l_other);
  assert_ok(DBMS_LOB.INSTR(l_pdf,UTL_RAW.CAST_TO_RAW('/SMask'))>0,'second document reuses decoded alpha PNG');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  rad_pdf_images.set_image_cache_limit;
  rad_pdf_images.clear_image_cache;

  -- Exact fractional sizes and base-style revisions produce distinct variants.
  tiny_document;
  rad_pdf_template.render(l_doc,'<p><font size="10.1pt">SIZE_A</font> '
                                     ||'<font size="10.4pt">SIZE_B</font></p>');
  rad_pdf_styles.define('body',p_font_color=>'FF0000');
  rad_pdf_template.render(l_doc,'<p><font size="10.1pt">SIZE_C</font></p>');
  rad_pdf_layout.render(l_doc);
  assert_ok(has(0,'10.1 Tf') AND has(0,'10.4 Tf'),'fractional font sizes remain distinct');
  assert_ok(has(0,'1 0 0 rg'),'derived styles reflect updated base format');
  rad_pdf.close_document(l_doc);
  rad_pdf_styles.clear_all;
  rad_pdf_template.drop_columns('ROBUSTNESS');
  DBMS_OUTPUT.PUT_LINE('Phase 18: '||l_pass||' passed, 0 failed.');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN rad_pdf.close_document(l_other); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF DBMS_LOB.ISTEMPORARY(l_src)=1 THEN DBMS_LOB.FREETEMPORARY(l_src); END IF;
  IF DBMS_LOB.ISTEMPORARY(l_pdf)=1 THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  rad_pdf_images.set_image_cache_limit;
  rad_pdf_images.clear_image_cache;
  rad_pdf_styles.clear_all;
  rad_pdf_template.drop_columns('ROBUSTNESS');
  RAISE;
END;
/
