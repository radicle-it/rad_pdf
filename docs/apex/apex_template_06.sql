-- apex_template_06.sql  —  Conditional blocks: <if bind="KEY">...</if>
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Including or excluding whole sections of the template at runtime:
--
--     <if bind="KEY">
--       ... any content ...
--     </if>
--
--   The block is INCLUDED when the bind value for KEY is non-NULL and non-empty.
--   The block is REMOVED  when KEY is absent from the bind array or its value
--   is NULL.
--
--   Conditionals are evaluated BEFORE bind substitution, so tokens inside a
--   suppressed block are never processed — they can be NULL without error.
--
--   Use cases in this example:
--     1. Show/hide salary section based on a checkbox (P1_SHOW_SALARY = 'Y')
--     2. Show/hide notes section based on a text area (P1_NOTES)
--     3. Show manager section only when the employee has one
--
-- APEX SETUP
--   Page items:
--     P1_EMPNO        (number field)
--     P1_SHOW_SALARY  (checkbox — value 'Y' when checked, NULL when unchecked)
--     P1_NOTES        (text area — optional free-text comment)
--   Process: Execute Server-side Code — On Load - Before Header
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;

  l_ename    EMP.ENAME%TYPE;
  l_job      EMP.JOB%TYPE;
  l_sal      EMP.SAL%TYPE;
  l_hiredate EMP.HIREDATE%TYPE;
  l_dname    DEPT.DNAME%TYPE;
  l_mgr_name EMP.ENAME%TYPE;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Resolve data
  -- -------------------------------------------------------------------------
  SELECT e.ename, e.job, e.sal, e.hiredate, d.dname
    INTO l_ename, l_job, l_sal, l_hiredate, l_dname
    FROM emp  e
    JOIN dept d ON d.deptno = e.deptno
   WHERE e.empno = TO_NUMBER(:P1_EMPNO);

  BEGIN
    SELECT m.ename INTO l_mgr_name
      FROM emp m JOIN emp e ON e.mgr = m.empno
     WHERE e.empno = TO_NUMBER(:P1_EMPNO);
  EXCEPTION WHEN NO_DATA_FOUND THEN l_mgr_name := NULL; END;

  -- -------------------------------------------------------------------------
  -- 2. Binds
  --
  --   Key design decision: for conditional sections, you have two options:
  --
  --   Option A — add the bind only when the condition is true
  --     Pros: clean; the block disappears along with its tokens.
  --     Cons: slightly more PL/SQL IF logic.
  --
  --   Option B — always add the bind; use NULL to suppress
  --     Pros: simpler array building (no IF).
  --     Cons: the bind value itself is NULL — you MUST place the token inside
  --           an <if bind="KEY"> block so it is never seen by apply_binds.
  --           DO NOT reference a NULL-value token outside an <if> block.
  --
  --   This example uses Option A for SALARY and Option B for NOTES.
  -- -------------------------------------------------------------------------

  -- Always-present binds
  l_binds(1).key   := 'ENAME';     l_binds(1).value := INITCAP(l_ename);
  l_binds(2).key   := 'JOB';       l_binds(2).value := INITCAP(l_job);
  l_binds(3).key   := 'DNAME';     l_binds(3).value := l_dname;
  l_binds(4).key   := 'HIREDATE';  l_binds(4).value := TO_CHAR(l_hiredate, 'DD Month YYYY');

  -- SALARY section: Option A — add bind only when P1_SHOW_SALARY = 'Y'
  -- The <if bind="SALARY"> block is suppressed when SALARY is absent.
  IF :P1_SHOW_SALARY = 'Y' THEN
    l_binds(5).key   := 'SALARY';
    l_binds(5).value := TO_CHAR(l_sal, 'FM999,990.00');
  END IF;
  -- Note: if P1_SHOW_SALARY != 'Y', no entry for SALARY exists in l_binds,
  -- so the <if bind="SALARY"> block is automatically dropped.

  -- NOTES section: Option B — always present, NULL when empty
  -- The :P1_NOTES item is NULL when the user left the text area blank.
  -- The <if bind="NOTES"> block suppresses #NOTES# when it is NULL,
  -- avoiding the NULL-bind error.
  l_binds(6).key   := 'NOTES';
  l_binds(6).value := :P1_NOTES;   -- may be NULL — safe inside <if bind="NOTES">

  -- MANAGER section: only present when the employee has a manager
  IF l_mgr_name IS NOT NULL THEN
    l_binds(7).key   := 'MANAGER_NAME';
    l_binds(7).value := INITCAP(l_mgr_name);
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Template
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    '<h1>Employee Summary: #ENAME#</h1>'                                  ||
    '<p>Job: <b>#JOB#</b>   Department: <b>#DNAME#</b>   Hired: #HIREDATE#</p>' ||

    '<spacer height="10pt"/>'                                             ||
    '<hr color="336699"/>'                                                ||
    '<spacer height="8pt"/>'                                              ||

    -- -----------------------------------------------------------------------
    -- MANAGER SECTION: shown only when the employee has a manager.
    -- When MANAGER_NAME is absent from the bind array, this entire block
    -- (including the <h2> and <p>) is removed from the output.
    -- -----------------------------------------------------------------------
    '<if bind="MANAGER_NAME">'
      || '<h2>Reporting to</h2>'
      || '<p>#MANAGER_NAME#</p>'
      || '<spacer height="8pt"/>'
      || '</if>'                                                          ||

    -- -----------------------------------------------------------------------
    -- SALARY SECTION: shown only when the user checked P1_SHOW_SALARY.
    -- When SALARY is absent, the block and its #SALARY# token are removed.
    -- -----------------------------------------------------------------------
    '<if bind="SALARY">'
      || '<h2>Compensation</h2>'
      || '<p>Monthly salary: <b>#SALARY#</b></p>'
      || '<spacer height="8pt"/>'
      || '</if>'                                                          ||

    -- -----------------------------------------------------------------------
    -- NOTES SECTION: shown only when P1_NOTES is non-NULL.
    -- The #NOTES# token is INSIDE the <if> block — it is never processed
    -- when NOTES is NULL, so no ORA-20810 is raised.
    -- -----------------------------------------------------------------------
    '<if bind="NOTES">'
      || '<h2>Notes</h2>'
      || '<p>#NOTES#</p>'
      || '</if>'                                                          ||

    '<spacer height="14pt"/>'                                             ||
    '<p style="caption">Tip: remove a bind-array entry (or leave its value '  ||
    'NULL) to suppress the corresponding &lt;if bind=...&gt; block entirely.</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="emp_summary_' ||
        :P1_EMPNO || '.pdf"');
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
