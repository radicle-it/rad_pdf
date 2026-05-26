-- apex_template_09.sql  -  Page break: <pagebreak/>
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Forcing a new page at an explicit point in the document:
--     <pagebreak/>
--
--   Use cases:
--     - Start each department on a new page in a multi-department report.
--     - Place a cover/summary on page 1 and detail data from page 2 onwards.
--     - Separate a table of contents from the body content.
--
--   In this example:
--     Page 1 - company-wide summary (all departments, headcount per dept).
--     Page 2 - detail for the selected department with an employee list.
--
-- APEX SETUP
--   Page item: P1_DEPTNO
--   Process: Execute Server-side Code - On Load - Before Header
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;
  l_count  PLS_INTEGER;

  -- Summary table: one line per department
  l_summary  VARCHAR2(32767);

  -- Detail: employee list for the selected department
  l_detail   VARCHAR2(32767);

  CURSOR c_depts IS
    SELECT d.deptno, d.dname, d.loc, COUNT(e.empno) AS cnt
      FROM dept d
      LEFT JOIN emp e ON e.deptno = d.deptno
     GROUP BY d.deptno, d.dname, d.loc
     ORDER BY d.deptno;

  CURSOR c_emp_detail(p_deptno NUMBER) IS
    SELECT ename, INITCAP(job) AS job,
           TO_CHAR(sal, 'FM999,990.00') AS sal_fmt,
           TO_CHAR(hiredate, 'DD-Mon-YYYY') AS hire_fmt
      FROM emp
     WHERE deptno = p_deptno
     ORDER BY ename;

BEGIN
  SELECT dname, loc INTO l_dname, l_loc
    FROM dept WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  SELECT COUNT(*) INTO l_count FROM emp WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  -- -------------------------------------------------------------------------
  -- Build page-1 summary: one paragraph line per department.
  -- -------------------------------------------------------------------------
  l_summary := '';
  FOR d IN c_depts LOOP
    IF l_summary IS NOT NULL THEN l_summary := l_summary || '<br/>'; END IF;

    IF d.deptno = TO_NUMBER(:P1_DEPTNO) THEN
      -- Highlight the selected department
      l_summary := l_summary
        || '<b><color rgb="003366">'
        || d.deptno || '  ' || d.dname || ' - ' || INITCAP(d.loc)
        || '   (' || d.cnt || ' employee' || CASE WHEN d.cnt != 1 THEN 's' END || ')'
        || '</color></b>';
    ELSE
      l_summary := l_summary
        || d.deptno || '  ' || d.dname || ' - ' || INITCAP(d.loc)
        || '   (' || d.cnt || ' employee' || CASE WHEN d.cnt != 1 THEN 's' END || ')';
    END IF;
  END LOOP;

  -- -------------------------------------------------------------------------
  -- Build page-2 detail: one <br/>-separated line per employee.
  -- -------------------------------------------------------------------------
  l_detail := '';
  FOR r IN c_emp_detail(TO_NUMBER(:P1_DEPTNO)) LOOP
    IF l_detail IS NOT NULL THEN l_detail := l_detail || '<br/>'; END IF;
    l_detail := l_detail
      || '<b>' || INITCAP(r.ename) || '</b>'
      || '  <i>' || r.job || '</i>'
      || '  - Salary: ' || r.sal_fmt
      || '  Hired: '    || r.hire_fmt;
  END LOOP;
  IF l_detail IS NULL THEN l_detail := '<i>No employees.</i>'; END IF;

  -- -------------------------------------------------------------------------
  -- Binds
  -- -------------------------------------------------------------------------
  l_binds(1).key := 'DNAME';   l_binds(1).value := l_dname;
  l_binds(2).key := 'LOC';     l_binds(2).value := INITCAP(l_loc);
  l_binds(3).key := 'DEPTNO';  l_binds(3).value := :P1_DEPTNO;
  l_binds(4).key := 'COUNT';   l_binds(4).value := TO_CHAR(l_count);

  l_binds(5).key   := 'SUMMARY'; l_binds(5).value := l_summary;
  l_binds(5).raw   := TRUE;

  l_binds(6).key   := 'DETAIL';  l_binds(6).value := l_detail;
  l_binds(6).raw   := TRUE;

  l_binds(7).key := 'GEN_DATE';
  l_binds(7).value := TO_CHAR(SYSDATE, 'DD Month YYYY');

  -- -------------------------------------------------------------------------
  -- Template: PAGE 1 (summary), then <pagebreak/>, then PAGE 2 (detail)
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,

    -- =======================================================================
    -- PAGE 1 - Company overview
    -- =======================================================================
    '<h1>Company Overview</h1>'                                           ||
    '<p style="caption">Generated: #GEN_DATE#</p>'                       ||
    '<spacer height="8pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="14pt"/>'                                             ||
    '<h2>Departments</h2>'                                                ||
    '<p>'
      || 'Selected department is shown in '
      || '<b><color rgb="003366">bold blue</color></b>.'
      || '</p>'                                                           ||
    '<spacer height="6pt"/>'                                              ||
    '<p>#SUMMARY#</p>'                                                    ||

    -- -----------------------------------------------------------------------
    -- <pagebreak/> forces everything after this point to start on a new page.
    -- -----------------------------------------------------------------------
    '<pagebreak/>'                                                        ||

    -- =======================================================================
    -- PAGE 2 - Department detail
    -- =======================================================================
    '<h1>#DNAME# - Detail</h1>'                                          ||
    '<p>Location: <b>#LOC#</b>   Employees: <b>#COUNT#</b></p>'         ||
    '<spacer height="8pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="14pt"/>'                                             ||
    '<h2>Employee List</h2>'                                              ||
    '<p>#DETAIL#</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="overview_dept_' ||
        :P1_DEPTNO || '.pdf"');
  OWA_UTIL.HTTP_HEADER_CLOSE;
  WPG_DOCLOAD.DOWNLOAD_FILE(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  APEX_APPLICATION.STOP_APEX_ENGINE;

EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN RAISE;
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
