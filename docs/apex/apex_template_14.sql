-- apex_template_14.sql  —  Complete department report (all features combined)
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   A production-quality report that combines all template engine features:
--     - Bind substitution (#KEY# tokens from EMP/DEPT data)
--     - Conditional blocks (<if bind="KEY">) for optional sections
--     - Inline formatting (<b>, <i>, <color>, <font size>, <br/>)
--     - Inline markup inside headings
--     - Ordered and unordered lists with formatted items
--     - Data table (<table columns="…" query="…">)
--     - Spacers and horizontal rules for visual separation
--     - Page break between summary and detail pages
--     - Custom default font size from t_template_options
--
--   The document has two pages:
--     Page 1 — Department summary (key stats, top earner, salary distribution)
--     Page 2 — Full employee roster as a formatted table
--
-- APEX SETUP
--   Page items:
--     P1_DEPTNO     (select list — department number)
--     P1_NOTES      (text area — optional notes; NULL suppresses the section)
--     P1_SHOW_COMMS (checkbox — 'Y' to include commission column, else NULL)
--   Application Process (On New Session): register EMP_ROSTER column set.
--   Process: Execute Server-side Code — On Load - Before Header
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_opts   rad_pdf_types.t_template_options;

  -- Department data
  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;

  -- Aggregates
  l_count    PLS_INTEGER;
  l_sum_sal  NUMBER;
  l_max_sal  NUMBER;
  l_min_sal  NUMBER;
  l_avg_sal  NUMBER;

  -- Top earner
  l_top_name EMP.ENAME%TYPE;
  l_top_sal  EMP.SAL%TYPE;

  -- Salary distribution list (one colour-coded line per employee)
  l_sal_list   VARCHAR2(32767);

  -- Highest-job employees list
  l_mgr_list   VARCHAR2(32767);

  CURSOR c_sal_dist(p_deptno NUMBER) IS
    SELECT ename, sal, job
      FROM emp WHERE deptno = p_deptno ORDER BY sal DESC;

  CURSOR c_managers(p_deptno NUMBER) IS
    SELECT DISTINCT m.ename, m.job
      FROM emp m
      JOIN emp e ON e.mgr = m.empno
     WHERE m.deptno = p_deptno
     ORDER BY m.ename;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Resolve all data upfront
  -- -------------------------------------------------------------------------
  SELECT dname, loc INTO l_dname, l_loc
    FROM dept WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  SELECT COUNT(*), SUM(sal), MAX(sal), MIN(sal), AVG(sal)
    INTO l_count, l_sum_sal, l_max_sal, l_min_sal, l_avg_sal
    FROM emp WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  BEGIN
    SELECT ename, sal INTO l_top_name, l_top_sal
      FROM (SELECT ename, sal FROM emp
             WHERE deptno = TO_NUMBER(:P1_DEPTNO) ORDER BY sal DESC)
     WHERE ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN l_top_name := NULL; END;

  -- Build salary distribution: colour-coded by tier
  l_sal_list := '';
  FOR r IN c_sal_dist(TO_NUMBER(:P1_DEPTNO)) LOOP
    IF l_sal_list IS NOT NULL THEN l_sal_list := l_sal_list || '<br/>'; END IF;
    IF r.sal >= 3000 THEN
      l_sal_list := l_sal_list
        || '<b><color rgb="006600">' || INITCAP(r.ename) || '</color></b>'
        || '  <font size="9pt"><i>' || INITCAP(r.job) || '</i></font>'
        || '  <b>' || TO_CHAR(r.sal,'FM999,990.00') || '</b>';
    ELSIF r.sal >= 2000 THEN
      l_sal_list := l_sal_list
        || '<b>' || INITCAP(r.ename) || '</b>'
        || '  <font size="9pt"><i>' || INITCAP(r.job) || '</i></font>'
        || '  ' || TO_CHAR(r.sal,'FM999,990.00');
    ELSE
      l_sal_list := l_sal_list
        || '<color rgb="888888">' || INITCAP(r.ename) || '</color>'
        || '  <font size="9pt"><i>' || INITCAP(r.job) || '</i></font>'
        || '  ' || TO_CHAR(r.sal,'FM999,990.00');
    END IF;
  END LOOP;
  IF l_sal_list IS NULL THEN l_sal_list := '<i>No employees.</i>'; END IF;

  -- Build manager list
  l_mgr_list := '';
  FOR r IN c_managers(TO_NUMBER(:P1_DEPTNO)) LOOP
    l_mgr_list := l_mgr_list
      || '<li><b>' || INITCAP(r.ename) || '</b>'
      || ' — <i>' || INITCAP(r.job) || '</i>'
      || '</li>';
  END LOOP;

  -- -------------------------------------------------------------------------
  -- 2. Binds
  -- -------------------------------------------------------------------------
  l_binds(1).key  := 'DEPT_NAME'; l_binds(1).value := l_dname;
  l_binds(2).key  := 'DEPT_LOC';  l_binds(2).value := INITCAP(l_loc);
  l_binds(3).key  := 'DEPTNO';    l_binds(3).value := :P1_DEPTNO;
  l_binds(4).key  := 'COUNT';     l_binds(4).value := TO_CHAR(l_count);

  l_binds(5).key  := 'SUM_SAL';
  l_binds(5).value := NVL(TO_CHAR(l_sum_sal,'FM999,990.00'), '—');

  l_binds(6).key  := 'MAX_SAL';
  l_binds(6).value := NVL(TO_CHAR(l_max_sal,'FM999,990.00'), '—');

  l_binds(7).key  := 'MIN_SAL';
  l_binds(7).value := NVL(TO_CHAR(l_min_sal,'FM999,990.00'), '—');

  l_binds(8).key  := 'AVG_SAL';
  l_binds(8).value := NVL(TO_CHAR(l_avg_sal,'FM999,990.00'), '—');

  -- Top earner: conditional bind (absent when no employees)
  IF l_top_name IS NOT NULL THEN
    l_binds(9).key  := 'TOP_NAME';
    l_binds(9).value := INITCAP(l_top_name);
    l_binds(10).key  := 'TOP_SAL';
    l_binds(10).value := TO_CHAR(l_top_sal,'FM999,990.00');
  END IF;

  -- Salary distribution: raw because it contains inline tags
  l_binds(11).key   := 'SAL_LIST';
  l_binds(11).value := l_sal_list;
  l_binds(11).raw   := TRUE;

  -- Manager list: raw because it contains <li> tags
  l_binds(12).key   := 'MGR_LIST';
  l_binds(12).value := NVL(l_mgr_list, '<li>None.</li>');
  l_binds(12).raw   := TRUE;

  -- Optional notes (NULL → <if bind="NOTES"> block is suppressed)
  l_binds(13).key  := 'NOTES';
  l_binds(13).value := :P1_NOTES;   -- may be NULL — safe inside <if>

  l_binds(14).key  := 'GEN_DATE';
  l_binds(14).value := TO_CHAR(SYSDATE, 'DD Month YYYY HH24:MI');

  -- -------------------------------------------------------------------------
  -- 3. Options
  -- -------------------------------------------------------------------------
  l_opts.allow_queries    := TRUE;
  l_opts.default_font_size := 10;   -- set explicitly for this report

  -- -------------------------------------------------------------------------
  -- 4. Render — PAGE 1: department summary
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,

    -- ----- Header -----------------------------------------------------------
    '<h1>Department Report — '
      || '<color rgb="003366">#DEPT_NAME#</color>'
      || '</h1>'                                                           ||
    '<p>Location: <b>#DEPT_LOC#</b>   |   '
      || 'Department: <b>#DEPTNO#</b>   |   '
      || 'Total employees: <b>#COUNT#</b></p>'                           ||
    '<spacer height="6pt"/>'                                              ||
    '<hr color="003366" width="1.5"/>'                                    ||
    '<spacer height="10pt"/>'                                             ||

    -- ----- Salary statistics ------------------------------------------------
    '<h2>Salary Statistics</h2>'                                          ||
    '<p>'
      || '<b>Total payroll:</b> #SUM_SAL#<br/>'
      || '<b>Highest salary:</b> #MAX_SAL#<br/>'
      || '<b>Lowest salary:</b>  #MIN_SAL#<br/>'
      || '<b>Average salary:</b> #AVG_SAL#'
      || '</p>'                                                           ||

    -- Top earner — conditional: block absent when dept has no employees
    '<if bind="TOP_NAME">'
      || '<p>Top earner: '
      || '<b><color rgb="006600">#TOP_NAME#</color></b>'
      || ' — #TOP_SAL#</p>'
      || '</if>'                                                          ||

    '<spacer height="10pt"/>'                                             ||
    '<hr color="CCCCCC" width="0.5"/>'                                    ||
    '<spacer height="8pt"/>'                                              ||

    -- ----- Salary distribution (colour-coded) --------------------------------
    '<h2>Salary Distribution</h2>'                                        ||
    '<p style="caption">'
      || '<color rgb="006600"><b>Green bold</b></color> = ≥ 3,000   '    ||
      'Plain = ≥ 2,000   '                                                ||
      '<color rgb="888888">Grey</color> = &lt; 2,000'
      || '</p>'                                                           ||
    '<spacer height="4pt"/>'                                              ||
    '<p>#SAL_LIST#</p>'                                                   ||

    '<spacer height="10pt"/>'                                             ||
    '<hr color="CCCCCC" width="0.5"/>'                                    ||
    '<spacer height="8pt"/>'                                              ||

    -- ----- Managers list (unordered) -----------------------------------------
    '<h2>People Managers</h2>'                                            ||
    '<ul>#MGR_LIST#</ul>'                                                 ||

    -- ----- Optional notes ---------------------------------------------------
    '<if bind="NOTES">'
      || '<spacer height="10pt"/>'
      || '<hr color="CCCCCC" width="0.5"/>'
      || '<spacer height="8pt"/>'
      || '<h2>Notes</h2>'
      || '<p>#NOTES#</p>'
      || '</if>'                                                          ||

    -- ----- Page break → page 2 -----------------------------------------------
    '<pagebreak/>'                                                        ||

    -- ----- PAGE 2: Full employee table ---------------------------------------
    '<h1>#DEPT_NAME# — Employee Roster</h1>'                             ||
    '<p style="caption">Location: #DEPT_LOC#   |   Dept: #DEPTNO#</p>' ||
    '<spacer height="6pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="8pt"/>'                                              ||

    '<table columns="EMP_ROSTER"'
      || ' query="SELECT empno, ename, INITCAP(job),'
      ||          ' TO_CHAR(hiredate,''DD-Mon-YYYY''), sal'
      ||        ' FROM emp WHERE deptno = #DEPTNO# ORDER BY ename"'
      || ' row_height="15pt"'
      || ' header_bg="003366"'
      || ' alt_bg="EAF0FB"'
      || ' border_color="AAAAAA"'
      || ' allow_query="true"/>'                                          ||

    '<spacer height="10pt"/>'                                             ||
    '<p style="caption">Generated: #GEN_DATE#</p>',
    l_binds,
    l_opts);

  -- -------------------------------------------------------------------------
  -- 5. Finalize and stream
  -- -------------------------------------------------------------------------
  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="dept_report_' ||
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
