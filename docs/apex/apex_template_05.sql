-- apex_template_05.sql  —  Forced line breaks with <br/>
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   <br/> always produces a true within-paragraph forced line break.
--   The text before and after <br/> stays in the same paragraph (same
--   word-wrapping context, same style, same line-height).
--
--   This is useful for:
--     - Multi-line address blocks where each component must start on a new
--       line but share the same indentation and style.
--     - Notes or comments from a CLOB column that contain newlines.
--     - Concatenating a list of items into one visually distinct block.
--
-- APEX SETUP
--   Page item: P1_EMPNO
--   Process: Execute Server-side Code — On Load - Before Header
--
-- EMP / DEPT USAGE
--   Shows an employee's "profile card" with each field on its own line,
--   all inside a single styled paragraph (no separate <p> per field).
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;

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
  -- 1. Resolve data
  -- -------------------------------------------------------------------------
  SELECT e.ename, e.job, e.sal, e.hiredate, e.comm,
         d.dname, d.loc
    INTO l_ename, l_job, l_sal, l_hiredate, l_comm,
         l_dname, l_loc
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
  -- -------------------------------------------------------------------------
  l_binds(1).key := 'ENAME';
  l_binds(1).value := INITCAP(l_ename);

  l_binds(2).key := 'JOB';
  l_binds(2).value := INITCAP(l_job);

  l_binds(3).key := 'SAL';
  l_binds(3).value := TO_CHAR(l_sal, 'FM999,990.00');

  l_binds(4).key := 'COMM';
  l_binds(4).value := NVL(TO_CHAR(l_comm, 'FM999,990.00'), '—');

  l_binds(5).key := 'HIREDATE';
  l_binds(5).value := TO_CHAR(l_hiredate, 'DD Month YYYY');

  l_binds(6).key := 'DNAME';
  l_binds(6).value := INITCAP(l_dname);

  l_binds(7).key := 'LOC';
  l_binds(7).value := INITCAP(l_loc);

  l_binds(8).key := 'MANAGER';
  l_binds(8).value := NVL(INITCAP(l_mgr_name), '(none)');

  -- -------------------------------------------------------------------------
  -- 3. Template
  --
  -- Each <br/> forces a new line WITHIN the same paragraph.
  -- Compare with using separate <p> tags — separate paragraphs add extra
  -- vertical spacing between each item; <br/> keeps them tightly grouped.
  --
  -- Key rule: mixing <br/> (or any inline tag) in the same <p> routes the
  -- paragraph through the PARA_RUNS engine, which renders everything on the
  -- same word-wrapped lines.  All runs share the same style unless overridden
  -- by <b>, <i>, <color>, or <font>.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    '<h1>Employee Profile</h1>'                                           ||
    '<spacer height="6pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="10pt"/>'                                             ||

    -- -----------------------------------------------------------------------
    -- Profile block: single <p>, each field on a new line via <br/>.
    -- Labels are bold; values are plain (default style).
    -- All lines share the same left margin and font size.
    -- -----------------------------------------------------------------------
    '<p>'
      || '<b>Name:</b>       #ENAME#<br/>'
      || '<b>Job:</b>        #JOB#<br/>'
      || '<b>Department:</b> #DNAME# (#LOC#)<br/>'
      || '<b>Manager:</b>    #MANAGER#<br/>'
      || '<b>Hired:</b>      #HIREDATE#'
      || '</p>'                                                           ||

    '<spacer height="8pt"/>'                                              ||
    '<hr color="CCCCCC" width="0.5"/>'                                    ||
    '<spacer height="14pt"/>'                                             ||

    -- -----------------------------------------------------------------------
    -- Compensation block: another single <p> with labelled lines.
    -- -----------------------------------------------------------------------
    '<h2>Compensation</h2>'                                               ||
    '<p>'
      || '<b>Salary:</b>     #SAL#<br/>'
      || '<b>Commission:</b> #COMM#'
      || '</p>'                                                           ||

    '<spacer height="14pt"/>'                                             ||
    '<p style="caption">'
      || 'Tip: &lt;br/&gt; keeps lines in the same paragraph '
      || '— use separate &lt;p&gt; tags when you need paragraph spacing.'
      || '</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="profile_' ||
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
