-- apex_template_02.sql  -  Bind substitution
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Replacing #KEY# tokens in the template with runtime values:
--     - Populated from a SQL query (EMP/DEPT lookup)
--     - Populated from APEX session state (:P1_EMPNO)
--     - Auto-escaping: user-supplied text is safe by default
--     - ## escape sequence produces a literal # character
--     - NULL-safe binds via NVL
--
-- APEX SETUP
--   Page item: P1_EMPNO (Number Field or Select List of employee numbers)
--   Process: Execute Server-side Code - On Load - Before Header
--
-- EMP / DEPT USAGE
--   Looks up one employee row by P1_EMPNO; joins to DEPT for the name.
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;

  -- Columns resolved from the database before building the template
  l_empno    EMP.EMPNO%TYPE;
  l_ename    EMP.ENAME%TYPE;
  l_job      EMP.JOB%TYPE;
  l_sal      EMP.SAL%TYPE;
  l_hiredate EMP.HIREDATE%TYPE;
  l_comm     EMP.COMM%TYPE;
  l_dname    DEPT.DNAME%TYPE;
  l_loc      DEPT.LOC%TYPE;
  l_mgr_name EMP.ENAME%TYPE;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Resolve live data from EMP / DEPT.
  --    TO_NUMBER(:P1_EMPNO) validates the page item - an invalid or NULL value
  --    raises an exception caught below, so no malformed SQL is possible.
  -- -------------------------------------------------------------------------
  SELECT e.empno, e.ename, e.job, e.sal, e.hiredate, e.comm,
         d.dname, d.loc
    INTO l_empno, l_ename, l_job, l_sal, l_hiredate, l_comm,
         l_dname, l_loc
    FROM emp   e
    JOIN dept  d ON d.deptno = e.deptno
   WHERE e.empno = TO_NUMBER(:P1_EMPNO);

  -- Manager name (may be NULL for top-level employee)
  BEGIN
    SELECT m.ename
      INTO l_mgr_name
      FROM emp m
      JOIN emp e ON e.mgr = m.empno
     WHERE e.empno = l_empno;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_mgr_name := NULL; END;

  -- -------------------------------------------------------------------------
  -- 2. Build the bind array.
  --
  --    Each bind entry maps one #TOKEN# in the template to a VARCHAR2 value.
  --    render() auto-escapes every value (& → &amp;  < → &lt;  > → &gt;)
  --    before substitution, so user-supplied text is safe without any
  --    extra call to escape_value().
  --
  --    Values must NOT be NULL (the engine raises ORA-20810 for a NULL bind
  --    that has a matching #TOKEN# in the template).  Use NVL to supply a
  --    safe default for columns that can be NULL.
  -- -------------------------------------------------------------------------
  l_binds(1).key   := 'ENAME';
  l_binds(1).value := l_ename;                              -- VARCHAR2 - safe

  l_binds(2).key   := 'EMPNO';
  l_binds(2).value := TO_CHAR(l_empno);

  l_binds(3).key   := 'JOB';
  l_binds(3).value := INITCAP(l_job);                       -- cosmetic: Job → job

  l_binds(4).key   := 'SAL';
  l_binds(4).value := TO_CHAR(l_sal, 'FM999,990.00');

  l_binds(5).key   := 'HIREDATE';
  l_binds(5).value := TO_CHAR(l_hiredate, 'DD Month YYYY');

  l_binds(6).key   := 'DNAME';
  l_binds(6).value := l_dname;

  l_binds(7).key   := 'LOC';
  l_binds(7).value := INITCAP(l_loc);

  -- NVL supplies a fallback for nullable columns
  l_binds(8).key   := 'COMMISSION';
  l_binds(8).value := NVL(TO_CHAR(l_comm, 'FM999,990.00'), 'None');

  l_binds(9).key   := 'MANAGER';
  l_binds(9).value := NVL(l_mgr_name, '(top level)');

  l_binds(10).key  := 'GEN_DATE';
  l_binds(10).value := TO_CHAR(SYSDATE, 'DD Month YYYY HH24:MI');

  -- -------------------------------------------------------------------------
  -- 3. Render.
  --    Each #KEY# in the template is replaced by the corresponding bind value.
  --    Token matching is case-insensitive: #ename# = #ENAME# = #Ename#.
  --    ## produces a literal # (the hash-sign escape).
  --    Unknown tokens (no matching bind key) are left verbatim.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    '<h1>Employee Card: #ENAME#</h1>'                                     ||
    '<spacer height="6pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="8pt"/>'                                              ||

    '<p>Employee ##: <b>#EMPNO#</b></p>'                                  ||
    -- Note: ## above is the escape for a literal # character in the PDF.

    '<p>Name:        #ENAME#</p>'                                         ||
    '<p>Job title:   #JOB#</p>'                                           ||
    '<p>Department:  #DNAME# (#LOC#)</p>'                                 ||
    '<p>Manager:     #MANAGER#</p>'                                       ||

    '<spacer height="8pt"/>'                                              ||
    '<hr color="AAAAAA" width="0.5"/>'                                    ||
    '<spacer height="8pt"/>'                                              ||

    '<p>Salary:      #SAL#</p>'                                           ||
    '<p>Commission:  #COMMISSION#</p>'                                    ||
    '<p>Hire date:   #HIREDATE#</p>'                                      ||

    '<spacer height="12pt"/>'                                             ||
    '<p style="caption">Generated on #GEN_DATE#.</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="emp_' ||
        TO_CHAR(l_empno) || '.pdf"');
  OWA_UTIL.HTTP_HEADER_CLOSE;
  WPG_DOCLOAD.DOWNLOAD_FILE(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  APEX_APPLICATION.STOP_APEX_ENGINE;

EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN RAISE;
  WHEN NO_DATA_FOUND THEN
    -- Employee not found - redirect or show a message instead of crashing
    APEX_ERROR.ADD_ERROR(
      p_message          => 'Employee ' || :P1_EMPNO || ' not found.',
      p_display_location => apex_error.c_inline_in_notification);
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
