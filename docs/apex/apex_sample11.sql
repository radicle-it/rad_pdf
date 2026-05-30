-- =============================================================================
-- apex_sample11.sql  -  Line dash patterns in APEX (v1.5.0)
-- =============================================================================
--
-- WHAT THIS SHOWS
--   How to use rad_pdf.set_line_dash inside an APEX page process to add
--   dashed decorative rules and borders to a table report. The dashed top
--   and bottom rules frame the report; a dashed separator line sits between
--   the company header and the table.
--
-- KEY TECHNIQUES
--   - rad_pdf.set_line_dash(l_doc, p_dash, p_gap, p_phase, p_unit)
--     called from rad_pdf (public facade) - same API in both APEX and non-APEX
--   - Dash state persists until explicitly reset; always call set_line_dash(l_doc, 0)
--     before switching to a different dash or before solid paths
--   - Header/footer callbacks (header_proc / footer_proc) execute AFTER the render
--     pass; set_line_dash calls inside them follow the same rules
--   - Colors and line width are per-call parameters on each drawing primitive
--     (h_line, line, rect etc.); there are no persistent set_draw_color /
--     set_line_width setters in this version
--
-- WHERE TO PUT THIS CODE
--   Processing -> Execute Server-side Code
--   Point:  On Load - Before Header
--
-- PAGE ITEMS REQUIRED
--   None.
--
-- DATA
--   Uses EMP / DEPT (Scott schema). Replace with your own query.
--
-- PREREQUISITES
--   RAD_PDF v1.5.0+ installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc  rad_pdf_types.t_doc_handle;
  l_pdf  BLOB;
  l_cols rad_pdf_types.t_columns;
  l_clr  rad_pdf_types.t_color_scheme;
  l_tmpl rad_pdf_types.t_page_template;
  i      PLS_INTEGER;

  l_today VARCHAR2(30) := TO_CHAR(SYSDATE, 'DD-MON-YYYY');

BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Page template: header callback draws a dashed rule below the header area
  -- =========================================================================
  l_tmpl.margin_top    := 100;
  l_tmpl.margin_bottom := 80;
  l_tmpl.margin_left   := 40;
  l_tmpl.margin_right  := 40;

  -- Header callback: company name + dashed separator.
  -- h_line accepts p_color and p_line_width as per-call parameters.
  l_tmpl.header_proc :=
    'DECLARE '
    || '  l_pw NUMBER := rad_pdf.get_info(:doc, rad_pdf_types.c_info_page_width); '
    || '  l_ml NUMBER := rad_pdf.get_info(:doc, rad_pdf_types.c_info_margin_left); '
    || '  l_mr NUMBER := rad_pdf.get_info(:doc, rad_pdf_types.c_info_margin_right); '
    || '  l_cw NUMBER := l_pw - l_ml - l_mr; '
    || 'BEGIN '
    || '  rad_pdf_canvas.set_font(:doc, ''Helvetica'', ''B'', 14); '
    || '  rad_pdf_canvas.write_text(:doc, ''Acme Corp - Employee Report'', l_ml, 810); '
    || '  rad_pdf_canvas.set_font(:doc, ''Helvetica'', ''N'', 9); '
    || '  rad_pdf_canvas.write_text(:doc, ''Page #PAGE_NR# of #PAGE_COUNT#   Generated: '
    ||      l_today || ''', l_ml, 795); '
    || '  rad_pdf.set_line_dash(:doc, 3, p_gap => 3, p_unit => ''mm''); '
    || '  rad_pdf_canvas.h_line(:doc, l_ml, 786, l_cw, '
    || '    p_line_width => 1.5, p_color => ''003366''); '
    || '  rad_pdf.set_line_dash(:doc, 0); '
    || 'END;';

  -- Footer callback: dashed rule above footer, confidentiality note.
  l_tmpl.footer_proc :=
    'DECLARE '
    || '  l_pw NUMBER := rad_pdf.get_info(:doc, rad_pdf_types.c_info_page_width); '
    || '  l_ml NUMBER := rad_pdf.get_info(:doc, rad_pdf_types.c_info_margin_left); '
    || '  l_mr NUMBER := rad_pdf.get_info(:doc, rad_pdf_types.c_info_margin_right); '
    || '  l_cw NUMBER := l_pw - l_ml - l_mr; '
    || 'BEGIN '
    || '  rad_pdf.set_line_dash(:doc, 2, p_gap => 4, p_unit => ''mm''); '
    || '  rad_pdf_canvas.h_line(:doc, l_ml, 68, l_cw, '
    || '    p_line_width => 1, p_color => ''888888''); '
    || '  rad_pdf.set_line_dash(:doc, 0); '
    || '  rad_pdf_canvas.set_font(:doc, ''Helvetica'', ''I'', 8); '
    || '  rad_pdf_canvas.write_text(:doc, ''Confidential - internal use only'', l_ml, 55); '
    || 'END;';

  l_doc := rad_pdf.new_document(p_template => l_tmpl);

  -- =========================================================================
  -- Column definitions
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(5);

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

  l_cols(1).label              := 'No';
  l_cols(1).width              := 42;
  l_cols(1).header_fmt.align_h := 'C';
  l_cols(1).data_fmt.align_h   := 'C';

  l_cols(2).label      := 'Name';
  l_cols(2).width      := 50;
  l_cols(2).auto_width := TRUE;

  l_cols(3).label      := 'Job';
  l_cols(3).width      := 40;
  l_cols(3).auto_width := TRUE;

  l_cols(4).label              := 'Hired';
  l_cols(4).width              := 50;
  l_cols(4).auto_width         := TRUE;
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.align_h   := 'C';

  l_cols(5).label               := 'Salary';
  l_cols(5).width               := 72;
  l_cols(5).header_fmt.align_h  := 'R';
  l_cols(5).data_fmt.align_h    := 'R';
  l_cols(5).data_fmt.num_format := '999,990.00';

  -- =========================================================================
  -- Color scheme
  -- =========================================================================
  l_clr.header_paper  := '1A3A5C';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '1A3A5C';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.odd_paper     := 'EAF0FB';
  l_clr.even_border   := 'AAAAAA';
  l_clr.odd_border    := 'AAAAAA';

  -- =========================================================================
  -- Document content
  -- =========================================================================
  rad_pdf.heading(l_doc, 'Employee Salary Report', 1);
  rad_pdf.write(l_doc,
    'This report demonstrates dashed decorative rules in the header '
    || 'and footer callbacks, applied with rad_pdf.set_line_dash.');
  rad_pdf.spacer(l_doc, 10);

  rad_pdf.query2table(l_doc,
    'SELECT TO_CHAR(empno),'
    || ' INITCAP(ename),'
    || ' INITCAP(job),'
    || ' TO_CHAR(hiredate, ''DD-Mon-YYYY''),'
    || ' sal'
    || ' FROM emp'
    || ' ORDER BY deptno, ename',
    l_cols,
    p_colors => l_clr);

  -- =========================================================================
  -- Output
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="dash_report.pdf"');
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
