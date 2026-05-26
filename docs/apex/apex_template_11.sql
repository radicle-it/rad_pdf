-- apex_template_11.sql  -  Multi-section document via multiple render() calls
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Calling render() multiple times on the same document handle.
--   Each call APPENDS its flowables to the document - no new document needed.
--   This pattern lets you:
--     - Keep header, body, and footer as separate template strings.
--     - Reuse a header/footer template across different body templates.
--     - Build the body from multiple queries in a loop (one render per dept).
--     - Separate concerns: different procedures can own different sections.
--
--   In this example the document has three sections built by separate render()
--   calls:
--     SECTION 1  - cover page (no binds)
--     SECTION 2  - department pages (one per department, looped)
--     SECTION 3  - closing signature block
--
-- APEX SETUP
--   No page items needed - the report covers all departments.
--   Process: Execute Server-side Code - On Load - Before Header
-- ===========================================================================

DECLARE
  l_doc      rad_pdf_types.t_doc_handle;
  l_pdf      BLOB;
  l_opts     rad_pdf_types.t_template_options;
  l_binds    rad_pdf_types.t_bind_array;

  -- Re-usable header template (same for every department section)
  c_dept_header CONSTANT VARCHAR2(500) :=
    '<h1><color rgb="003366">#DNAME#</color></h1>'        ||
    '<p>Location: <b>#LOC#</b>   '
      || 'Employees: <b>#COUNT#</b></p>'                  ||
    '<spacer height="6pt"/>'                              ||
    '<hr color="003366"/>'                                ||
    '<spacer height="14pt"/>';

  -- Re-usable employee list template
  c_emp_list CONSTANT VARCHAR2(500) :=
    '<h2>Employee List</h2>'                              ||
    '<p>#EMP_LINES#</p>';

  l_emp_lines VARCHAR2(32767);

  CURSOR c_depts IS
    SELECT d.deptno, d.dname, d.loc, COUNT(e.empno) AS cnt
      FROM dept d
      LEFT JOIN emp e ON e.deptno = d.deptno
     GROUP BY d.deptno, d.dname, d.loc
     ORDER BY d.deptno;

  CURSOR c_emp(p_deptno NUMBER) IS
    SELECT ename, INITCAP(job) AS job,
           TO_CHAR(sal, 'FM999,990.00') AS sal_fmt
      FROM emp
     WHERE deptno = p_deptno
     ORDER BY ename;

  l_first_dept BOOLEAN := TRUE;

BEGIN
  l_opts.allow_queries := FALSE;  -- no <table> tags in this example

  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- SECTION 1: Cover page - no binds, no data
  -- =========================================================================
  rad_pdf_template.render(l_doc,
    '<h1>Human Resources Report</h1>'                                     ||
    '<spacer height="20pt"/>'                                             ||
    '<hr color="003366" width="2"/>'                                      ||
    '<spacer height="20pt"/>'                                             ||
    '<p>This report covers all departments and their employees.</p>'     ||
    '<p>Generated: <b>' || TO_CHAR(SYSDATE, 'DD Month YYYY') || '</b></p>');

  -- =========================================================================
  -- SECTION 2: One page per department - render() called in a loop.
  --   <pagebreak/> is injected between departments (not before the first).
  -- =========================================================================
  FOR d IN c_depts LOOP

    -- Inject a page break between department sections
    IF NOT l_first_dept THEN
      rad_pdf_template.render(l_doc, '<pagebreak/>');
    END IF;
    l_first_dept := FALSE;

    -- Build the employee list for this department
    l_emp_lines := '';
    FOR r IN c_emp(d.deptno) LOOP
      IF l_emp_lines IS NOT NULL THEN l_emp_lines := l_emp_lines || '<br/>'; END IF;
      l_emp_lines := l_emp_lines
        || '<b>' || INITCAP(r.ename) || '</b>'
        || ' (<i>' || r.job || '</i>)'
        || '  ' || r.sal_fmt;
    END LOOP;
    IF l_emp_lines IS NULL THEN l_emp_lines := '<i>No employees.</i>'; END IF;

    -- Populate the bind array for this department
    -- (overwrite all entries - l_binds persists across loop iterations)
    l_binds(1).key := 'DNAME';      l_binds(1).value := d.dname;
    l_binds(2).key := 'LOC';        l_binds(2).value := INITCAP(d.loc);
    l_binds(3).key := 'COUNT';      l_binds(3).value := TO_CHAR(d.cnt);
    l_binds(4).key := 'EMP_LINES';  l_binds(4).value := l_emp_lines;
    l_binds(4).raw := TRUE;   -- value contains inline tags

    -- Two separate render() calls build the department section:
    -- first the header, then the employee list.
    -- Both calls append to the SAME document (l_doc).
    rad_pdf_template.render(l_doc, c_dept_header, l_binds);
    rad_pdf_template.render(l_doc, c_emp_list,    l_binds);

  END LOOP;

  -- =========================================================================
  -- SECTION 3: Closing block - no binds again
  -- =========================================================================
  rad_pdf_template.render(l_doc,
    '<pagebreak/>'                                                        ||
    '<h1>End of Report</h1>'                                             ||
    '<spacer height="20pt"/>'                                             ||
    '<hr color="AAAAAA" width="0.5"/>'                                   ||
    '<spacer height="10pt"/>'                                             ||
    '<p>This document is generated automatically by the RAD_PDF '       ||
    'template engine.  For questions contact HR.</p>');

  -- =========================================================================
  -- Finalize and stream
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="hr_report_all.pdf"');
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
