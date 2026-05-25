-- apex_template_07.sql  —  Lists: <ul>, <ol>, <li>
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Building ordered and unordered lists from database data:
--     <ul>...</ul>   unordered list — bullet prefix "*  "
--     <ol>...</ol>   ordered list   — numbered prefix "1.  ", "2.  ", …
--     <li>...</li>   list item; content may contain inline tags
--
--   Key points:
--     - List tag names (<UL>, <OL>, <Li>) are case-insensitive.
--     - <li> content goes through the same inline-markup engine as <p>.
--       You can use <b>, <i>, <color>, <font>, and <br/> inside <li>.
--     - The optional style="name" attribute on <ul>/<ol> applies to all items.
--
-- APEX SETUP
--   Page item: P1_DEPTNO
--   Process: Execute Server-side Code — On Load - Before Header
--
-- EMP / DEPT USAGE
--   Unordered list: employees in the department (name + job).
--   Ordered list  : top earners ranked by salary (name + formatted salary).
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_dname  DEPT.DNAME%TYPE;

  -- Build the list content as VARCHAR2 strings of <li>…</li> items.
  l_ul_items  VARCHAR2(32767);   -- employees (unordered)
  l_ol_items  VARCHAR2(32767);   -- top earners (ordered)

  -- Managers set (for conditional bold)
  l_mgr_empno EMP.EMPNO%TYPE;

  CURSOR c_employees(p_deptno NUMBER) IS
    SELECT e.empno, e.ename, e.job, e.sal,
           CASE WHEN EXISTS (SELECT 1 FROM emp m WHERE m.mgr = e.empno)
                THEN 'Y' ELSE 'N' END AS is_manager
      FROM emp e
     WHERE e.deptno = p_deptno
     ORDER BY e.ename;

  CURSOR c_top_earners(p_deptno NUMBER) IS
    SELECT ename, sal
      FROM emp
     WHERE deptno = p_deptno
     ORDER BY sal DESC;

BEGIN
  SELECT dname INTO l_dname FROM dept WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  -- -------------------------------------------------------------------------
  -- Build unordered list items.
  -- Managers are shown in bold; others in plain text.
  -- Job title is italic.
  -- -------------------------------------------------------------------------
  l_ul_items := '';
  FOR r IN c_employees(TO_NUMBER(:P1_DEPTNO)) LOOP
    IF r.is_manager = 'Y' THEN
      -- Manager: bold name
      l_ul_items := l_ul_items
        || '<li><b>' || INITCAP(r.ename) || '</b>'
        || ' — <i>' || INITCAP(r.job) || '</i>'
        || ' <color rgb="006600"><b>(manager)</b></color>'
        || '</li>';
    ELSE
      l_ul_items := l_ul_items
        || '<li>' || INITCAP(r.ename)
        || ' — <i>' || INITCAP(r.job) || '</i>'
        || '</li>';
    END IF;
  END LOOP;

  IF l_ul_items IS NULL THEN
    l_ul_items := '<li>No employees in this department.</li>';
  END IF;

  -- -------------------------------------------------------------------------
  -- Build ordered list items (top earners — same department, by salary desc).
  -- Salaries >= 3000 are highlighted red.
  -- -------------------------------------------------------------------------
  l_ol_items := '';
  FOR r IN c_top_earners(TO_NUMBER(:P1_DEPTNO)) LOOP
    IF r.sal >= 3000 THEN
      l_ol_items := l_ol_items
        || '<li><b>' || INITCAP(r.ename) || '</b>'
        || ' — <color rgb="CC0000"><b>' || TO_CHAR(r.sal, 'FM999,990.00') || '</b></color>'
        || '</li>';
    ELSE
      l_ol_items := l_ol_items
        || '<li>' || INITCAP(r.ename)
        || ' — ' || TO_CHAR(r.sal, 'FM999,990.00')
        || '</li>';
    END IF;
  END LOOP;

  IF l_ol_items IS NULL THEN
    l_ol_items := '<li>No data.</li>';
  END IF;

  -- -------------------------------------------------------------------------
  -- Binds
  -- Both list content strings contain template tags → raw=TRUE
  -- -------------------------------------------------------------------------
  l_binds(1).key := 'DNAME';   l_binds(1).value := l_dname;
  l_binds(2).key := 'DEPTNO';  l_binds(2).value := :P1_DEPTNO;

  l_binds(3).key := 'UL_ITEMS'; l_binds(3).value := l_ul_items;
  l_binds(3).raw := TRUE;

  l_binds(4).key := 'OL_ITEMS'; l_binds(4).value := l_ol_items;
  l_binds(4).raw := TRUE;

  -- -------------------------------------------------------------------------
  -- Template
  --
  -- Note: <ul> and <ol> are self-closing in the sense that their only
  -- meaningful content is <li> items — any text outside <li> tags is ignored.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    '<h1>Department #DNAME# — Lists Demo</h1>'                            ||
    '<p style="caption">Department #DEPTNO#</p>'                         ||
    '<spacer height="8pt"/>'                                              ||
    '<hr color="336699"/>'                                                ||
    '<spacer height="14pt"/>'                                             ||

    -- -----------------------------------------------------------------------
    -- Unordered list — bullet prefix for each item
    -- -----------------------------------------------------------------------
    '<h2>All Employees</h2>'                                              ||
    '<p style="caption">'
      || '<color rgb="006600"><b>Bold green = manager</b></color>'
      || '</p>'                                                           ||
    '<spacer height="4pt"/>'                                              ||
    '<ul>#UL_ITEMS#</ul>'                                                 ||

    '<spacer height="12pt"/>'                                             ||
    '<hr color="CCCCCC" width="0.5"/>'                                    ||
    '<spacer height="14pt"/>'                                             ||

    -- -----------------------------------------------------------------------
    -- Ordered list — automatically numbered 1., 2., 3., …
    -- -----------------------------------------------------------------------
    '<h2>Salary Ranking</h2>'                                             ||
    '<p style="caption">'
      || '<color rgb="CC0000"><b>Red = salary &gt;= 3,000</b></color>'
      || '</p>'                                                           ||
    '<spacer height="4pt"/>'                                              ||
    '<ol>#OL_ITEMS#</ol>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="lists_dept_' ||
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
