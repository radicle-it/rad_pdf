-- apex_template_12.sql  —  Custom default font via t_template_options
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Changing the default font for all body paragraphs in a render() call
--   without having to define custom styles manually:
--
--     l_opts.default_font_name  := 'Arial';   -- or any registered font
--     l_opts.default_font_style := 'N';        -- 'N','B','I','BI'
--     l_opts.default_font_size  := 11;          -- in pt
--     l_opts.default_style      := 'body';      -- base style to derive from
--
--   When any of these three fields is non-NULL, the engine creates a derived
--   style variant (e.g. 'body__dft_fn_s11') and uses it as the effective
--   default_style for the duration of the render() call.
--
--   These options affect:
--     - All <p> tags that do NOT carry an explicit style="..." attribute.
--     - The base style used when inline markup derives sub-styles.
--
--   They do NOT affect:
--     - <h1>–<h6> (headings have their own styles).
--     - <p style="caption"> or any <p> with an explicit style= attribute.
--     - <table> column styles.
--
-- APEX SETUP
--   Page items:
--     P1_DEPTNO
--     P1_FONT_SIZE  (optional: number field 8–16, default 10)
--     P1_FONT_STYLE (optional: select list — 'N', 'B', 'I', 'BI')
--   Process: Execute Server-side Code — On Load - Before Header
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_opts   rad_pdf_types.t_template_options;
  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;

  -- Employee summary built in PL/SQL
  l_emp_lines VARCHAR2(32767);

  CURSOR c_emp(p_deptno NUMBER) IS
    SELECT ename, INITCAP(job) AS job,
           TO_CHAR(sal, 'FM999,990.00') AS sal_fmt
      FROM emp WHERE deptno = p_deptno ORDER BY ename;

BEGIN
  SELECT dname, loc INTO l_dname, l_loc
    FROM dept WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  l_emp_lines := '';
  FOR r IN c_emp(TO_NUMBER(:P1_DEPTNO)) LOOP
    IF l_emp_lines IS NOT NULL THEN l_emp_lines := l_emp_lines || '<br/>'; END IF;
    l_emp_lines := l_emp_lines
      || r.ename || '  (' || r.job || ')  ' || r.sal_fmt;
  END LOOP;
  IF l_emp_lines IS NULL THEN l_emp_lines := 'No employees.'; END IF;

  -- -------------------------------------------------------------------------
  -- Options: font customisation
  --
  --   default_font_name : name of a font known to rad_pdf_fonts.
  --     Standard Type-1 fonts always available (no embedding needed):
  --       Helvetica  Helvetica-Bold  Helvetica-Oblique  Helvetica-BoldOblique
  --       Times-Roman  Times-Bold  Times-Italic  Times-BoldItalic
  --       Courier  Courier-Bold  Courier-Oblique  Courier-BoldOblique
  --
  --   default_font_style : 'N' Normal | 'B' Bold | 'I' Italic | 'BI' Both
  --   default_font_size  : size in pt (e.g. 11, 12.5)
  --
  --   Set only the fields you want to override; leave others NULL to keep
  --   the base style's value.
  -- -------------------------------------------------------------------------
  l_opts.default_font_size  := NVL(TO_NUMBER(:P1_FONT_SIZE),  11);
  l_opts.default_font_style := NVL(:P1_FONT_STYLE,            'N');
  -- Uncomment to change the font family:
  -- l_opts.default_font_name := 'Times-Roman';

  -- -------------------------------------------------------------------------
  -- Binds
  -- -------------------------------------------------------------------------
  l_binds(1).key := 'DNAME';     l_binds(1).value := l_dname;
  l_binds(2).key := 'LOC';       l_binds(2).value := INITCAP(l_loc);
  l_binds(3).key := 'DEPTNO';    l_binds(3).value := :P1_DEPTNO;
  l_binds(4).key := 'FONT_SIZE'; l_binds(4).value := TO_CHAR(l_opts.default_font_size);
  l_binds(5).key := 'FONT_STY';  l_binds(5).value := l_opts.default_font_style;
  l_binds(6).key := 'EMP_LINES'; l_binds(6).value := l_emp_lines;
  -- l_emp_lines is plain text (no inline tags) so raw=FALSE (default) is correct

  -- -------------------------------------------------------------------------
  -- Render
  --
  -- All <p> tags without style="..." use the derived default style.
  -- Headings are unaffected (they have their own styles).
  -- The <p style="caption"> explicitly uses caption regardless of l_opts.
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    -- Heading unaffected by default_font_* options
    '<h1>Department #DNAME#</h1>'                                         ||
    '<h2>Font options demo — size #FONT_SIZE#pt, style #FONT_STY#</h2>'  ||

    '<spacer height="6pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="8pt"/>'                                              ||

    -- These <p> tags pick up the custom font from l_opts
    '<p>Location: #LOC#   (department #DEPTNO#)</p>'                     ||

    '<spacer height="6pt"/>'                                              ||
    '<p>Employee names, job titles, and salaries:</p>'                   ||
    '<p>#EMP_LINES#</p>'                                                  ||

    '<spacer height="10pt"/>'                                             ||

    -- This paragraph explicitly uses the "caption" style — unaffected by l_opts
    '<p style="caption">'
      || 'This line always uses the caption style (Helvetica I 8pt) '
      || 'regardless of t_template_options settings.'
      || '</p>',
    l_binds,
    l_opts);   -- <-- pass the options as the fourth argument

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="font_demo.pdf"');
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
