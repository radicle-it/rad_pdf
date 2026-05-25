-- =============================================================================
-- template_sample05.sql  -  Template engine: multi-section document
-- =============================================================================
--
-- WHAT THIS SHOWS
--   Multiple render() calls on the same document handle are additive: each
--   call appends its content after the previous one.  Use this pattern to
--   compose a document from independent sections without concatenating one
--   giant template string.
--
--   Document structure:
--     Page 1   — cover page (no data, no binds)
--     Pages 2+ — one section per department: summary stats + employee table
--     Last page — end-of-report note
--
--   Key techniques:
--   • Register the column set once; all render() calls share it.
--   • Rebuild the bind array on each loop iteration (Oracle index-by arrays
--     have no cost-free "clear" method; simply overwrite the existing entries
--     when keys do not change).
--   • Use <pagebreak/> to separate sections.  The first section does not need
--     a leading pagebreak because the cover page's render() already ended the
--     page.
--   • t_template_options.allow_queries is set once and passed to every
--     render() call inside the loop.
--
-- DATA
--   Uses EMP / DEPT.
--
-- HOW TO RUN
--   Same as template_sample01.sql.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_opts   rad_pdf_types.t_template_options;
  l_cols   rad_pdf_types.t_columns;
  l_binds  rad_pdf_types.t_bind_array;

  CURSOR c_dept IS
    SELECT deptno, dname, loc FROM dept ORDER BY deptno;

  l_count    PLS_INTEGER;
  l_sum_sal  NUMBER;
  l_max_sal  NUMBER;
  l_first    BOOLEAN := TRUE;
BEGIN
  -- --------------------------------------------------------------------------
  -- 1. Register the shared column set once.
  --    It is used by every department section in the loop below.
  -- --------------------------------------------------------------------------
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(4);

  l_cols(1).label              := 'Name';
  l_cols(1).width              := 130;

  l_cols(2).label              := 'Job';
  l_cols(2).width              := 100;

  l_cols(3).label              := 'Hired';
  l_cols(3).width              := 90;
  l_cols(3).data_fmt.align_h   := 'C';
  l_cols(3).header_fmt.align_h := 'C';

  l_cols(4).label              := 'Salary';
  l_cols(4).width              := 80;
  l_cols(4).data_fmt.align_h   := 'R';
  l_cols(4).data_fmt.num_format := 'FM999,990.00';

  rad_pdf_template.register_columns('DEPT_EMP', l_cols);

  -- Options: allow <table> queries in every render() call inside the loop.
  l_opts.allow_queries := TRUE;

  -- --------------------------------------------------------------------------
  -- 2. Open the document and render the cover page (no binds needed).
  -- --------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    '<h1>Company HR Report</h1>'                                                ||
    '<spacer height="8pt"/>'                                                    ||
    '<hr color="003366" width="2"/>'                                            ||
    '<spacer height="8pt"/>'                                                    ||
    '<p>Salary and headcount summary by department.</p>'                        ||
    '<spacer height="20pt"/>'                                                   ||
    '<p style="caption">Generated: '
      || TO_CHAR(SYSDATE, 'DD Month YYYY HH24:MI')
      || '</p>');

  -- --------------------------------------------------------------------------
  -- 3. One render() call per department.
  --    Each call appends its content after the previous one.
  -- --------------------------------------------------------------------------
  FOR dept IN c_dept LOOP

    SELECT COUNT(*), NVL(SUM(sal), 0), NVL(MAX(sal), 0)
      INTO l_count, l_sum_sal, l_max_sal
      FROM emp WHERE deptno = dept.deptno;

    -- Rebuild the bind array for this iteration.
    l_binds(1).key   := 'DNAME';   l_binds(1).value := INITCAP(dept.dname);
    l_binds(2).key   := 'LOC';     l_binds(2).value := INITCAP(dept.loc);
    l_binds(3).key   := 'DEPTNO';  l_binds(3).value := TO_CHAR(dept.deptno);
    l_binds(4).key   := 'COUNT';   l_binds(4).value := TO_CHAR(l_count);
    l_binds(5).key   := 'SUM_SAL'; l_binds(5).value := TO_CHAR(l_sum_sal, 'FM999,990.00');
    l_binds(6).key   := 'MAX_SAL'; l_binds(6).value := TO_CHAR(l_max_sal, 'FM999,990.00');

    rad_pdf_template.render(l_doc,

      -- <pagebreak/> before every section except the very first.
      -- (The cover page already ends on its own page.)
      CASE WHEN NOT l_first THEN '<pagebreak/>' ELSE '' END                    ||

      '<h1><color rgb="003366">#DNAME#</color></h1>'                           ||
      '<p>Location: <b>#LOC#</b>   |   '
        || 'Employees: <b>#COUNT#</b>   |   '
        || 'Total payroll: <b>#SUM_SAL#</b>   |   '
        || 'Highest salary: <b>#MAX_SAL#</b></p>'                              ||
      '<spacer height="8pt"/>'                                                  ||
      '<hr color="AAAAAA" width="0.5"/>'                                        ||
      '<spacer height="6pt"/>'                                                  ||

      -- <table> uses the registered 'DEPT_EMP' column set.
      -- #DEPTNO# in the query string is replaced by the bind value above.
      '<table columns="DEPT_EMP"'
        || ' query="SELECT ename, INITCAP(job),'
        ||          ' TO_CHAR(hiredate, ''DD-Mon-YYYY''), sal'
        ||        ' FROM emp WHERE deptno = #DEPTNO# ORDER BY ename"'
        || ' row_height="14pt"'
        || ' header_bg="003366"'
        || ' alt_bg="F0F4FF"'
        || ' border_color="CCCCCC"'
        || ' allow_query="true"/>',

      l_binds,
      l_opts);

    l_first := FALSE;

  END LOOP;

  -- --------------------------------------------------------------------------
  -- 4. Append the back page.
  -- --------------------------------------------------------------------------
  rad_pdf_template.render(l_doc,
    '<pagebreak/>'                                                              ||
    '<h2>End of Report</h2>'                                                   ||
    '<p>Data sourced from the <b>EMP</b> and <b>DEPT</b> tables.</p>'          ||
    '<spacer height="8pt"/>'                                                    ||
    '<p style="caption">Generated by RAD_PDF template engine.</p>');

  -- --------------------------------------------------------------------------
  -- 5. Finalize.
  -- --------------------------------------------------------------------------
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
