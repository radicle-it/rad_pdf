-- sample11.sql - Template engine example (non-APEX)
--
-- Demonstrates rad_pdf_template.render:
--   - Bind placeholder substitution (#KEY#)
--   - Block tags: <h1>, <h2>, <p>, <spacer>, <hr>, <pagebreak>
--   - Inline tags inside <p>: <b>, <i>, <br/>
--   - <table> tag with registered column set (requires allow_queries)
--
-- Uses the classic Oracle EMP / DEPT tables (available in every sample schema).
--
-- Run in SQL*Plus from repo root.
-- The file is saved to the Oracle directory RAD_PDF_DIR.
-- Create the directory first:
--   CREATE OR REPLACE DIRECTORY rad_pdf_dir AS '/tmp';
--   GRANT READ, WRITE ON DIRECTORY rad_pdf_dir TO <your_schema>;

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  -- -------------------------------------------------------------------------
  -- Column set for the <table> tag: department summary (EMP + DEPT).
  -- -------------------------------------------------------------------------
  l_cols  rad_pdf_types.t_columns;

  -- -------------------------------------------------------------------------
  -- Template stored in a CLOB (simulates a template loaded from a DB table).
  -- -------------------------------------------------------------------------
  l_tmpl  CLOB;

  -- -------------------------------------------------------------------------
  -- Bind values: replace #PLACEHOLDER# tokens in the template.
  -- -------------------------------------------------------------------------
  l_binds rad_pdf_types.t_bind_array;

  -- -------------------------------------------------------------------------
  -- Options: enable query execution for the <table> tag.
  -- -------------------------------------------------------------------------
  l_opts  rad_pdf_types.t_template_options;

  l_doc       rad_pdf_types.t_doc_handle;
  l_pdf       BLOB;

  -- Scalar totals resolved before building the template.
  l_emp_count PLS_INTEGER;
  l_dept_count PLS_INTEGER;

  -- Helper: append a VARCHAR2 chunk to a CLOB.
  PROCEDURE wapp(p_clob IN OUT NOCOPY CLOB, p_str IN VARCHAR2) IS
  BEGIN
    IF p_str IS NOT NULL THEN
      DBMS_LOB.WRITEAPPEND(p_clob, LENGTH(p_str), p_str);
    END IF;
  END wapp;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Resolve summary totals from EMP / DEPT.
  -- -------------------------------------------------------------------------
  SELECT COUNT(DISTINCT deptno), COUNT(*) INTO l_dept_count, l_emp_count FROM emp;

  -- -------------------------------------------------------------------------
  -- 2. Register column definitions for the <table> tag.
  -- -------------------------------------------------------------------------
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(4);

  -- Column 1: Department name
  l_cols(1).label               := 'Department';
  l_cols(1).width               := 140;

  -- Column 2: Location
  l_cols(2).label               := 'Location';
  l_cols(2).width               := 110;

  -- Column 3: Headcount
  l_cols(3).label               := 'Employees';
  l_cols(3).width               := 80;
  l_cols(3).header_fmt.align_h  := 'C';
  l_cols(3).data_fmt.align_h    := 'C';

  -- Column 4: Average salary
  l_cols(4).label               := 'Avg Salary';
  l_cols(4).width               := 90;
  l_cols(4).header_fmt.align_h  := 'R';
  l_cols(4).data_fmt.align_h    := 'R';
  l_cols(4).data_fmt.num_format := '999,990.00';

  rad_pdf_template.register_columns('DEPT_SUMMARY', l_cols);

  -- -------------------------------------------------------------------------
  -- 3. Build the template CLOB.
  -- -------------------------------------------------------------------------
  DBMS_LOB.CREATETEMPORARY(l_tmpl, TRUE);

  wapp(l_tmpl, '<h1>Department Salary Report</h1>');
  wapp(l_tmpl, '<h2>Period: #PERIOD#</h2>');
  wapp(l_tmpl, '<p>Prepared by: <b>#AUTHOR#</b></p>');
  wapp(l_tmpl, '<spacer height="8pt"/>');
  wapp(l_tmpl, '<hr color="336699" width="1"/>');
  wapp(l_tmpl, '<spacer height="8pt"/>');

  wapp(l_tmpl, '<h2>Executive Summary</h2>');
  wapp(l_tmpl, '<p>');
  wapp(l_tmpl,   'This report covers <b>#DEPT_COUNT# departments</b> and ');
  wapp(l_tmpl,   '<b>#EMP_COUNT# employees</b> as of #PERIOD#.<br/>');
  wapp(l_tmpl,   'Average salaries are computed from the EMP table and rounded to the nearest unit.');
  wapp(l_tmpl, '</p>');

  wapp(l_tmpl, '<spacer height="12pt"/>');

  wapp(l_tmpl, '<h2>Summary by Department</h2>');
  wapp(l_tmpl, '<table columns="DEPT_SUMMARY"');
  wapp(l_tmpl,        ' query="SELECT d.dname, d.loc,');
  wapp(l_tmpl,               '        COUNT(e.empno),');
  wapp(l_tmpl,               '        ROUND(AVG(NVL(e.sal, 0)))');
  wapp(l_tmpl,               '   FROM dept d');
  wapp(l_tmpl,               '   LEFT JOIN emp e ON e.deptno = d.deptno');
  wapp(l_tmpl,               '  GROUP BY d.dname, d.loc');
  wapp(l_tmpl,               '  ORDER BY d.dname"');
  wapp(l_tmpl,        ' allow_query="true"/>');

  wapp(l_tmpl, '<pagebreak/>');

  wapp(l_tmpl, '<h2>Notes</h2>');
  wapp(l_tmpl, '<p>');
  wapp(l_tmpl,   'Departments with no employees show a headcount of 0 and an average salary of 0.<br/>');
  wapp(l_tmpl,   'For questions regarding this report, contact <i>#CONTACT#</i>.');
  wapp(l_tmpl, '</p>');

  -- -------------------------------------------------------------------------
  -- 4. Set bind values.
  -- -------------------------------------------------------------------------
  l_binds(1).key   := 'PERIOD';     l_binds(1).value := TO_CHAR(SYSDATE, 'Month YYYY');
  l_binds(2).key   := 'AUTHOR';     l_binds(2).value := USER;
  l_binds(3).key   := 'DEPT_COUNT'; l_binds(3).value := TO_CHAR(l_dept_count);
  l_binds(4).key   := 'EMP_COUNT';  l_binds(4).value := TO_CHAR(l_emp_count);
  l_binds(5).key   := 'CONTACT';    l_binds(5).value := 'dba@example.com';

  -- -------------------------------------------------------------------------
  -- 5. Enable query execution (required for <table> tags).
  -- -------------------------------------------------------------------------
  l_opts.allow_queries := TRUE;

  -- -------------------------------------------------------------------------
  -- 6. Render the template.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl, l_binds, l_opts);
  DBMS_LOB.FREETEMPORARY(l_tmpl);

  -- -------------------------------------------------------------------------
  -- 7. Save the PDF.
  -- -------------------------------------------------------------------------
  rad_pdf.save(l_doc, 'RAD_PDF_DIR', 'sample11_dept_report.pdf');
  DBMS_OUTPUT.PUT_LINE('sample11_dept_report.pdf written to RAD_PDF_DIR.');

EXCEPTION
  WHEN OTHERS THEN
    IF DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tmpl); END IF;
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
