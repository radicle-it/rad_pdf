-- =============================================================================
-- apex_sample12.sql  -  Justified paragraph text in APEX (v1.5.0)
-- =============================================================================
--
-- WHAT THIS SHOWS
--   Two approaches to justified text in a layout-engine report:
--
--   Approach A (recommended for layout reports): define a custom style with
--   align_h = 'J', then pass that style name to rad_pdf.write. The layout
--   engine's render_flowable uses write_wrapped internally, passing the
--   style's align_h, so every paragraph in that style is automatically
--   justified without any canvas calls.
--
--   Approach B (canvas-only, same as docs/sample16.sql): call
--   rad_pdf_canvas.write_wrapped directly with p_align => 'J' for
--   absolute-positioned text blocks outside the layout flow.
--
-- KEY TECHNIQUES
--   - rad_pdf_styles.define to register a custom 'body_j' style with
--     align_h = 'J'; load_defaults must be called first
--   - rad_pdf.write(l_doc, p_text, p_style => 'body_j') for justified
--     layout-mode paragraphs
--   - Mixing a style change per paragraph: alternate 'body' and 'body_j'
--     to show the contrast in the same document
--   - Custom styles are session-scoped: they persist until load_defaults
--     is called again or the session ends
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
  l_fmt  rad_pdf_types.t_cell_format;
  i      PLS_INTEGER;

  l_today VARCHAR2(30) := TO_CHAR(SYSDATE, 'DD-MON-YYYY');

  c_intro CONSTANT VARCHAR2(4000) :=
    'This quarterly report provides a detailed overview of employee compensation '
    || 'across all departments. Each entry reflects the current base salary as '
    || 'recorded in the human resources system. Department managers should review '
    || 'the figures and flag any discrepancies to the HR team by the end of the '
    || 'current fiscal month. Salary adjustments approved after the report cut-off '
    || 'date will appear in the next scheduled release.';

  c_note CONSTANT VARCHAR2(4000) :=
    'This document is classified as confidential. Distribution is restricted to '
    || 'authorised personnel only. Any reproduction or disclosure outside the '
    || 'organisation requires prior written consent from the Finance Director.';

BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Approach A: define a custom justified body style
  -- The layout engine's render_flowable passes style.align_h to write_wrapped,
  -- so 'J' here automatically produces fully-justified paragraphs.
  -- =========================================================================
  l_fmt             := rad_pdf_styles.get('body');  -- clone from built-in body
  l_fmt.align_h     := 'J';
  rad_pdf_styles.define('body_j',
    p_font_name  => l_fmt.font_name,
    p_font_style => l_fmt.font_style,
    p_font_size  => l_fmt.font_size,
    p_font_color => l_fmt.font_color,
    p_align_h    => 'J');

  -- Also define a bold-justified variant for the notice box
  l_fmt             := rad_pdf_styles.get('body');
  l_fmt.align_h     := 'J';
  rad_pdf_styles.define('body_j_i',
    p_font_name  => l_fmt.font_name,
    p_font_style => 'I',
    p_font_size  => l_fmt.font_size,
    p_font_color => '555555',
    p_align_h    => 'J');

  -- =========================================================================
  -- Document
  -- =========================================================================
  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Opening section: comparison of L vs J alignment
  -- =========================================================================
  rad_pdf.heading(l_doc, 'Quarterly Salary Report', 1);
  rad_pdf.write(l_doc, 'Prepared by Finance Department  |  Date: ' || l_today, 'caption');
  rad_pdf.spacer(l_doc, 8);

  -- Left-aligned paragraph (default 'body' style)
  rad_pdf.heading(l_doc, 'Introduction (left-aligned)', 3);
  rad_pdf.write(l_doc, c_intro);       -- uses 'body' style = left-aligned

  rad_pdf.spacer(l_doc, 10);

  -- Justified paragraph (custom 'body_j' style)
  rad_pdf.heading(l_doc, 'Introduction (justified)', 3);
  rad_pdf.write(l_doc, c_intro, 'body_j');   -- same text, now justified

  rad_pdf.spacer(l_doc, 10);

  -- Confidentiality notice in italic justified
  rad_pdf.write(l_doc, c_note, 'body_j_i');

  rad_pdf.spacer(l_doc, 16);

  -- =========================================================================
  -- Column definitions for the employee table
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

  l_cols(3).label      := 'Dept';
  l_cols(3).width      := 50;
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
  -- Data table
  -- =========================================================================
  rad_pdf.heading(l_doc, 'Employee Salary Detail', 2);

  rad_pdf.query2table(l_doc,
    'SELECT TO_CHAR(e.empno),'
    || ' INITCAP(e.ename),'
    || ' INITCAP(d.dname),'
    || ' TO_CHAR(e.hiredate, ''DD-Mon-YYYY''),'
    || ' e.sal'
    || ' FROM emp e JOIN dept d ON d.deptno = e.deptno'
    || ' ORDER BY d.dname, e.ename',
    l_cols,
    p_colors => l_clr);

  -- Footer note, justified
  rad_pdf.spacer(l_doc, 12);
  rad_pdf.write(l_doc,
    'All figures are in local currency units. Bonus allocations and allowances '
    || 'are excluded from this report and are published separately through the '
    || 'compensation portal. Next scheduled report date: end of following quarter.',
    'body_j_i');

  -- =========================================================================
  -- Output
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: ' || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="justified_report.pdf"');
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
