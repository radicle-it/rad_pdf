-- =============================================================================
-- apex_sample08.sql  -  Auto-width columns
-- =============================================================================
--
-- WHAT THIS SHOWS
--   Columns whose width adapts automatically to the widest cell value.
--   No manual width tuning is required: the engine measures each cell
--   using actual font metrics and assigns the minimum width that fits
--   the content without clipping.
--
-- KEY TECHNIQUES
--   - auto_width = TRUE on t_column_def: width derived from content
--   - width acts as a minimum floor (column is never narrower than declared)
--   - max_width caps the result (useful for free-text / description columns)
--   - Fixed-width columns (auto_width = FALSE) coexist with auto-width ones
--   - num_format is honoured: the formatted display string is measured,
--     not the raw numeric value
--   - Oracle EXTEND creates NULL records: all margin fields must be set explicitly
--
-- COLUMN STRATEGY IN THIS EXAMPLE
--   EmpNo   - fixed 42 pt  (always a 4-digit number, size is predictable)
--   Name    - auto-width   (fits the longest employee name)
--   Job     - auto-width   (fits the longest job title)
--   Hired   - auto-width   (formatted date string, length varies by locale)
--   Salary  - auto-width + max_width 80 pt + num_format (right-aligned amount)
--
-- DATA
--   Uses EMP / DEPT (Scott schema).  Replace with your own query as needed.
--
-- WHERE TO PUT THIS CODE
--   Processing -> Execute Server-side Code
--   Point:  On Load - Before Header
--
-- PREREQUISITES
--   RAD_PDF v1.3.0+ installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  l_clr  rad_pdf_types.t_color_scheme;
  i      PLS_INTEGER;

  l_today VARCHAR2(30) := TO_CHAR(SYSDATE, 'DD-MON-YYYY');
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Column definitions
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(5);

  -- Oracle EXTEND creates NULL records; set all margin fields explicitly.
  FOR i IN 1..5 LOOP
    l_cols(i).data_fmt.margin_top    := 4;
    l_cols(i).data_fmt.margin_bot    := 4;
    l_cols(i).data_fmt.margin_left   := 5;
    l_cols(i).data_fmt.margin_rgt    := 5;
    l_cols(i).header_fmt.margin_top  := 4;
    l_cols(i).header_fmt.margin_bot  := 4;
    l_cols(i).header_fmt.margin_left := 5;
    l_cols(i).header_fmt.margin_rgt  := 5;
    l_cols(i).header_fmt.font_style  := 'B';
    l_cols(i).header_fmt.back_color  := '1A3A5C';
    l_cols(i).header_fmt.font_color  := 'FFFFFF';
    l_cols(i).header_fmt.border      := rad_pdf_types.c_border_all;
    l_cols(i).data_fmt.border        := rad_pdf_types.c_border_all;
  END LOOP;

  -- Col 1: EmpNo - fixed width (always a short number)
  l_cols(1).label              := 'No';
  l_cols(1).width              := 42;       -- fixed, no auto_width
  l_cols(1).header_fmt.align_h := 'C';
  l_cols(1).data_fmt.align_h   := 'C';

  -- Col 2: Name - auto-width (longest name drives the column)
  l_cols(2).label      := 'Name';
  l_cols(2).width      := 50;       -- minimum floor
  l_cols(2).auto_width := TRUE;

  -- Col 3: Job - auto-width
  l_cols(3).label      := 'Job';
  l_cols(3).width      := 40;
  l_cols(3).auto_width := TRUE;

  -- Col 4: Hire date - auto-width (formatted date, length varies)
  l_cols(4).label              := 'Hired';
  l_cols(4).width              := 50;
  l_cols(4).auto_width         := TRUE;
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.align_h   := 'C';

  -- Col 5: Salary - auto-width with a cap; right-aligned formatted number
  l_cols(5).label                  := 'Salary';
  l_cols(5).width                  := 50;
  l_cols(5).auto_width             := TRUE;
  l_cols(5).max_width              := 80;   -- cap: salary strings never exceed this
  l_cols(5).header_fmt.align_h     := 'R';
  l_cols(5).data_fmt.align_h       := 'R';
  l_cols(5).data_fmt.num_format    := '999,990.00';

  -- =========================================================================
  -- Color scheme
  -- =========================================================================
  l_clr.even_paper    := 'FFFFFF';
  l_clr.odd_paper     := 'EAF0FB';
  l_clr.even_border   := 'AAAAAA';
  l_clr.odd_border    := 'AAAAAA';
  l_clr.header_border := '1A3A5C';

  -- =========================================================================
  -- Title + table
  -- =========================================================================
  rad_pdf.add_heading(l_doc, 'Employee Roster', 1);
  rad_pdf.add_paragraph(l_doc,
    'Column widths adapt automatically to cell content. '
    || 'No and Salary columns are fixed or capped; Name, Job, and Hired are auto-sized.');

  rad_pdf.add_table(l_doc,
    'SELECT TO_CHAR(empno),'
    || ' INITCAP(ename),'
    || ' INITCAP(job),'
    || ' TO_CHAR(hiredate, ''DD-Mon-YYYY''),'
    || ' sal'
    || ' FROM emp'
    || ' ORDER BY ename',
    l_cols,
    l_clr);

  rad_pdf.add_paragraph(l_doc, 'Generated: ' || l_today);

  -- =========================================================================
  -- Output
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="employee_roster.pdf"');
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
