-- =============================================================================
-- apex_sample10.sql  -  Image watermark loaded from application static files
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A logo image is fetched from apex_application_static_files and registered
--   as a translucent image watermark centred on every page.  If the static
--   file is not found (e.g. not yet uploaded) the document is produced without
--   a watermark - no error is raised.
--
-- KEY TECHNIQUES
--   - Load logo from apex_application_static_files (same pattern as apex_sample05)
--   - Graceful fallback: WHEN NO_DATA_FOUND produces document without watermark
--   - rad_pdf.set_watermark_image: image is centred, 20% opacity, 50% page width
--   - p_layer => 'UNDER': watermark drawn behind page content (default)
--   - Navy color scheme matching other APEX examples in this series
--
-- IMAGE SETUP
--   Upload your company logo as an Application Static File in APEX:
--     Shared Components -> Static Application Files -> Upload File
--   Name the file 'company_logo.png' (or adjust the file_name filter below).
--   Supported formats: JPEG, PNG, GIF.
--
-- DATA
--   Uses EMP (Scott schema). Replace with your own query as needed.
--
-- WHERE TO PUT THIS CODE
--   Processing -> Execute Server-side Code
--   Point:  On Load - Before Header
--
-- PREREQUISITES
--   RAD_PDF v1.4.0+ installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc       rad_pdf_types.t_doc_handle;
  l_pdf       BLOB;
  l_cols      rad_pdf_types.t_columns;
  l_clr       rad_pdf_types.t_color_scheme;
  l_logo_blob BLOB;
  l_logo_id   PLS_INTEGER := NULL;
  i           PLS_INTEGER;

  l_today VARCHAR2(30) := TO_CHAR(SYSDATE, 'DD-MON-YYYY');
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Load logo from application static files and register image watermark.
  -- The WHEN NO_DATA_FOUND handler allows the document to be produced even
  -- when the file has not been uploaded yet.
  -- =========================================================================
  BEGIN
    SELECT file_content
    INTO   l_logo_blob
    FROM   apex_application_static_files
    WHERE  application_id = :APP_ID
    AND    file_name      = 'company_logo.png';

    l_logo_id := rad_pdf_images.load_image(l_doc, l_logo_blob);
    rad_pdf.set_watermark_image(
      p_doc       => l_doc,
      p_image_id  => l_logo_id,
      p_opacity   => 0.2,     -- 20% opacity: logo is visible but does not obscure text
      p_width_pct => 50,      -- image spans 50% of page width; aspect ratio preserved
      p_layer     => 'UNDER');
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;  -- file not uploaded - document produced without watermark
    WHEN OTHERS        THEN NULL;  -- unexpected error - proceed without watermark
  END;

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
  -- Color scheme: navy header, light blue alternating rows
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
  rad_pdf.heading(l_doc, 'Employee Roster', 1);
  rad_pdf.write(l_doc,
    CASE WHEN l_logo_id IS NOT NULL
         THEN 'Company logo watermark loaded from application static files.'
         ELSE 'No logo file found - document produced without watermark.'
    END);

  rad_pdf.query2table(l_doc,
    'SELECT TO_CHAR(empno),'
    || ' INITCAP(ename),'
    || ' INITCAP(job),'
    || ' TO_CHAR(hiredate, ''DD-Mon-YYYY''),'
    || ' sal'
    || ' FROM emp'
    || ' ORDER BY ename',
    l_cols,
    p_colors => l_clr);

  rad_pdf.write(l_doc, 'Generated: ' || l_today);

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
