-- Reproducible rendering workloads. Compare CPU separately from cloud wait time.
-- PERF|workload|iteration|elapsed_cs|cpu_cs|pdf_bytes
SET DEFINE OFF
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
  l_text CLOB;
  l_cols rad_pdf_types.t_columns;
  l_template CLOB;
  l_start NUMBER;
  l_cpu NUMBER;
  l_bytes NUMBER;
  l_chunk VARCHAR2(4000) := RPAD('Complete paragraph text with accents '||UNISTR('\00E8\00E9')||'. ',3900,'Repeat words for reliable layout. ');
  PROCEDURE begin_case IS
  BEGIN
    l_bytes := 0;
    l_start := DBMS_UTILITY.GET_TIME;
    l_cpu := DBMS_UTILITY.GET_CPU_TIME;
  END;
  PROCEDURE finish_case(p_name VARCHAR2,p_iteration PLS_INTEGER) IS
  BEGIN
    IF l_bytes<=0 THEN RAISE_APPLICATION_ERROR(-20999,'Empty benchmark PDF'); END IF;
    DBMS_OUTPUT.PUT_LINE('PERF|'||p_name||'|'||p_iteration||'|'
      ||(DBMS_UTILITY.GET_TIME-l_start)||'|'||(DBMS_UTILITY.GET_CPU_TIME-l_cpu)||'|'||l_bytes);
  END;
  PROCEDURE collect_pdf IS
  BEGIN
    l_pdf := rad_pdf.finalize(l_doc);
    IF DBMS_LOB.SUBSTR(l_pdf,4,1)!=UTL_RAW.CAST_TO_RAW('%PDF') THEN
      RAISE_APPLICATION_ERROR(-20999,'Invalid benchmark PDF');
    END IF;
    l_bytes := l_bytes+DBMS_LOB.GETLENGTH(l_pdf);
    DBMS_LOB.FREETEMPORARY(l_pdf);
  END;
BEGIN
  rad_pdf_styles.load_defaults;
  DBMS_LOB.CREATETEMPORARY(l_text,TRUE);
  FOR i IN 1..40 LOOP DBMS_LOB.WRITEAPPEND(l_text,LENGTH(l_chunk),l_chunk); END LOOP;
  DBMS_LOB.WRITEAPPEND(l_text,12,' TAIL_MARKER');
  DBMS_LOB.CREATETEMPORARY(l_template,TRUE);
  FOR i IN 1..200 LOOP
    l_chunk := '<p>Normal <b>bold words</b> and <color rgb="003366">blue text</color> '
      ||'<font size="13pt">larger text</font> repeated for measurement.</p>';
    DBMS_LOB.WRITEAPPEND(l_template,LENGTH(l_chunk),l_chunk);
  END LOOP;
  FOR iteration IN 1..3 LOOP
    begin_case;
    l_doc := rad_pdf.new_document;
    rad_pdf.add(l_doc,rad_pdf_layout.paragraph(l_text));
    collect_pdf;
    finish_case('clob_156k',iteration);

    begin_case;
    l_doc := rad_pdf.new_document;
    rad_pdf_template.render(l_doc,l_template);
    collect_pdf;
    finish_case('mixed_200',iteration);

    l_cols := rad_pdf_types.t_columns(); l_cols.EXTEND(4);
    FOR c IN 1..4 LOOP l_cols(c).label := 'Column '||c; l_cols(c).width := 100; END LOOP;
    begin_case;
    l_doc := rad_pdf.new_document;
    rad_pdf.query2table(l_doc,
      'select level, ''Item ''||level, round(level*1.25,2), ''Group ''||mod(level,10) from dual connect by level<=5000',l_cols);
    collect_pdf;
    finish_case('table_5000x4',iteration);

    l_cols := rad_pdf_types.t_columns(); l_cols.EXTEND(2);
    l_cols(1).label := 'ID'; l_cols(1).width := 60;
    l_cols(2).label := 'Description'; l_cols(2).width := 240; l_cols(2).wrap := TRUE;
    begin_case;
    l_doc := rad_pdf.new_document;
    rad_pdf.query2table(l_doc,
      'select level, ''Description ''||level||'' with several words repeated to wrap across multiple lines in the table cell.'' from dual connect by level<=1000',l_cols);
    collect_pdf;
    finish_case('wrapped_1000',iteration);

    begin_case;
    FOR d IN 1..50 LOOP
      l_doc := rad_pdf.new_document;
      rad_pdf.heading(l_doc,'Invoice '||d);
      rad_pdf.write(l_doc,'Small documents repeated in one session with deterministic cleanup.');
      collect_pdf;
    END LOOP;
    finish_case('batch_50',iteration);
  END LOOP;
  DBMS_LOB.FREETEMPORARY(l_text);
  DBMS_LOB.FREETEMPORARY(l_template);
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  IF DBMS_LOB.ISTEMPORARY(l_pdf)=1 THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
  IF DBMS_LOB.ISTEMPORARY(l_text)=1 THEN DBMS_LOB.FREETEMPORARY(l_text); END IF;
  IF DBMS_LOB.ISTEMPORARY(l_template)=1 THEN DBMS_LOB.FREETEMPORARY(l_template); END IF;
  RAISE;
END;
/
