-- =============================================================================
-- apex_sample04.sql  -  Full report with page header, footer, logo, and session info
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A production-quality APEX PDF report that:
--   • Reads APEX session information (V() / NV() functions) to personalise
--     the header and the document metadata at runtime
--   • Loads a company logo from APEX Static Application Files and places it
--     in the page header on every page
--   • Uses a page template with a header procedure showing the logo,
--     application name, current user, date, and page number
--   • Uses rad_pdf_types.t_doc_info to populate PDF viewer File -> Properties
--   • Demonstrates the correct call order when the logo ID must be embedded
--     as a literal in header_proc:
--       1. new_document  (no template yet)
--       2. load_image    (get logo_id)
--       3. build header_proc with logo_id as a literal
--       4. set_template
--
-- LOGO
--   Upload a JPEG or RGB PNG (no alpha channel) to APEX Static Application
--   Files and name it 'app_logo.jpg' (or .png - update file_name below).
--   If the file is missing or unsupported the document is generated without
--   the logo; no error is raised.
--
-- DATA
--   Uses the standard EMP and DEPT tables (always present in Oracle databases).
--
-- V() AND NV() FUNCTIONS
--   V('APP_USER')           - APEX logged-in username
--   V('APP_SESSION')        - APEX session ID
--   V('APP_NAME')           - Application name
--   NV('APP_ID')            - Application ID as NUMBER
--   SYS_CONTEXT('USERENV','SESSION_USER') - Database session user
--
-- NOTE ON #DOC_HANDLE# IN header_proc / footer_proc
--   The PL/SQL string is stored in the document handle and executed via
--   EXECUTE IMMEDIATE at finalize time.  PL/SQL locals (like l_apex_user)
--   are out of scope at that point.  Capture runtime values into locals
--   first (as done below) and embed them as literals in the string.
--   This is safe because V() returns trusted session state, not raw input.
--   For untrusted values store them in a package variable before finalize.
--
-- PREREQUISITES
--   RAD_PDF installed in the workspace schema.
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc        rad_pdf_types.t_doc_handle;
  l_pdf        BLOB;
  l_info       rad_pdf_types.t_doc_info;
  l_tpl        rad_pdf_types.t_page_template;
  l_cols       rad_pdf_types.t_columns;
  l_clr        rad_pdf_types.t_color_scheme;
  l_logo_blob  BLOB;
  l_logo_id    PLS_INTEGER := NULL;
  i            PLS_INTEGER;

  -- Capture APEX session values into PL/SQL locals first.
  l_apex_user  VARCHAR2(100) := NVL(V('APP_USER'), 'Unknown');
  l_app_name   VARCHAR2(200) := NVL(V('APP_NAME'), 'APEX Application');
  l_today      VARCHAR2(30)  := TO_CHAR(SYSDATE, 'DD-MON-YYYY');
BEGIN
  rad_pdf_styles.load_defaults;

  -- =========================================================================
  -- Step 1: document metadata - displayed in PDF viewer File -> Properties
  -- =========================================================================
  l_info.title    := l_app_name || ' - HR Report';
  l_info.author   := l_apex_user;
  l_info.subject  := 'Employee listing generated ' || l_today;
  l_info.keywords := 'APEX RAD_PDF employees HR ' || l_today;

  -- =========================================================================
  -- Step 2: start document without template (template applied after logo load)
  -- =========================================================================
  l_doc := rad_pdf.new_document(p_info => l_info);

  -- =========================================================================
  -- Step 3: load logo from APEX Static Application Files
  --         A missing file or unsupported format produces no logo, not an error.
  --         Use a JPEG or RGB PNG (no alpha channel).
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
  -- Step 4: page template - A4 portrait with room for header and footer
  --
  --   Header area : y = [772 .. 842]   (margin_top = 70)
  --   Footer area : y = [0  ..  50]    (margin_bottom = 50)
  --   Content area: y = [50 .. 772]
  --
  --   Logo  : top at y=832, 36x36 pt, x=42
  --   Text  : app name baseline y=826, user y=815     x=86
  --   Page# : baseline y=820                          x=460
  --   Rule  : y=778 (6 pt above content area)
  -- =========================================================================
  l_tpl.page_format_name := 'A4';
  l_tpl.margin_top       := 70;
  l_tpl.margin_bottom    := 50;
  l_tpl.margin_left      := 42;
  l_tpl.margin_right     := 42;

  -- Header: logo | app name + user on left; date + page n/N on right
  l_tpl.header_proc :=
    'BEGIN ' ||
    CASE WHEN l_logo_id IS NOT NULL THEN
      'rad_pdf_canvas.put_image(' ||
        '#DOC_HANDLE#, ' || TO_CHAR(l_logo_id) || ', ' ||
        '42, 832, 36, 36, ''L'', ''T'', ''pt''); '
    END ||
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''B'', 9); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''1A3A5C''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''' || REPLACE(l_app_name, '''', '''''') || ''', ' ||
      CASE WHEN l_logo_id IS NOT NULL THEN '86' ELSE '42' END ||
      ', 826, ''pt''); ' ||
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''N'', 8); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''555555''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''User: ' || REPLACE(l_apex_user, '''', '''''') || ''', ' ||
      CASE WHEN l_logo_id IS NOT NULL THEN '86' ELSE '42' END ||
      ', 815, ''pt''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''Page #PAGE_NR# of #PAGE_COUNT#   ' || l_today || ''', 460, 820, ''pt''); ' ||
    'rad_pdf_canvas.h_line(#DOC_HANDLE#, 42, 778, 511, 0.5, ''1A3A5C'', ''pt''); ' ||
    'END;';

  -- Footer: thin rule + confidentiality notice
  l_tpl.footer_proc :=
    'BEGIN ' ||
    'rad_pdf_canvas.h_line(#DOC_HANDLE#, 42, 44, 511, 0.4, ''AAAAAA'', ''pt''); ' ||
    'rad_pdf_canvas.set_font (#DOC_HANDLE#, ''Helvetica'', ''I'', 7); ' ||
    'rad_pdf_canvas.set_color(#DOC_HANDLE#, ''888888''); ' ||
    'rad_pdf_canvas.write_text(#DOC_HANDLE#, ' ||
      '''Confidential - for internal use only - generated by RAD_PDF'', 42, 30, ''pt''); ' ||
    'END;';

  rad_pdf_layout.set_template(l_doc, l_tpl);

  -- =========================================================================
  -- Column definitions: EMP joined to DEPT (6 columns, total width = 510 pt)
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(6);

  FOR i IN 1..6 LOOP
    l_cols(i).data_fmt.margin_top  := 4;
    l_cols(i).data_fmt.margin_bot  := 4;
    l_cols(i).data_fmt.margin_left := 5;
    l_cols(i).data_fmt.margin_rgt  := 5;
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
  -- Color scheme - navy blue
  -- =========================================================================
  l_clr.header_paper  := '1A3A5C';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '1A3A5C';
  l_clr.odd_paper     := 'EBF2FA';
  l_clr.odd_border    := 'BDD5EC';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.even_border   := 'BDD5EC';

  -- =========================================================================
  -- Build document content
  -- =========================================================================
  rad_pdf.heading(l_doc, 'Employee Listing', 1);
  rad_pdf.write  (l_doc,
    'Report for: ' || l_apex_user ||
    '  |  Date: ' || l_today);
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
    'Application ID: ' || NV('APP_ID') ||
    '  |  Session: '   || V('APP_SESSION'), 'caption');

  -- =========================================================================
  -- Stream to browser
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
