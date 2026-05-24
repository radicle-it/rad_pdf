-- =============================================================================
-- apex_sample00.sql  -  Professional letterhead: logo, company info, page header/footer
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A production-ready PDF template with a full company letterhead:
--   • Page header: company logo (top-left), company name and address (right of
--     logo), page N of M counter (top-right), horizontal separator rule
--   • Page footer: document title (left), page N of M (right), horizontal rule
--   • Uses rad_pdf_layout.set_template after loading the logo, so the logo
--     image ID can be embedded as a literal in the header_proc string
--
-- LOGO STORAGE - choose one option:
--
--   Option A - Database BLOB table (recommended)
--     Create the table once and insert your logo:
--
--       CREATE TABLE app_images (
--         name      VARCHAR2(100) PRIMARY KEY,
--         mime_type VARCHAR2(50)  NOT NULL,
--         img_data  BLOB          NOT NULL
--       );
--
--     Upload the logo via APEX SQL Workshop → SQL Scripts, or with any tool that
--     can write LOBs.  Name the row 'company_logo'.
--
--     Advantages: no ACL needed, survives URL changes, works behind firewalls.
--
--   Option B - HTTPS URL
--     If the logo is already hosted, replace the BLOB query block with:
--
--       l_logo_id := rad_pdf_images.load_image(l_doc, 'https://yourhost/logo.png');
--
--     Requires a UTL_HTTP ACL that grants the schema access to the host.
--
--   Option C - APEX static files (APEX 21.2+)
--     APEX static files are reachable via URL; combine with Option B:
--
--       l_logo_id := rad_pdf_images.load_image(
--                      l_doc, V('APP_IMAGES') || 'logo.png');
--
--   If the logo cannot be loaded for any reason the document is still generated
--   without it - the EXCEPTION block swallows loading errors gracefully.
--
-- CUSTOMISE
--   Edit the four constants at the top of the DECLARE section.
--
-- DATA
--   Uses the standard EMP and DEPT tables (always present in Oracle databases).
--
-- WHERE TO PUT THIS CODE
--   Processing → Execute Server-side Code
--   Point:  On Load - Before Header
--   Name:   Download Employee Report
--
-- PREREQUISITES
--   RAD_PDF installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc       rad_pdf_types.t_doc_handle;
  l_pdf       BLOB;
  l_info      rad_pdf_types.t_doc_info;
  l_tpl       rad_pdf_types.t_page_template;
  l_cols      rad_pdf_types.t_columns;
  l_clr       rad_pdf_types.t_color_scheme;
  l_logo_blob BLOB;
  l_logo_id   PLS_INTEGER := NULL;
  i           PLS_INTEGER;

  -- ── CUSTOMISE THESE LINES ──────────────────────────────────────────────────
  l_company   CONSTANT VARCHAR2(100) := 'Acme Corporation';
  l_address   CONSTANT VARCHAR2(100) := '123 Business Street - Milan, Italy';
  l_doc_title CONSTANT VARCHAR2(100) := 'Employee Listing - HR Department';
  -- ──────────────────────────────────────────────────────────────────────────

  l_apex_user VARCHAR2(100) := NVL(V('APP_USER'),
                                   SYS_CONTEXT('USERENV', 'SESSION_USER'));
  l_today     VARCHAR2(30)  := TO_CHAR(SYSDATE, 'DD-MON-YYYY');
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Step 1: document metadata (PDF viewer File → Properties)
  -- =========================================================================
  l_info.title    := l_company || ' - ' || l_doc_title;
  l_info.author   := l_apex_user;
  l_info.subject  := l_doc_title || ' generated ' || l_today;
  l_info.keywords := 'RAD_PDF APEX HR employees ' || l_today;

  -- =========================================================================
  -- Step 2: start document - template applied later so we can embed logo ID
  -- =========================================================================
  l_doc := rad_pdf.new_document(p_info => l_info);

  -- =========================================================================
  -- Step 3: load logo (Option A - BLOB table; swap for Option B/C if preferred)
  --         A missing table or missing row produces no logo, not an error.
  -- =========================================================================
  BEGIN
    SELECT file_content
    INTO   l_logo_blob
    FROM   apex_application_static_files
    WHERE  application_id = :APP_ID
    AND    file_name      = 'radicle_logo.png';

    l_logo_id := rad_pdf_images.load_image(l_doc, l_logo_blob);
    -- Note: l_logo_blob is a persistent LOB locator (not temporary) - no FREETEMPORARY needed.
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;  -- file not uploaded yet: proceed without logo
    WHEN OTHERS        THEN NULL;  -- unsupported format (e.g. RGBA PNG not yet supported):
                                   -- proceed without logo; check APEX debug log for details
  END;

  -- =========================================================================
  -- Step 4: page template - A4 portrait with room for header and footer
  --
  --   A4 page height = 842 pt.  Coordinate origin is the bottom-left corner.
  --   Header area  : y = [752 .. 842]   (margin_top = 90)
  --   Footer area  : y = [0  ..  52]    (margin_bottom = 52)
  --   Content area : y = [52 .. 752]
  --
  --   Logo  : top at y=828 → occupies y=[788, 828], x=[42, 82]  (40×40 pt)
  --   Names : company name baseline y=823, address y=810         x=90
  --   Page# : baseline y=817                                     x=455
  --   Rule  : y=757 (5 pt above content area)
  --
  --   Footer rule at y=44; text baselines at y=28.
  -- =========================================================================
  l_tpl.page_format_name := 'A4';
  l_tpl.margin_top       := 90;
  l_tpl.margin_bottom    := 52;
  l_tpl.margin_left      := 42;
  l_tpl.margin_right     := 42;

  -- Header: logo | company block | page counter | separator rule
  l_tpl.header_proc :=
    'BEGIN ' ||
    -- Logo (only when loaded; l_logo_id is a literal integer in the string)
    CASE WHEN l_logo_id IS NOT NULL THEN
      'rad_pdf_canvas.put_image(' ||
        '#DOC_HANDLE#, ' || TO_CHAR(l_logo_id) || ', ' ||
        '42, 828, 40, 40, ''L'', ''T'', ''pt''); '
    END ||
    -- Company name (bold, brand colour)
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''B'', 10); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''1A3A5C''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''' || REPLACE(l_company, '''', '''''') || ''', 90, 823, ''pt''); ' ||
    -- Company address (normal, grey)
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''N'', 8); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''555555''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''' || REPLACE(l_address, '''', '''''') || ''', 90, 810, ''pt''); ' ||
    -- Page N of M (top-right, grey)
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''N'', 8); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''888888''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''Page #PAGE_NR# of #PAGE_COUNT#'', 455, 817, ''pt''); ' ||
    -- Separator rule
    'rad_pdf_canvas.h_line(#DOC_HANDLE#, 42, 757, 511, 0.5, ''1A3A5C'', ''pt''); ' ||
    'END;';

  -- Footer: thin rule + document title (left) + page counter (right)
  l_tpl.footer_proc :=
    'BEGIN ' ||
    'rad_pdf_canvas.h_line(#DOC_HANDLE#, 42, 44, 511, 0.4, ''AAAAAA'', ''pt''); ' ||
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''I'', 7); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''888888''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''' || REPLACE(l_doc_title, '''', '''''') || ''', 42, 28, ''pt''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''Page #PAGE_NR# of #PAGE_COUNT#'', 455, 28, ''pt''); ' ||
    'END;';

  rad_pdf_layout.set_template(l_doc, l_tpl);

  -- =========================================================================
  -- Step 5: column definitions - EMP + DEPT (6 columns, total width = 510 pt)
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(6);

  FOR i IN 1..6 LOOP
    l_cols(i).data_fmt.margin_top    := 4;
    l_cols(i).data_fmt.margin_bot    := 4;
    l_cols(i).data_fmt.margin_left   := 5;
    l_cols(i).data_fmt.margin_rgt    := 5;
    l_cols(i).header_fmt.margin_top  := 4;
    l_cols(i).header_fmt.margin_bot  := 4;
    l_cols(i).header_fmt.margin_left := 5;
    l_cols(i).header_fmt.margin_rgt  := 5;
  END LOOP;

  l_cols(1).label              := 'Emp#';
  l_cols(1).width              := 50;
  l_cols(1).data_fmt.align_h   := 'R';
  l_cols(1).header_fmt.align_h := 'C';

  l_cols(2).label := 'Name';
  l_cols(2).width := 100;

  l_cols(3).label := 'Job';
  l_cols(3).width := 90;

  l_cols(4).label := 'Department';
  l_cols(4).width := 100;

  l_cols(5).label              := 'Hired';
  l_cols(5).width              := 90;
  l_cols(5).data_fmt.align_h   := 'C';
  l_cols(5).header_fmt.align_h := 'C';

  l_cols(6).label              := 'Salary';
  l_cols(6).width              := 80;
  l_cols(6).data_fmt.align_h   := 'R';
  l_cols(6).header_fmt.align_h := 'C';
  l_cols(6).data_fmt.num_format := 'FM999,999,990.00';

  -- =========================================================================
  -- Color scheme - slate blue
  -- =========================================================================
  l_clr.header_paper  := '2C3E6B';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '2C3E6B';
  l_clr.odd_paper     := 'F0F2F8';
  l_clr.odd_border    := 'C5CCE0';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.even_border   := 'C5CCE0';

  -- =========================================================================
  -- Step 6: document content
  -- =========================================================================
  rad_pdf.heading(l_doc, l_doc_title, 1);
  rad_pdf.write  (l_doc,
    'Prepared by: ' || l_apex_user ||
    '  |  Date: '   || l_today);
  rad_pdf.spacer (l_doc, 8);

  rad_pdf.query2table(l_doc,
    'SELECT e.empno, e.ename, e.job, d.dname, ' ||
    '       TO_CHAR(e.hiredate, ''DD-MON-YYYY''), e.sal ' ||
    'FROM   emp  e ' ||
    'JOIN   dept d ON d.deptno = e.deptno ' ||
    'ORDER BY d.dname, e.ename',
    l_cols,
    p_colors => l_clr);

  rad_pdf.spacer(l_doc, 8);
  rad_pdf.write (l_doc,
    'Application: ' || NVL(V('APP_NAME'),    'HR Reports') ||
    '  |  Session: ' || NVL(V('APP_SESSION'), 'N/A'), 'caption');

  -- =========================================================================
  -- Step 7: stream to browser
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  owa_util.mime_header('application/pdf', FALSE);
  htp.p('Content-Length: ' || DBMS_LOB.getlength(l_pdf));
  htp.p('Content-Disposition: attachment; filename="employees_' ||
        TO_CHAR(SYSDATE, 'YYYYMMDD') || '.pdf"');
  htp.p('Cache-Control: no-store, no-cache, must-revalidate');
  htp.p('Pragma: no-cache');
  owa_util.http_header_close;
  wpg_docload.download_file(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);

  apex_application.stop_apex_engine;
END;
