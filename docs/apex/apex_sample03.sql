-- =============================================================================
-- apex_sample03.sql  -  Multi-section report: summary table + detail table
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A single PDF with two distinct report sections:
--     1. Department Summary  - one row per department (headcount + total salary)
--     2. Employee Details    - all employees with department name and hire date
--
--   Key techniques:
--   • Multiple rad_pdf.query2table calls in one document
--   • Different column definitions and color schemes per section
--   • rad_pdf.heading / rad_pdf.spacer to structure the page flow
--   • rad_pdf.write with the built-in 'caption' style for footnotes
--   • Explicit cell margins for comfortable padding (margin_bot, margin_top,
--     margin_left, margin_rgt must be set - Oracle EXTEND creates NULL records
--     and does not apply the TYPE-level defaults)
--
-- DATA
--   Uses the standard EMP and DEPT tables (always present in Oracle databases).
--
-- WHERE TO PUT THIS CODE
--   Processing → Execute Server-side Code
--   Point:  On Load - Before Header
--   Name:   Download Payroll Report
--
-- PREREQUISITES
--   RAD_PDF installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  i      PLS_INTEGER;

  l_sum_cols  rad_pdf_types.t_columns;
  l_sum_clr   rad_pdf_types.t_color_scheme;

  l_det_cols  rad_pdf_types.t_columns;
  l_det_clr   rad_pdf_types.t_color_scheme;

  l_today VARCHAR2(30) := TO_CHAR(SYSDATE, 'DD-MON-YYYY');
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Section 1 - Department Summary (4 columns, total width = 440 pt)
  -- =========================================================================
  l_sum_cols := rad_pdf_types.t_columns();
  l_sum_cols.EXTEND(4);

  -- Apply comfortable padding to all columns.
  -- Oracle EXTEND creates NULL records; type-level defaults are NOT applied.
  -- margin_bot positions the text baseline; margin_top contributes to row height.
  FOR i IN 1..4 LOOP
    l_sum_cols(i).data_fmt.margin_top  := 4;
    l_sum_cols(i).data_fmt.margin_bot  := 4;
    l_sum_cols(i).data_fmt.margin_left := 5;
    l_sum_cols(i).data_fmt.margin_rgt  := 5;
    l_sum_cols(i).header_fmt.margin_top  := 4;
    l_sum_cols(i).header_fmt.margin_bot  := 4;
    l_sum_cols(i).header_fmt.margin_left := 5;
    l_sum_cols(i).header_fmt.margin_rgt  := 5;
  END LOOP;

  l_sum_cols(1).label              := 'Dept#';
  l_sum_cols(1).width              := 55;
  l_sum_cols(1).data_fmt.align_h   := 'R';
  l_sum_cols(1).header_fmt.align_h := 'C';

  l_sum_cols(2).label := 'Department';
  l_sum_cols(2).width := 130;

  l_sum_cols(3).label              := 'Headcount';
  l_sum_cols(3).width              := 80;
  l_sum_cols(3).data_fmt.align_h   := 'R';
  l_sum_cols(3).header_fmt.align_h := 'C';

  l_sum_cols(4).label              := 'Total Salary';
  l_sum_cols(4).width              := 110;
  l_sum_cols(4).data_fmt.align_h   := 'R';
  l_sum_cols(4).header_fmt.align_h := 'C';
  l_sum_cols(4).data_fmt.num_format := 'FM999,999,990.00';

  l_sum_clr.header_paper  := '1E6B3C';
  l_sum_clr.header_ink    := 'FFFFFF';
  l_sum_clr.header_border := '1E6B3C';
  l_sum_clr.odd_paper     := 'EAF5EE';
  l_sum_clr.odd_border    := 'A9DFBF';
  l_sum_clr.even_paper    := 'FFFFFF';
  l_sum_clr.even_border   := 'A9DFBF';

  -- =========================================================================
  -- Section 2 - Employee Details (5 columns, total width = 490 pt)
  -- =========================================================================
  l_det_cols := rad_pdf_types.t_columns();
  l_det_cols.EXTEND(5);

  FOR i IN 1..5 LOOP
    l_det_cols(i).data_fmt.margin_top  := 4;
    l_det_cols(i).data_fmt.margin_bot  := 4;
    l_det_cols(i).data_fmt.margin_left := 5;
    l_det_cols(i).data_fmt.margin_rgt  := 5;
    l_det_cols(i).header_fmt.margin_top  := 4;
    l_det_cols(i).header_fmt.margin_bot  := 4;
    l_det_cols(i).header_fmt.margin_left := 5;
    l_det_cols(i).header_fmt.margin_rgt  := 5;
  END LOOP;

  l_det_cols(1).label := 'Name';
  l_det_cols(1).width := 110;

  l_det_cols(2).label := 'Job';
  l_det_cols(2).width := 90;

  l_det_cols(3).label := 'Department';
  l_det_cols(3).width := 110;

  l_det_cols(4).label              := 'Hired';
  l_det_cols(4).width              := 90;
  l_det_cols(4).data_fmt.align_h   := 'C';
  l_det_cols(4).header_fmt.align_h := 'C';

  l_det_cols(5).label              := 'Salary';
  l_det_cols(5).width              := 90;
  l_det_cols(5).data_fmt.align_h   := 'R';
  l_det_cols(5).header_fmt.align_h := 'C';
  l_det_cols(5).data_fmt.num_format := 'FM999,999,990.00';

  l_det_clr.header_paper  := '1A3A5C';
  l_det_clr.header_ink    := 'FFFFFF';
  l_det_clr.header_border := '1A3A5C';
  l_det_clr.odd_paper     := 'EBF2FA';
  l_det_clr.odd_border    := 'BDD5EC';
  l_det_clr.even_paper    := 'FFFFFF';
  l_det_clr.even_border   := 'BDD5EC';

  -- =========================================================================
  -- Build document
  -- =========================================================================
  l_doc := rad_pdf.new_document;

  rad_pdf.heading(l_doc, 'Payroll Report - ' || l_today, 1);
  rad_pdf.write  (l_doc,
    'Generated by: ' || V('APP_USER') ||
    '  |  Application: ' || NVL(V('APP_NAME'), 'APEX'));
  rad_pdf.spacer (l_doc, 10);

  rad_pdf.heading(l_doc, 'Department Summary', 2);
  rad_pdf.spacer (l_doc, 4);

  rad_pdf.query2table(l_doc,
    'SELECT d.deptno, d.dname, COUNT(e.empno), NVL(SUM(e.sal), 0) ' ||
    'FROM   dept d LEFT JOIN emp e ON e.deptno = d.deptno ' ||
    'GROUP BY d.deptno, d.dname ' ||
    'ORDER BY d.deptno',
    l_sum_cols,
    p_colors => l_sum_clr);

  rad_pdf.new_page(l_doc);

  rad_pdf.heading(l_doc, 'Employee Details', 2);
  rad_pdf.spacer (l_doc, 4);

  rad_pdf.query2table(l_doc,
    'SELECT e.ename, e.job, d.dname, ' ||
    '       TO_CHAR(e.hiredate, ''DD-MON-YYYY''), e.sal ' ||
    'FROM   emp  e ' ||
    'JOIN   dept d ON d.deptno = e.deptno ' ||
    'ORDER BY d.dname, e.ename',
    l_det_cols,
    p_colors => l_det_clr);

  rad_pdf.spacer(l_doc, 8);
  rad_pdf.write (l_doc,
    'Source: EMP / DEPT - data as of ' || l_today, 'caption');

  -- =========================================================================
  -- Stream to browser
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  owa_util.mime_header('application/pdf', FALSE);
  htp.p('Content-Length: ' || DBMS_LOB.getlength(l_pdf));
  htp.p('Content-Disposition: attachment; filename="payroll_' ||
        TO_CHAR(SYSDATE, 'YYYYMMDD') || '.pdf"');
  htp.p('Cache-Control: no-store, no-cache, must-revalidate');
  htp.p('Pragma: no-cache');
  owa_util.http_header_close;
  wpg_docload.download_file(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);

  apex_application.stop_apex_engine;
END;
