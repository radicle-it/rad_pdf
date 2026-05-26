-- apex_template_04.sql  -  Inline colour and font size
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Custom ink colour and font size applied to specific text runs:
--     <color rgb="RRGGBB">...</color>   6-char hex colour, case-insensitive
--     <font size="Xpt">...</font>       any unit: pt, mm, cm, in
--
--   Single-level nesting is supported:
--     <b><color rgb="CC0000">bold red text</color></b>
--     <font size="14pt"><b>large bold</b></font>
--
--   Both tags work inside <p>, <li>, and <h1>–<h6>.
--
-- APEX SETUP
--   Page item: P1_DEPTNO
--   Process: Execute Server-side Code - On Load - Before Header
--
-- EMP / DEPT USAGE
--   Shows employees sorted by salary; high earners (sal >= 3000) are
--   highlighted in red bold, low earners in grey italic.
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_dname  DEPT.DNAME%TYPE;

  -- Build the salary paragraph with coloured runs.
  l_salary_lines VARCHAR2(32767);

  CURSOR c_emp(p_deptno NUMBER) IS
    SELECT ename, job, sal
      FROM emp
     WHERE deptno = p_deptno
     ORDER BY sal DESC;

BEGIN
  SELECT dname INTO l_dname FROM dept WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  -- -------------------------------------------------------------------------
  -- Build the salary paragraph.
  --   sal >= 3000  →  bold + red   (colour CC0000)
  --   sal >= 2000  →  bold + blue  (colour 003399)
  --   sal <  2000  →  italic + grey (colour 888888)
  -- -------------------------------------------------------------------------
  l_salary_lines := '';
  FOR r IN c_emp(TO_NUMBER(:P1_DEPTNO)) LOOP
    IF l_salary_lines IS NOT NULL THEN
      l_salary_lines := l_salary_lines || '<br/>';
    END IF;

    IF r.sal >= 3000 THEN
      -- High earner: bold red
      l_salary_lines := l_salary_lines
        || '<b><color rgb="CC0000">'
        || r.ename || ' - ' || TO_CHAR(r.sal, 'FM999,990.00')
        || '</color></b>';

    ELSIF r.sal >= 2000 THEN
      -- Mid earner: bold blue
      l_salary_lines := l_salary_lines
        || '<b><color rgb="003399">'
        || r.ename || ' - ' || TO_CHAR(r.sal, 'FM999,990.00')
        || '</color></b>';

    ELSE
      -- Low earner: italic grey, smaller font
      l_salary_lines := l_salary_lines
        || '<font size="9pt"><color rgb="888888"><i>'
        || r.ename || ' - ' || TO_CHAR(r.sal, 'FM999,990.00')
        || '</i></color></font>';
    END IF;
  END LOOP;

  IF l_salary_lines IS NULL THEN
    l_salary_lines := '<i>No employees.</i>';
  END IF;

  -- -------------------------------------------------------------------------
  -- Binds
  -- -------------------------------------------------------------------------
  l_binds(1).key := 'DNAME';   l_binds(1).value := l_dname;
  l_binds(2).key := 'DEPTNO';  l_binds(2).value := :P1_DEPTNO;

  -- raw=TRUE because the value contains template tags (<b>, <color>, etc.)
  l_binds(3).key   := 'SALARY_LINES';
  l_binds(3).value := l_salary_lines;
  l_binds(3).raw   := TRUE;

  -- -------------------------------------------------------------------------
  -- Template
  --
  -- Colour and font size can also be used directly in the template string
  -- (not just via raw binds).  The examples below show both approaches.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    -- Heading with a coloured word directly in the template
    '<h1>Salary Report - '
      || '<color rgb="003366">#DNAME#</color>'
      || '</h1>'                                                            ||
    '<p style="caption">Department #DEPTNO#</p>'                          ||

    '<spacer height="8pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="14pt"/>'                                             ||

    -- Legend: font-size changes inside a heading (works after the fix)
    '<h2>Colour key</h2>'                                                  ||
    '<p>'
      || '<color rgb="CC0000"><b>Bold red</b></color> = salary ≥ 3,000   '||
      '<color rgb="003399"><b>Bold blue</b></color> = salary ≥ 2,000   '  ||
      '<font size="9pt"><color rgb="888888"><i>Grey small</i></color></font>'
      || ' = salary &lt; 2,000'
      || '</p>'                                                            ||

    '<spacer height="10pt"/>'                                              ||
    '<h2>Employees by salary (high to low)</h2>'                          ||

    -- The actual salary lines, built dynamically above with colour markup
    '<p>#SALARY_LINES#</p>'                                               ||

    '<spacer height="14pt"/>'                                              ||
    -- Font-size override directly in the template (no bind needed)
    '<p>'
      || '<font size="8pt"><color rgb="888888">'
      || 'Amounts in local currency.  '
      || 'Generated: ' || TO_CHAR(SYSDATE, 'DD-Mon-YYYY HH24:MI')
      || '</color></font>'
      || '</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="salary_' ||
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
