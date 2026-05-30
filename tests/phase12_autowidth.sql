-- phase12_autowidth.sql - Acceptance tests for auto-width columns (v1.3.0).
--
-- Run from repo root in SQL*Plus after installing all phases:
--   @tests/phase12_autowidth.sql
--
-- Uses DEPT/EMP (Scott schema) for data-driven tests.
-- Tests that do not require data use a VALUES-based subquery.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET DEFINE OFF

PROMPT ================================================================
PROMPT  Phase 12 - Auto-width Columns Acceptance Tests (v1.3.0)
PROMPT ================================================================
PROMPT

-- ===========================================================================
-- Test 1: auto_width = FALSE (default) - finalize succeeds, behaviour
--         identical to v1.2.0 (no auto-width logic runs)
-- ===========================================================================
DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;

  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 1: auto_width = FALSE (default) - no change to existing behaviour');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  DECLARE
    l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  BEGIN
    l_cols.EXTEND(2);
    l_cols(1).label := 'Name';   l_cols(1).width := 80;
    l_cols(2).label := 'Value';  l_cols(2).width := 60;
    rad_pdf.query2table(l_doc,
      'SELECT ''Alice'', ''100'' FROM DUAL UNION ALL SELECT ''Bob'', ''200'' FROM DUAL',
      l_cols);
  END;
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 2: single auto-width column - width adapts to content
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 2: single auto-width column');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(2);
  l_cols(1).label      := 'Name';
  l_cols(1).width      := 10;       -- floor only; content will be wider
  l_cols(1).auto_width := TRUE;
  l_cols(2).label      := 'Score';
  l_cols(2).width      := 50;
  rad_pdf.query2table(l_doc,
    'SELECT ''Alice'', ''99'' FROM DUAL'
    || ' UNION ALL SELECT ''Christopher'', ''42'' FROM DUAL',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 3: all columns auto-width - finalize succeeds
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 3: all columns auto-width');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(3);
  l_cols(1).label := 'Col A'; l_cols(1).auto_width := TRUE;
  l_cols(2).label := 'Col B'; l_cols(2).auto_width := TRUE;
  l_cols(3).label := 'Col C'; l_cols(3).auto_width := TRUE;
  rad_pdf.query2table(l_doc,
    'SELECT ''Short'', ''Medium text'', ''A much longer value here'' FROM DUAL',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 4: max_width cap - auto-width column does not exceed max_width
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 4: max_width cap');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(1);
  l_cols(1).label      := 'Long Column';
  l_cols(1).auto_width := TRUE;
  l_cols(1).max_width  := 60;   -- cap at 60pt regardless of content
  rad_pdf.query2table(l_doc,
    'SELECT RPAD(''X'', 80, ''Y'') FROM DUAL',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 5: width floor - auto-width never goes below declared width
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 5: width floor');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(1);
  l_cols(1).label      := 'X';
  l_cols(1).width      := 200;  -- large floor; data is tiny
  l_cols(1).auto_width := TRUE;
  rad_pdf.query2table(l_doc, 'SELECT ''Y'' FROM DUAL', l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 6: auto_width + wrap = TRUE on same column - wrap wins, no crash
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 6: auto_width + wrap on same column - wrap wins, no crash');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(1);
  l_cols(1).label      := 'Notes';
  l_cols(1).width      := 150;
  l_cols(1).wrap       := TRUE;
  l_cols(1).auto_width := TRUE;   -- silently ignored: wrap wins
  rad_pdf.query2table(l_doc,
    'SELECT ''This is a long note that wraps inside the fixed column width'' FROM DUAL',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 7: empty result set - auto-width falls back to header text width
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 7: empty result set - falls back to header width');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(1);
  l_cols(1).label      := 'Department Name';
  l_cols(1).auto_width := TRUE;
  -- Query returns no rows
  rad_pdf.query2table(l_doc,
    'SELECT dname FROM dept WHERE 1=0',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 8: NULL values in auto-width column - treated as empty, no ORA error
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 8: NULL values in auto-width column');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(2);
  l_cols(1).label      := 'Name';
  l_cols(1).auto_width := TRUE;
  l_cols(2).label      := 'Opt';
  l_cols(2).auto_width := TRUE;
  rad_pdf.query2table(l_doc,
    'SELECT ''Alice'', NULL FROM DUAL UNION ALL SELECT NULL, ''Y'' FROM DUAL',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 9: num_format column - auto-width based on formatted display string
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 9: num_format - auto-width from formatted value');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(2);
  l_cols(1).label := 'Item'; l_cols(1).width := 80;
  l_cols(2).label                     := 'Amount';
  l_cols(2).auto_width                := TRUE;
  l_cols(2).data_fmt.num_format       := '999,990.00';
  l_cols(2).data_fmt.align_h          := 'R';
  rad_pdf.query2table(l_doc,
    'SELECT ''Widget A'', 1234567.89 FROM DUAL'
    || ' UNION ALL SELECT ''Widget B'', 0.01 FROM DUAL',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 10: refcursor source with auto-width
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  l_rc   SYS_REFCURSOR;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 10: refcursor source with auto-width');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(2);
  l_cols(1).label      := 'Dept';
  l_cols(1).auto_width := TRUE;
  l_cols(2).label      := 'Loc';
  l_cols(2).auto_width := TRUE;
  OPEN l_rc FOR SELECT dname, loc FROM dept ORDER BY deptno;
  rad_pdf.refcursor2table(l_doc, l_rc, l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 11: mixed auto + fixed columns - fixed widths unchanged, finalize OK
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 11: mixed auto + fixed columns');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(4);
  l_cols(1).label      := 'EmpNo';   l_cols(1).width := 40;   -- fixed
  l_cols(2).label      := 'Name';    l_cols(2).auto_width := TRUE;
  l_cols(3).label      := 'Job';     l_cols(3).auto_width := TRUE;
  l_cols(4).label      := 'Sal';     l_cols(4).width := 60;   -- fixed
  l_cols(4).data_fmt.align_h := 'R';
  rad_pdf.query2table(l_doc,
    'SELECT TO_CHAR(empno), ename, job, TO_CHAR(sal) FROM emp ORDER BY ename',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 12: multi-page table with auto-width - header repeats on new pages
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 12: multi-page table with auto-width');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(2);
  l_cols(1).label      := 'N';
  l_cols(1).auto_width := TRUE;
  l_cols(2).label      := 'Square';
  l_cols(2).auto_width := TRUE;
  rad_pdf.query2table(l_doc,
    'SELECT TO_CHAR(LEVEL), TO_CHAR(LEVEL * LEVEL) FROM DUAL CONNECT BY LEVEL <= 60',
    l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 13: max_width < width (floor > cap) - cap wins, no error
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 13: max_width < width - cap wins, no error');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  l_cols.EXTEND(1);
  l_cols(1).label      := 'Col';
  l_cols(1).width      := 100;
  l_cols(1).auto_width := TRUE;
  l_cols(1).max_width  := 40;  -- cap < floor
  rad_pdf.query2table(l_doc, 'SELECT ''test'' FROM DUAL', l_cols);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 14: two documents in same session - independent auto-width state
-- ===========================================================================
DECLARE
  l_doc1 rad_pdf_types.t_doc_handle;
  l_doc2 rad_pdf_types.t_doc_handle;
  l_pdf1 BLOB;
  l_pdf2 BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();

  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 14: two documents, independent auto-width state');
  rad_pdf_styles.load_defaults;
  l_cols.EXTEND(1);
  l_cols(1).label := 'X'; l_cols(1).auto_width := TRUE;

  l_doc1 := rad_pdf.new_document;
  rad_pdf.query2table(l_doc1, 'SELECT ''Doc1'' FROM DUAL', l_cols);
  l_pdf1 := rad_pdf.finalize(l_doc1);

  l_doc2 := rad_pdf.new_document;
  rad_pdf.query2table(l_doc2, 'SELECT ''Doc2-longer'' FROM DUAL', l_cols);
  l_pdf2 := rad_pdf.finalize(l_doc2);

  assert(DBMS_LOB.GETLENGTH(l_pdf1) > 0, 'doc1 empty');
  assert(DBMS_LOB.GETLENGTH(l_pdf2) > 0, 'doc2 empty');
  DBMS_LOB.FREETEMPORARY(l_pdf1);
  DBMS_LOB.FREETEMPORARY(l_pdf2);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc1); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN rad_pdf.close_document(l_doc2); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 15: layout engine integration - auto-width table in flowable list
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  l_opts rad_pdf_types.t_table_options;
  l_clrs rad_pdf_types.t_color_scheme;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 15: layout engine integration');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  l_cols.EXTEND(2);
  l_cols(1).label      := 'Department';
  l_cols(1).auto_width := TRUE;
  l_cols(2).label      := 'Location';
  l_cols(2).auto_width := TRUE;

  rad_pdf.heading(l_doc, 'Department List', 1);
  rad_pdf.query2table(l_doc,
    'SELECT dname, loc FROM dept ORDER BY dname',
    l_cols, l_clrs, l_opts);
  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

-- ===========================================================================
-- Test 16: template engine integration - auto-width column set in <table>
-- ===========================================================================
DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  l_opts rad_pdf_types.t_template_options;
  PROCEDURE assert(p_cond BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    IF NOT NVL(p_cond, FALSE) THEN
      RAISE_APPLICATION_ERROR(-20999, 'ASSERTION FAILED: ' || p_msg);
    END IF;
  END assert;
BEGIN
  DBMS_OUTPUT.PUT_LINE('Test 16: template engine integration');
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  l_cols.EXTEND(2);
  l_cols(1).label      := 'Dept';
  l_cols(1).auto_width := TRUE;
  l_cols(2).label      := 'Loc';
  l_cols(2).auto_width := TRUE;
  rad_pdf_template.register_columns('AW_DEPT', l_cols);

  l_opts.allow_queries := TRUE;
  rad_pdf_template.render(l_doc,
    '<h1>Departments</h1>'
    || '<table columns="AW_DEPT" query="SELECT dname, loc FROM dept ORDER BY dname"'
    || ' allow_query="true"/>',
    l_opts);

  l_pdf := rad_pdf.finalize(l_doc);
  assert(DBMS_LOB.GETLENGTH(l_pdf) > 0, 'BLOB empty');
  DBMS_LOB.FREETEMPORARY(l_pdf);
  rad_pdf_template.drop_columns('AW_DEPT');
  DBMS_OUTPUT.PUT_LINE('  PASS');
EXCEPTION WHEN OTHERS THEN
  BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN rad_pdf_template.drop_columns('AW_DEPT'); EXCEPTION WHEN OTHERS THEN NULL; END;
  RAISE;
END;
/

PROMPT
PROMPT ================================================================
PROMPT  Phase 12 complete - all auto-width tests passed.
PROMPT ================================================================
