-- apex_template_08.sql  —  Data table: <table columns="…" query="…">
-- ===========================================================================
--
-- WHAT THIS SHOWS
--   Embedding a live SQL query result as a formatted table:
--
--     <table columns="COLUMN_SET_NAME"
--            query="SELECT col1, col2, … FROM … WHERE …"
--            allow_query="true"
--            [row_height="Xpt"]
--            [max_rows="N"]
--            [header_bg="RRGGBB"]
--            [alt_bg="RRGGBB"]
--            [border_color="RRGGBB"]/>
--
--   DOUBLE OPT-IN SECURITY:
--     Both allow_query="true" in the tag AND
--     p_options.allow_queries = TRUE must be set.
--     This prevents accidental query execution from untrusted templates.
--
--   COLUMN SET:
--     Must be pre-registered via rad_pdf_template.register_columns(name, t_columns).
--     Do this in an Application Process that runs On New Session.
--
--   BIND VALUES IN QUERIES:
--     #TOKEN# in the query attribute is replaced by the bind value BEFORE the
--     SQL is executed.  Always validate numeric values via TO_NUMBER before
--     placing them in a bind to prevent SQL injection.
--
-- APEX SETUP
--   Page item: P1_DEPTNO
--   Application Process (On New Session): register column sets (see bottom).
--   Process: Execute Server-side Code — On Load - Before Header
-- ===========================================================================

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_opts   rad_pdf_types.t_template_options;
  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;
  l_count  PLS_INTEGER;

BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Resolve department data
  -- -------------------------------------------------------------------------
  SELECT dname, loc INTO l_dname, l_loc
    FROM dept WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  SELECT COUNT(*) INTO l_count FROM emp WHERE deptno = TO_NUMBER(:P1_DEPTNO);

  -- -------------------------------------------------------------------------
  -- 2. Binds
  --
  --    #DEPTNO# appears inside the <table query="…"> attribute.
  --    It is replaced verbatim in the SQL string before execution, so it
  --    must be a clean numeric value — validated by TO_NUMBER above.
  -- -------------------------------------------------------------------------
  l_binds(1).key := 'DNAME';   l_binds(1).value := l_dname;
  l_binds(2).key := 'LOC';     l_binds(2).value := INITCAP(l_loc);
  l_binds(3).key := 'DEPTNO';  l_binds(3).value := TO_CHAR(TO_NUMBER(:P1_DEPTNO));
  l_binds(4).key := 'COUNT';   l_binds(4).value := TO_CHAR(l_count);
  l_binds(5).key := 'GEN_DATE';l_binds(5).value := TO_CHAR(SYSDATE,'DD-Mon-YYYY HH24:MI');

  -- -------------------------------------------------------------------------
  -- 3. Options: allow_queries MUST be TRUE for <table> tags to execute
  -- -------------------------------------------------------------------------
  l_opts.allow_queries := TRUE;

  -- -------------------------------------------------------------------------
  -- 4. Render
  --
  --    The <table> tag fires a SQL query at render time.  The column set
  --    "EMP_ROSTER" must have been registered in the current database session
  --    (see the On New Session process below).
  --
  --    Color attributes accept 6-char hex RGB:
  --      header_bg      = header row background
  --      alt_bg         = odd-row background (even rows are white)
  --      border_color   = colour of all cell borders
  -- -------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,
    '<h1>Employee Roster — #DNAME#</h1>'                                  ||
    '<p>Location: <b>#LOC#</b>   Total employees: <b>#COUNT#</b></p>'    ||

    '<spacer height="6pt"/>'                                              ||
    '<hr color="003366"/>'                                                ||
    '<spacer height="10pt"/>'                                             ||

    -- -----------------------------------------------------------------------
    -- The <table> tag.
    --   columns     = name registered with register_columns()
    --   query       = SQL SELECT; must return exactly as many columns as the
    --                 column set has entries (in the same order).
    --                 #DEPTNO# is a bind token — replaced before execution.
    --   allow_query = must be "true" (tag-level opt-in)
    --   row_height  = fixed height for every data row in pt (optional)
    --   header_bg   = background colour of the header row
    --   alt_bg      = alternating background for odd-numbered data rows
    --   border_color= colour for all borders
    -- -----------------------------------------------------------------------
    '<table columns="EMP_ROSTER"'
      || ' query="SELECT empno,'
      ||           ' ename,'
      ||           ' INITCAP(job),'
      ||           ' TO_CHAR(hiredate, ''DD-Mon-YYYY''),'
      ||           ' sal'
      ||        ' FROM emp'
      ||       ' WHERE deptno = #DEPTNO#'
      ||       ' ORDER BY ename"'
      || ' row_height="16pt"'
      || ' header_bg="003366"'
      || ' alt_bg="EAF0FB"'
      || ' border_color="AAAAAA"'
      || ' allow_query="true"/>'                                          ||

    '<spacer height="10pt"/>'                                             ||
    '<p style="caption">Generated: #GEN_DATE#</p>',
    l_binds,
    l_opts);

  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="roster_dept_' ||
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

-- ===========================================================================
-- APPLICATION PROCESS (On New Session) — register the EMP_ROSTER column set.
-- Paste this separately into an Application Process in APEX App Builder:
--   Shared Components → Application Processes → Create
--   Name:  RAD_PDF Session Init
--   Point: On New Session
-- ===========================================================================
/*
BEGIN
  rad_pdf_styles.load_defaults;

  DECLARE
    l_cols rad_pdf_types.t_columns := rad_pdf_types.t_columns();
  BEGIN
    l_cols.EXTEND(5);

    l_cols(1).label              := 'No';
    l_cols(1).width              := 42;
    l_cols(1).header_fmt.align_h := 'C';
    l_cols(1).data_fmt.align_h   := 'C';

    l_cols(2).label := 'Name';    l_cols(2).width := 110;
    l_cols(3).label := 'Job';     l_cols(3).width := 90;

    l_cols(4).label              := 'Hired';
    l_cols(4).width              := 80;
    l_cols(4).header_fmt.align_h := 'C';
    l_cols(4).data_fmt.align_h   := 'C';

    l_cols(5).label               := 'Salary';
    l_cols(5).width               := 64;
    l_cols(5).header_fmt.align_h  := 'R';
    l_cols(5).data_fmt.align_h    := 'R';
    l_cols(5).data_fmt.num_format := '999,990.00';

    rad_pdf_template.register_columns('EMP_ROSTER', l_cols);
  END;
END;
*/
