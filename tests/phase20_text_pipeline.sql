-- Prepared text, byte offsets, stream borrowing and transferred output ownership.
SET DEFINE OFF
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_style rad_pdf_text.t_style;
  l_plan rad_pdf_text.t_plan;
  l_fmt rad_pdf_types.t_cell_format;
  l_runs rad_pdf_types.t_inline_run_list;
  l_src CLOB;
  l_blob BLOB;
  l_copy BLOB;
  l_raw BLOB;
  l_n NUMBER;
  l_pos NUMBER;
  l_text VARCHAR2(32767);
  l_saved VARCHAR2(32767);
  l_pass PLS_INTEGER := 0;
  PROCEDURE ok(p_value BOOLEAN,p_message VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_value,FALSE) THEN RAISE_APPLICATION_ERROR(-20999,p_message); END IF;
    l_pass := l_pass+1; DBMS_OUTPUT.PUT_LINE('PASS  '||p_message);
  END;
  FUNCTION plan_text RETURN VARCHAR2 IS
    l_result VARCHAR2(32767);
  BEGIN
    FOR i IN 1..l_plan.fragments.COUNT LOOP l_result := l_result||l_plan.fragments(i).text; END LOOP;
    RETURN l_result;
  END;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_fmt := rad_pdf_styles.get('body');
  l_style := rad_pdf_text.prepare_style(l_doc,l_fmt);
  l_plan := rad_pdf_text.prepare_varchar(NULL,l_style,100);
  ok(l_plan.lines.COUNT=0 AND l_plan.height=0,'empty plan has zero height');
  l_plan := rad_pdf_text.prepare_varchar('first'||CHR(13)||CHR(10)||'second'||CHR(13)||'third'||CHR(10)||'fourth',l_style,200);
  ok(l_plan.lines.COUNT=4,'CRLF, CR and LF produce one break each');
  ok(l_plan.height=4*l_style.leading,'measurement uses planned line heights');
  l_plan := rad_pdf_text.prepare_varchar('first'||CHR(10)||CHR(10)||'last',l_style,200);
  ok(l_plan.lines.COUNT=3,'blank line is retained');
  ok(l_plan.lines(2).last_fragment<l_plan.lines(2).first_fragment,'blank line contains no glyphs');
  l_plan := rad_pdf_text.prepare_varchar(RPAD('W',300,'W'),l_style,40);
  ok(l_plan.lines.COUNT>1 AND LENGTH(plan_text)=300,'overlong word splits without lost glyphs');
  FOR i IN 1..l_plan.lines.COUNT LOOP
    ok(l_plan.lines(i).width<=40,'planned line fits its width '||i);
  END LOOP;
  l_plan := rad_pdf_text.prepare_varchar('one two three four five six seven eight nine',l_style,90,'J');
  ok(NOT l_plan.lines(1).terminal AND l_plan.lines(1).gaps>0,'natural wrap can be justified');
  ok(l_plan.lines(l_plan.lines.COUNT).terminal,'final line is not justified');
  BEGIN
    l_plan := rad_pdf_text.prepare_varchar('X',l_style,0);
    ok(FALSE,'zero width rejected');
  EXCEPTION WHEN OTHERS THEN ok(SQLCODE=rad_pdf_types.c_err_layout,'zero width rejected'); END;
  BEGIN
    l_plan := rad_pdf_text.prepare_varchar('W',l_style,0.1);
    ok(FALSE,'oversize glyph rejected');
  EXCEPTION WHEN OTHERS THEN ok(SQLCODE=rad_pdf_types.c_err_layout,'oversize glyph rejected'); END;
  DBMS_LOB.CREATETEMPORARY(l_src,TRUE);
  l_text := RPAD('A',8190,'A')||'XY'||RPAD('B',4200,'B')||UNISTR('\00E8')||'TAIL';
  DBMS_LOB.WRITEAPPEND(l_src,LENGTH(l_text),l_text);
  l_plan := rad_pdf_text.prepare(l_doc,l_src,'body',180);
  ok(plan_text=l_text,'CLOB chunk and fragment boundaries preserve every character');
  ok(DBMS_LOB.GETLENGTH(l_src)=LENGTH(l_text),'preparation leaves input CLOB intact');
  DBMS_LOB.FREETEMPORARY(l_src);
  l_text := RPAD('a',17000,'a')||'(';
  l_saved := rad_pdf_fonts.text_to_pdf_string(l_text,l_style.font_idx);
  ok(LENGTH(l_saved)=17004,'long escaped text avoids RAWTOHEX overflow');
  ok(SUBSTR(l_saved,-3)=CHR(92)||'()', 'long PDF string escapes its final parenthesis');
  rad_pdf.close_document(l_doc);

  -- Byte-counted writes, including values too large for buffered concatenation.
  l_doc := rad_pdf.new_document(p_compress_pages=>FALSE);
  l_text := RPAD(UNISTR('\00E8'),15000,UNISTR('\00E8'));
  rad_pdf_serial.page_write(l_doc,l_text);
  rad_pdf_serial.page_write(l_doc,RPAD('Z',32767,'Z'));
  rad_pdf_serial.page_flush(l_doc);
  l_blob := rad_pdf_serial.get_page_blob(l_doc,0);
  ok(DBMS_LOB.GETLENGTH(l_blob)=LENGTHB(l_text)+1+32767+1,'page buffer counts bytes and accepts 32767-byte writes');
  rad_pdf.close_document(l_doc);

  -- Borrowed stream remains alive; snapshots flush but never steal ownership.
  l_doc := rad_pdf.new_document;
  DBMS_LOB.CREATETEMPORARY(l_raw,TRUE);
  DBMS_LOB.WRITEAPPEND(l_raw,7,UTL_RAW.CAST_TO_RAW('payload'));
  l_n := rad_pdf_serial.write_stream_obj(l_doc,l_raw,NULL,FALSE);
  ok(DBMS_LOB.GETLENGTH(l_raw)=7,'uncompressed stream borrows the source');
  l_copy := rad_pdf_serial.get_doc_copy(l_doc);
  l_saved := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(l_copy,32767,1));
  ok(INSTR(l_saved,'payload')>0,'snapshot includes pending buffered writes');
  DBMS_LOB.FREETEMPORARY(l_copy);
  rad_pdf_serial.doc_write(l_doc,'next');
  l_copy := rad_pdf_serial.get_doc_copy(l_doc);
  ok(DBMS_LOB.GETLENGTH(l_copy)>LENGTHB(l_saved),'snapshot does not detach the writer');
  DBMS_LOB.FREETEMPORARY(l_copy);
  DBMS_LOB.FREETEMPORARY(l_raw);
  rad_pdf.close_document(l_doc);

  -- Both output modes remain valid after finalize closes the handle.
  FOR compression_mode IN 0..1 LOOP
    l_doc := rad_pdf.new_document(p_compress_pages=>compression_mode=1);
    FOR i IN 1..150 LOOP rad_pdf_canvas.write_text(l_doc,'compressible repeated text',20,100); END LOOP;
    l_blob := rad_pdf.finalize(l_doc);
    ok(DBMS_LOB.ISTEMPORARY(l_blob)=1,'finalized BLOB survives closing document compression_mode '||compression_mode);
    ok(DBMS_LOB.INSTR(l_blob,UTL_RAW.CAST_TO_RAW('%%EOF'))>0,'finalization flushes EOF compression_mode '||compression_mode);
    l_n := DBMS_LOB.INSTR(l_blob,UTL_RAW.CAST_TO_RAW('/FlateDecode'));
    ok((compression_mode=1 AND l_n>0) OR (compression_mode=0 AND l_n=0),'page compression setting compression_mode '||compression_mode);
    IF compression_mode=0 THEN l_pos := DBMS_LOB.GETLENGTH(l_blob);
    ELSE ok(DBMS_LOB.GETLENGTH(l_blob)<l_pos/2,'compression reduces repeated content by more than half'); END IF;
    DBMS_LOB.FREETEMPORARY(l_blob);
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('Phase 20: '||l_pass||' assertions passed');
END;
/
