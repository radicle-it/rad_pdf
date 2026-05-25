-- =============================================================================
-- template_sample04.sql  -  Template engine: data table with <table>
-- =============================================================================
--
-- WHAT THIS SHOWS
--   • rad_pdf_template.register_columns — registers a named t_columns set so
--     the <table> tag can reference it by name.  Register once per session
--     (e.g. in an application init procedure or a database login trigger).
--   • <table> tag attributes:
--       columns="NAME"          registered column-set name (required)
--       query="SELECT ..."      SQL to execute (required)
--       allow_query="true"      tag-level opt-in for query execution (required)
--       row_height="Xpt"        fixed row height (optional)
--       header_bg="RRGGBB"      header background colour (optional)
--       alt_bg="RRGGBB"         alternating row colour (optional)
--       border_color="RRGGBB"   grid border colour (optional)
--       max_rows="N"            cap on rows returned (optional)
--   • Security double opt-in: query execution requires BOTH
--       (a) allow_query="true" on the <table> tag, AND
--       (b) p_options.allow_queries := TRUE on the render() call.
--     If either is missing, ORA-20815 is raised.
--   • Bind tokens (#KEY#) inside the query string are substituted before the
--     query runs, so you can inject a filter value safely from PL/SQL.
--     Never concatenate raw user input into the query string.
--
-- DATA
--   Uses EMP / DEPT.  Change l_deptno to 10, 20, or 40 as desired.
--
-- HOW TO RUN
--   Same as template_sample01.sql.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_binds  rad_pdf_types.t_bind_array;
  l_opts   rad_pdf_types.t_template_options;
  l_cols   rad_pdf_types.t_columns;

  -- Change this to 10, 20, or 40 to see a different department.
  l_deptno CONSTANT NUMBER := 30;

  l_dname  DEPT.DNAME%TYPE;
  l_loc    DEPT.LOC%TYPE;
BEGIN
  -- --------------------------------------------------------------------------
  -- 1. Register the column set.
  --    Names are case-insensitive; 'EMP_COLS' and 'emp_cols' are the same.
  --    Register once per session; call register_columns again to update.
  -- --------------------------------------------------------------------------
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(5);

  l_cols(1).label             := 'Emp #';
  l_cols(1).width             := 45;
  l_cols(1).data_fmt.align_h  := 'R';
  l_cols(1).header_fmt.align_h := 'C';

  l_cols(2).label             := 'Name';
  l_cols(2).width             := 120;

  l_cols(3).label             := 'Job';
  l_cols(3).width             := 100;

  l_cols(4).label             := 'Hired';
  l_cols(4).width             := 90;
  l_cols(4).data_fmt.align_h  := 'C';
  l_cols(4).header_fmt.align_h := 'C';

  l_cols(5).label               := 'Salary';
  l_cols(5).width               := 80;
  l_cols(5).data_fmt.align_h    := 'R';
  l_cols(5).data_fmt.num_format := 'FM999,990.00';

  rad_pdf_template.register_columns('EMP_COLS', l_cols);

  -- --------------------------------------------------------------------------
  -- 2. Resolve department header data.
  -- --------------------------------------------------------------------------
  SELECT dname, loc INTO l_dname, l_loc
    FROM dept WHERE deptno = l_deptno;

  l_binds(1).key   := 'DNAME';  l_binds(1).value := INITCAP(l_dname);
  l_binds(2).key   := 'LOC';    l_binds(2).value := INITCAP(l_loc);
  -- DEPTNO is used as a filter inside the query string below.
  -- The template engine substitutes #DEPTNO# in the query before executing it.
  l_binds(3).key   := 'DEPTNO'; l_binds(3).value := TO_CHAR(l_deptno);

  -- --------------------------------------------------------------------------
  -- 3. Options: allow queries (required for <table> to execute its query).
  -- --------------------------------------------------------------------------
  l_opts.allow_queries := TRUE;

  -- --------------------------------------------------------------------------
  -- 4. Render.
  -- --------------------------------------------------------------------------
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_template.render(l_doc,

    '<h1>#DNAME# — Employee Roster</h1>'                                        ||
    '<p>Location: <b>#LOC#</b>   |   Department: <b>#DEPTNO#</b></p>'          ||
    '<spacer height="6pt"/>'                                                    ||
    '<hr color="003366" width="1.5"/>'                                          ||
    '<spacer height="8pt"/>'                                                    ||

    -- <table> tag.
    -- query="..." runs with the caller's schema privileges at render time.
    -- #DEPTNO# is replaced by the bind value before the query executes.
    -- Column order in SELECT must match the registered column set.
    '<table columns="EMP_COLS"'
      || ' query="SELECT empno, ename, INITCAP(job),'
      ||          ' TO_CHAR(hiredate, ''DD-Mon-YYYY''), sal'
      ||        ' FROM emp WHERE deptno = #DEPTNO# ORDER BY ename"'
      || ' row_height="15pt"'
      || ' header_bg="003366"'
      || ' alt_bg="EAF0FB"'
      || ' border_color="AAAAAA"'
      || ' allow_query="true"/>'                                                ||

    '<spacer height="10pt"/>'                                                   ||
    '<p style="caption">Generated: '
      || TO_CHAR(SYSDATE, 'DD Month YYYY HH24:MI')
      || '</p>',

    l_binds,
    l_opts);

  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated — size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('Department ' || l_deptno || ' not found in DEPT.');
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
