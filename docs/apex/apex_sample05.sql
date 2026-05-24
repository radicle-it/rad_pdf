-- =============================================================================
-- apex_sample05.sql  -  Cover page + paginated report with header from page 2
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A PDF where page 1 is a custom cover (logo, title, date) and pages 2+
--   carry a standard header and footer.  The key technique is the
--   IF #PAGE_NR# > 1 guard inside header_proc / footer_proc: both blocks are
--   executed for every page at finalize time, but the guard makes them a no-op
--   on the cover page.
--
-- KEY TECHNIQUES
--   • new_document without a template (template applied after logo is loaded)
--   • load_image called before set_template so the image ID can be embedded
--     as a literal in header_proc
--   • IF #PAGE_NR# > 1 THEN ... END IF  to skip header/footer on page 1
--   • rad_pdf.new_page forces page 2 after cover content
--   • rad_pdf.get_info(l_doc, rad_pdf_types.c_info_page_nr) to read the
--     current page number at any point during generation
--
-- NOTE ON LOCALS IN HEADER_PROC
--   PL/SQL locals (l_apex_user, l_today, l_logo_id) are out of scope when
--   header_proc runs via EXECUTE IMMEDIATE at finalize time.  Capture them
--   first and embed as literals in the proc string.
--
-- DATA
--   Uses the standard EMP and DEPT tables.
--
-- WHERE TO PUT THIS CODE
--   Processing → Execute Server-side Code
--   Point:  On Load - Before Header
--
-- PREREQUISITES
--   RAD_PDF installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc        rad_pdf_types.t_doc_handle;
  l_pdf        BLOB;
  l_tpl        rad_pdf_types.t_page_template;
  l_cols       rad_pdf_types.t_columns;
  l_clr        rad_pdf_types.t_color_scheme;
  l_logo_blob  BLOB;
  l_logo_id    PLS_INTEGER := NULL;
  i            PLS_INTEGER;

  -- Capture session values as literals for use inside header_proc
  l_apex_user  VARCHAR2(100) := NVL(V('APP_USER'), 'Unknown');
  l_today      VARCHAR2(30)  := TO_CHAR(SYSDATE, 'DD-MON-YYYY');
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Step 1: open document without template
  -- =========================================================================
  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Step 2: load logo so we have its ID before building header_proc
  -- =========================================================================
  BEGIN
    SELECT file_content
    INTO   l_logo_blob
    FROM   apex_application_static_files
    WHERE  application_id = :APP_ID
    AND    file_name      = 'radicle_logo.jpg';

    l_logo_id := rad_pdf_images.load_image(l_doc, l_logo_blob);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
    WHEN OTHERS        THEN NULL;
  END;

  -- =========================================================================
  -- Step 3: page template - A4 portrait
  --   header area : y = [772 .. 842]  (margin_top = 70)
  --   footer area : y = [0  ..  44]   (margin_bottom = 44)
  --   content area: y = [44 .. 772]
  -- =========================================================================
  l_tpl.page_format_name := 'A4';
  l_tpl.margin_top       := 70;
  l_tpl.margin_bottom    := 44;
  l_tpl.margin_left      := 42;
  l_tpl.margin_right     := 42;

  -- Header: skipped on page 1 (cover).  Pages 2+ show logo + title + page n/N.
  l_tpl.header_proc :=
    'BEGIN ' ||
    'IF #PAGE_NR# > 1 THEN ' ||
    CASE WHEN l_logo_id IS NOT NULL THEN
      'rad_pdf_canvas.put_image(' ||
        '#DOC_HANDLE#, ' || TO_CHAR(l_logo_id) || ', ' ||
        '42, 826, 30, 30, ''L'', ''T'', ''pt''); '
    END ||
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''B'', 9); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''1A3A5C''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''Payroll Report - ' || l_today || ''', ' ||
      CASE WHEN l_logo_id IS NOT NULL THEN '80' ELSE '42' END ||
      ', 820, ''pt''); ' ||
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''N'', 8); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''555555''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''Page #PAGE_NR# of #PAGE_COUNT#'', 460, 820, ''pt''); ' ||
    'rad_pdf_canvas.h_line(#DOC_HANDLE#, 42, 778, 511, 0.5, ''1A3A5C'', ''pt''); ' ||
    'END IF; ' ||
    'END;';

  -- Footer: skipped on page 1 (cover).  Pages 2+ show a thin rule + notice.
  l_tpl.footer_proc :=
    'BEGIN ' ||
    'IF #PAGE_NR# > 1 THEN ' ||
    'rad_pdf_canvas.h_line(#DOC_HANDLE#, 42, 40, 511, 0.4, ''AAAAAA'', ''pt''); ' ||
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''I'', 7); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''888888''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''Confidential - internal use only - generated by RAD_PDF'', 42, 26, ''pt''); ' ||
    'END IF; ' ||
    'END;';

  rad_pdf_layout.set_template(l_doc, l_tpl);

  -- =========================================================================
  -- Step 4: cover page content (page 1 - no header, no footer)
  -- =========================================================================

  -- You can read the current page number at any time:
  -- l_current_pg := rad_pdf.get_info(l_doc, rad_pdf_types.c_info_page_nr);  -- = 1

  -- Place logo large on the cover
  IF l_logo_id IS NOT NULL THEN
    rad_pdf_canvas.put_image(l_doc, l_logo_id, 190, 650, 215, 80, 'L', 'T', 'pt');
  END IF;

  -- Cover title block
  rad_pdf.spacer(l_doc, 280);
  rad_pdf.heading(l_doc, 'Payroll Report', 1);
  rad_pdf.write  (l_doc, l_today, 'caption');
  rad_pdf.write  (l_doc, 'Prepared by: ' || l_apex_user, 'caption');

  -- Force page 2 - header/footer will appear from here onward
  rad_pdf.new_page(l_doc);

  -- =========================================================================
  -- Step 5: report content (pages 2+)
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
  END LOOP;

  l_cols(1).label              := 'Name';
  l_cols(1).width              := 110;

  l_cols(2).label              := 'Job';
  l_cols(2).width              := 90;

  l_cols(3).label              := 'Department';
  l_cols(3).width              := 110;

  l_cols(4).label              := 'Hired';
  l_cols(4).width              := 90;
  l_cols(4).data_fmt.align_h   := 'C';
  l_cols(4).header_fmt.align_h := 'C';

  l_cols(5).label              := 'Salary';
  l_cols(5).width              := 90;
  l_cols(5).data_fmt.align_h   := 'R';
  l_cols(5).header_fmt.align_h := 'C';
  l_cols(5).data_fmt.num_format := 'FM999,999,990.00';

  l_clr.header_paper  := '1A3A5C';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '1A3A5C';
  l_clr.odd_paper     := 'EBF2FA';
  l_clr.odd_border    := 'BDD5EC';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.even_border   := 'BDD5EC';

  rad_pdf.heading(l_doc, 'Employee Details', 2);
  rad_pdf.spacer (l_doc, 6);

  rad_pdf.query2table(l_doc,
    'SELECT e.ename, e.job, d.dname, ' ||
    '       TO_CHAR(e.hiredate, ''DD-MON-YYYY''), e.sal ' ||
    'FROM   emp  e ' ||
    'JOIN   dept d ON d.deptno = e.deptno ' ||
    'ORDER BY d.dname, e.ename',
    l_cols,
    p_colors => l_clr);

  -- =========================================================================
  -- Step 6: stream to browser
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  owa_util.mime_header('application/pdf', FALSE);
  htp.p('Content-Length: ' || DBMS_LOB.getlength(l_pdf));
  htp.p('Content-Disposition: attachment; filename="payroll_cover_' ||
        TO_CHAR(SYSDATE, 'YYYYMMDD') || '.pdf"');
  htp.p('Cache-Control: no-store, no-cache, must-revalidate');
  htp.p('Pragma: no-cache');
  owa_util.http_header_close;
  wpg_docload.download_file(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);

  apex_application.stop_apex_engine;
END;
