-- apex_sample07.sql - Template engine example (Oracle APEX)
--
-- Demonstrates rad_pdf_template.render inside an APEX page process:
--   - Bind substitution from APEX session state (#KEY#)
--   - Block tags: <h1>, <h2>, <p>, <spacer>, <hr>
--   - Inline formatting: <b>, <i>, <br/>
--   - Optional <table> with registered column set
--
-- Uses the classic Oracle EMP / DEPT tables (available in every sample schema).
--
-- Prerequisites:
--   - RAD_PDF suite installed (all 9 phases).
--   - A page process of type "Execute Code" on the target APEX page.
--   - APEX page items P1_DEPTNO, P1_NOTES.
--   - The APEX application's parsing schema has SELECT privilege on EMP and DEPT,
--     and EXECUTE privilege on rad_pdf, rad_pdf_template, and rad_pdf_types.

DECLARE
  -- -------------------------------------------------------------------------
  -- Column definitions for the employee list (registered once per session
  -- or in an APEX application initialization code block).
  -- -------------------------------------------------------------------------
  l_cols  rad_pdf_types.t_columns;

  -- -------------------------------------------------------------------------
  -- Template CLOB: structure and content of the document.
  -- Bind keys map to APEX page items (upper-cased, without the colon prefix).
  -- -------------------------------------------------------------------------
  l_tmpl  CLOB;

  -- -------------------------------------------------------------------------
  -- Bind array: populate from APEX session state and from a lookup query.
  -- -------------------------------------------------------------------------
  l_binds rad_pdf_types.t_bind_array;

  -- -------------------------------------------------------------------------
  -- Options: enable queries for the <table> tag.
  -- -------------------------------------------------------------------------
  l_opts  rad_pdf_types.t_template_options;

  l_doc       rad_pdf_types.t_doc_handle;
  l_pdf       BLOB;

  -- Department attributes resolved from DEPT before building the template.
  l_dept_name DEPT.DNAME%TYPE;
  l_dept_loc  DEPT.LOC%TYPE;

  -- Helper: append a VARCHAR2 chunk to a CLOB.
  PROCEDURE wapp(p_clob IN OUT NOCOPY CLOB, p_str IN VARCHAR2) IS
  BEGIN
    IF p_str IS NOT NULL THEN
      DBMS_LOB.WRITEAPPEND(p_clob, LENGTH(p_str), p_str);
    END IF;
  END wapp;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Resolve department name and location from DEPT.
  --    If P1_DEPTNO is NULL or invalid, default to "All Departments" so the
  --    report is still useful when the page item has not been set yet.
  -- -------------------------------------------------------------------------
  l_dept_name := 'All Departments';
  l_dept_loc  := chr(8212);   -- em-dash: not applicable for the all-dept view
  BEGIN
    SELECT dname, loc
      INTO l_dept_name, l_dept_loc
      FROM dept
     WHERE deptno = TO_NUMBER(:P1_DEPTNO);
  EXCEPTION
    WHEN OTHERS THEN NULL;   -- NO_DATA_FOUND or INVALID_NUMBER: keep defaults
  END;

  -- -------------------------------------------------------------------------
  -- 2. Register the employee column set (idempotent after first call).
  --    In a real application, move this to an Application Process that runs
  --    On New Session so it is registered only once per session.
  -- -------------------------------------------------------------------------
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(5);

  l_cols(1).label              := 'No';
  l_cols(1).width              := 40;
  l_cols(1).header_fmt.align_h := 'C';
  l_cols(1).data_fmt.align_h   := 'C';

  l_cols(2).label              := 'Name';
  l_cols(2).width              := 110;

  l_cols(3).label              := 'Job';
  l_cols(3).width              := 90;

  l_cols(4).label              := 'Hired';
  l_cols(4).width              := 75;
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.align_h   := 'C';

  l_cols(5).label              := 'Salary';
  l_cols(5).width              := 65;
  l_cols(5).header_fmt.align_h := 'R';
  l_cols(5).data_fmt.align_h   := 'R';
  l_cols(5).data_fmt.num_format := '999,990.00';

  rad_pdf_template.register_columns('EMP_LIST', l_cols);

  -- -------------------------------------------------------------------------
  -- 3. Build the document template CLOB.
  -- -------------------------------------------------------------------------
  DBMS_LOB.CREATETEMPORARY(l_tmpl, TRUE);

  wapp(l_tmpl, '<h1>Department Employee Report</h1>');
  wapp(l_tmpl, '<spacer height="6pt"/>');
  wapp(l_tmpl, '<p>Department: <b>#DEPT_NAME#</b></p>');
  wapp(l_tmpl, '<p>Location: <b>#DEPT_LOC#</b></p>');
  wapp(l_tmpl, '<spacer height="10pt"/>');
  wapp(l_tmpl, '<hr color="003366"/>');
  wapp(l_tmpl, '<spacer height="10pt"/>');

  wapp(l_tmpl, '<h2>Employees</h2>');
  wapp(l_tmpl, '<table columns="EMP_LIST"');
  wapp(l_tmpl,        ' query="SELECT empno, ename, job,');
  wapp(l_tmpl,               '        TO_CHAR(hiredate, ''DD-Mon-YYYY''), sal');
  wapp(l_tmpl,               '   FROM emp');
  -- When DEPTNO = 0 (P1_DEPTNO not set) the CASE makes the condition always
  -- TRUE so all employees are returned.  When DEPTNO is a real dept number
  -- only that department is shown.
  wapp(l_tmpl,               '  WHERE deptno = CASE WHEN #DEPTNO# = 0');
  wapp(l_tmpl,               '                      THEN deptno');
  wapp(l_tmpl,               '                      ELSE #DEPTNO# END');
  wapp(l_tmpl,               '  ORDER BY ename"');
  wapp(l_tmpl,        ' allow_query="true"/>');

  -- Optional notes section: only rendered when the NOTES bind value is non-NULL.
  -- <if bind="NOTES"> evaluates before bind substitution; when P1_NOTES is
  -- NULL the entire block (including the heading and paragraph) is suppressed.
  wapp(l_tmpl, '<spacer height="12pt"/>');
  wapp(l_tmpl, '<if bind="NOTES">');
  wapp(l_tmpl,   '<h2>Notes</h2>');
  wapp(l_tmpl,   '<p>#NOTES#</p>');
  wapp(l_tmpl, '</if>');

  -- -------------------------------------------------------------------------
  -- 4. Populate binds.
  --    DEPT_NAME / DEPT_LOC come from the lookup above.
  --    NOTES comes from the APEX page item (user-supplied text).  When the
  --    page item is NULL the <if bind="NOTES"> block in the template is
  --    suppressed entirely (no heading, no paragraph); there is no need for
  --    a NVL fallback.
  --    DEPTNO is inlined into the <table> query as a template token (#DEPTNO#)
  --    - rad_pdf_template replaces it with the literal value before executing
  --    the SQL, so no Oracle SQL bind variable (:name) is left unbound.
  --    The value is validated as numeric by the TO_NUMBER call in step 1.
  --
  --    NOTE: escape_value() is no longer required here.  rad_pdf_template.render
  --    auto-escapes all bind values (& → &amp;  < → &lt;  > → &gt;) before
  --    substitution, so user-supplied text is safe by default.
  --    Set raw=TRUE on a bind entry only for values that are already escaped
  --    or that intentionally contain template markup.
  -- -------------------------------------------------------------------------
  l_binds(1).key   := 'DEPT_NAME';
  l_binds(1).value := l_dept_name;

  l_binds(2).key   := 'DEPT_LOC';
  l_binds(2).value := l_dept_loc;

  -- NOTES: pass the raw page-item value.  When NULL, the <if bind="NOTES">
  -- block is dropped by apply_conditionals before bind substitution runs,
  -- so the #NOTES# token never reaches apply_binds_clob and no error is raised.
  l_binds(3).key   := 'NOTES';
  l_binds(3).value := :P1_NOTES;

  -- DEPTNO is inlined into the WHERE CASE expression via the #DEPTNO# token.
  -- NVL(…, 0) ensures the bind is never NULL; 0 selects all employees.
  l_binds(4).key   := 'DEPTNO';
  l_binds(4).value := TO_CHAR(NVL(TO_NUMBER(:P1_DEPTNO), 0));

  -- -------------------------------------------------------------------------
  -- 5. Enable table query execution.
  -- -------------------------------------------------------------------------
  l_opts.allow_queries := TRUE;

  -- -------------------------------------------------------------------------
  -- 6. Render and stream the PDF to the browser.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;
  rad_pdf_template.render(l_doc, l_tmpl, l_binds, l_opts);
  DBMS_LOB.FREETEMPORARY(l_tmpl);

  l_pdf := rad_pdf.finalize(l_doc);

  -- Stream to browser
  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="dept_' ||
        :P1_DEPTNO || '_employees.pdf"');
  OWA_UTIL.HTTP_HEADER_CLOSE;
  WPG_DOCLOAD.DOWNLOAD_FILE(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);
  APEX_APPLICATION.STOP_APEX_ENGINE;

EXCEPTION
  WHEN APEX_APPLICATION.E_STOP_APEX_ENGINE THEN
    RAISE;
  WHEN OTHERS THEN
    IF DBMS_LOB.ISTEMPORARY(l_tmpl) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tmpl); END IF;
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
