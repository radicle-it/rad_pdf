-- apex_template_10.sql  —  Inline markup inside headings <h1>–<h6>
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Using <b>, <i>, <color>, and <font size> inside heading tags:
--
--     <h1>Title with <color rgb="CC0000">red word</color></h1>
--     <h2>Summary for <b>#DNAME#</b></h2>
--
--   When a heading contains ANY inline tag, the layout engine renders it
--   as a PARA_RUNS flowable using the predefined 'h{N}' style (h1, h2, …).
--   This means the full styling of the heading level (font, size, weight)
--   is preserved for the plain-text parts, while inline overrides are
--   applied only to the tagged runs.
--
--   Headings WITHOUT inline tags continue to use rad_pdf_layout.heading()
--   for maximum compatibility.
--
-- APEX SETUP
--   Page item: P1_DEPTNO
--   Process: Execute Server-side Code — On Load - Before Header
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;
  l_count  PLS_INTEGER;
  l_top_earner EMP.ENAME%TYPE;
  l_top_sal    EMP.SAL%TYPE;

BEGIN
  SELECT dname, loc INTO l_dname, l_loc
    FROM dept WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  SELECT COUNT(*) INTO l_count FROM emp WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  -- Top earner in the department
  BEGIN
    SELECT ename, sal INTO l_top_earner, l_top_sal
      FROM (SELECT ename, sal FROM emp
             WHERE deptno = TO_NUMBER(:P1_DEPTNO)
             ORDER BY sal DESC)
     WHERE ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    l_top_earner := NULL; l_top_sal := NULL;
  END;

  -- -------------------------------------------------------------------------
  -- Binds
  -- -------------------------------------------------------------------------
  l_binds(1).key := 'DNAME';   l_binds(1).value := l_dname;
  l_binds(2).key := 'LOC';     l_binds(2).value := INITCAP(l_loc);
  l_binds(3).key := 'DEPTNO';  l_binds(3).value := :P1_DEPTNO;
  l_binds(4).key := 'COUNT';   l_binds(4).value := TO_CHAR(l_count);
  l_binds(5).key := 'TOP_EARNER';
  l_binds(5).value := NVL(INITCAP(l_top_earner), 'N/A');
  l_binds(6).key := 'TOP_SAL';
  l_binds(6).value := NVL(TO_CHAR(l_top_sal, 'FM999,990.00'), '—');

  -- -------------------------------------------------------------------------
  -- Template — each heading level demonstrates a different inline feature
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,

    -- Plain heading (no inline tags) — uses rad_pdf_layout.heading() path
    '<h1>Department Report</h1>'                                          ||

    -- Heading with a coloured word — the rest stays at h2 style weight/size
    '<h2>Department <color rgb="003366">#DNAME#</color></h2>'            ||

    -- Heading with bold + colour combined
    '<h3>Location: <b><color rgb="336633">#LOC#</color></b></h3>'       ||

    '<spacer height="6pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="8pt"/>'                                              ||

    -- h4 with italic word
    '<h4>Total employees: <i>#COUNT#</i></h4>'                          ||

    -- h5 with a font-size override on one word — useful for a superscript-
    -- style annotation or to visually de-emphasise part of the heading
    '<h5>Top earner: #TOP_EARNER# '
      || '<font size="8pt"><color rgb="CC0000">(#TOP_SAL#)</color></font>'
      || '</h5>'                                                          ||

    -- h6 — all inline features combined in one heading
    '<h6>'
      || '<b>Bold</b> + '
      || '<i>italic</i> + '
      || '<color rgb="990000">red</color> + '
      || '<font size="12pt">larger</font> — '
      || 'all inside h6'
      || '</h6>'                                                          ||

    '<spacer height="10pt"/>'                                             ||
    '<p>The heading levels above demonstrate inline markup '              ||
    'inside <b>&lt;h1&gt;</b> through <b>&lt;h6&gt;</b>.  '            ||
    'When a heading contains any inline tag it routes through the same '  ||
    'PARA_RUNS engine as &lt;p&gt;, keeping all text on the same lines.'  ||
    '</p>',
    l_binds);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="headings_dept_' ||
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
