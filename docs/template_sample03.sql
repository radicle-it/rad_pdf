-- =============================================================================
-- template_sample03.sql  -  Template engine: lists, inline colour, font size
-- =============================================================================
--
-- WHAT THIS SHOWS
--   • Unordered list: <ul><li>...</li></ul>  — one bullet point per <li>
--   • Ordered list:   <ol><li>...</li></ol>  — numbered: 1.  2.  3. ...
--   • Inline markup is supported inside <li> content (same as <p>):
--       <b>, <i>, <br/>, <color>, <font>
--   • Inline colour:
--       <color rgb="RRGGBB">...</color>
--       Six-character hex (upper or lower case).  Supports unlimited nesting
--       depth: each opening tag pushes the current colour onto a LIFO stack;
--       each </color> pops and restores the previous one.
--   • Inline font size:
--       <font size="Xpt">...</font>
--       Any unit accepted by rad_pdf_units (pt, mm, cm).  Also supports
--       unlimited nesting depth via a LIFO stack.
--
--   Building raw markup in PL/SQL:
--     When a bind value contains inline tags (<b>, <color>, ...) set
--     raw=TRUE on the t_bind_entry to skip auto-escaping.  Only do this
--     for values you control; never for user-supplied free text.
--
-- DATA
--   Uses EMP / DEPT.  Replace the cursors with DUAL if the tables are absent.
--
-- HOW TO RUN
--   Same as template_sample01.sql.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;

  CURSOR c_sal(p_deptno NUMBER) IS
    SELECT ename, job, sal FROM emp
     WHERE deptno = p_deptno ORDER BY sal DESC;

  CURSOR c_dept IS
    SELECT deptno, dname, loc FROM dept ORDER BY deptno;

  -- Inline-markup strings built in PL/SQL before binding.
  l_sal_lines   VARCHAR2(32767) := '';
  l_dept_items  VARCHAR2(32767) := '';
BEGIN
  -- --------------------------------------------------------------------------
  -- Build salary-distribution paragraph for RESEARCH (dept 20).
  -- Colour-code by salary tier; each line is a separate run inside <p>.
  -- --------------------------------------------------------------------------
  FOR r IN c_sal(20) LOOP
    IF l_sal_lines IS NOT NULL THEN l_sal_lines := l_sal_lines || '<br/>'; END IF;
    IF r.sal >= 3000 THEN
      -- High earner: bold green name
      l_sal_lines := l_sal_lines
        || '<b><color rgb="006600">' || INITCAP(r.ename) || '</color></b>'
        || '  <font size="9pt"><i>' || INITCAP(r.job)   || '</i></font>'
        || '  <b>' || TO_CHAR(r.sal, 'FM999,990.00')    || '</b>';
    ELSIF r.sal >= 2000 THEN
      -- Mid earner: normal weight, grey job title
      l_sal_lines := l_sal_lines
        || INITCAP(r.ename)
        || '  <font size="9pt"><color rgb="555555"><i>'
        || INITCAP(r.job) || '</i></color></font>'
        || '  ' || TO_CHAR(r.sal, 'FM999,990.00');
    ELSE
      -- Lower earner: grey name
      l_sal_lines := l_sal_lines
        || '<color rgb="999999">' || INITCAP(r.ename) || '</color>'
        || '  <font size="9pt"><i>' || INITCAP(r.job)   || '</i></font>'
        || '  ' || TO_CHAR(r.sal, 'FM999,990.00');
    END IF;
  END LOOP;
  IF l_sal_lines IS NULL THEN l_sal_lines := '<i>No employees.</i>'; END IF;

  -- --------------------------------------------------------------------------
  -- Build a <li> item for every department.
  -- --------------------------------------------------------------------------
  FOR r IN c_dept LOOP
    l_dept_items := l_dept_items
      || '<li>'
      || '<b>' || TO_CHAR(r.deptno) || '</b>  '
      || INITCAP(r.dname)
      || '  <font size="9pt"><color rgb="777777">'
      || INITCAP(r.loc) || '</color></font>'
      || '</li>';
  END LOOP;
  IF l_dept_items IS NULL THEN l_dept_items := '<li><i>No departments.</i></li>'; END IF;

  -- --------------------------------------------------------------------------
  -- Bind array.
  -- SAL_LINES and DEPT_ITEMS contain inline markup → raw=TRUE.
  -- --------------------------------------------------------------------------
  l_binds(1).key   := 'SAL_LINES';  l_binds(1).value := l_sal_lines;  l_binds(1).raw := TRUE;
  l_binds(2).key   := 'DEPT_ITEMS'; l_binds(2).value := l_dept_items; l_binds(2).raw := TRUE;

  -- --------------------------------------------------------------------------
  -- Render.
  -- --------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,

    '<h1>Inline Formatting and Lists</h1>'                                      ||

    -- ---- Inline colour and font size ----------------------------------------
    '<h2>Salary Distribution — Research Dept (dept 20)</h2>'                   ||
    '<p style="caption">'
      || '<color rgb="006600"><b>Green bold</b></color> = salary ≥ 3,000   '   ||
      'Plain = 2,000–2,999   '                                                  ||
      '<color rgb="999999">Grey</color> = &lt; 2,000'
      || '</p>'                                                                 ||
    '<spacer height="4pt"/>'                                                    ||
    '<p>#SAL_LINES#</p>'                                                        ||

    '<spacer height="14pt"/>'                                                   ||
    '<hr color="CCCCCC" width="0.5"/>'                                          ||
    '<spacer height="8pt"/>'                                                    ||

    -- ---- Unordered list (<ul>) ----------------------------------------------
    '<h2>Departments (unordered list)</h2>'                                     ||
    '<ul>#DEPT_ITEMS#</ul>'                                                     ||

    '<spacer height="8pt"/>'                                                    ||

    -- ---- Ordered list with inline markup in items (<ol>) --------------------
    '<h2>Steps to generate a PDF (ordered list)</h2>'                          ||
    '<ol>'
      || '<li>Call <b>rad_pdf_styles.load_defaults</b> once per session.</li>'
      || '<li>Call <b>rad_pdf.new_document</b> to open a document handle.</li>'
      || '<li>Build your bind array ('
      ||   '<font size="9pt"><color rgb="555555">key / value pairs</color></font>'
      || ').</li>'
      || '<li>Call <b>rad_pdf_template.render</b> with the template and binds.</li>'
      || '<li>Call <b>rad_pdf.finalize</b> to get the PDF BLOB.</li>'
      || '<li>Stream, store, or save the BLOB, then free it.</li>'
      || '</ol>',

    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated — size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
