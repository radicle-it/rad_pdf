-- =============================================================================
-- sample14.sql  -  Image watermark: logo centred on every page
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A logo image loaded from a BLOB and registered as a translucent image
--   watermark using rad_pdf.set_watermark_image. The watermark appears
--   centred on every page at 25% opacity and occupies 50% of the page width.
--   Page content (an EMP table) is drawn on top in the normal way.
--
-- KEY TECHNIQUES
--   - rad_pdf_images.load_image: load image from a BLOB before calling finalize
--   - rad_pdf.set_watermark_image: register an image watermark
--   - p_width_pct => 50: image occupies half the page width; aspect ratio preserved
--   - p_opacity => 0.25: 25% opacity keeps the table easy to read
--   - p_layer => 'UNDER': watermark drawn behind page content (default)
--   - Graceful handling: if the BLOB is NULL the document is produced without
--     a watermark - no error is raised
--   - rad_pdf_images.load_image also accepts a URL:
--       l_img_id := rad_pdf_images.load_image(l_doc, 'https://example.com/logo.png');
--     or an Oracle Directory:
--       l_img_id := rad_pdf_images.load_image(l_doc, 'MY_IMAGES_DIR', 'logo.png');
--
-- IMAGE IN THIS EXAMPLE
--   The script uses a 1x1 white JPEG as a stand-in so it runs without any
--   file system dependency. Replace l_logo_blob with your real image BLOB,
--   or use one of the load_image overloads shown above.
--
-- DATA
--   Uses the classic Oracle EMP table (Scott schema).
--   Replace with your own query if EMP is not available.
--
-- HOW TO RUN
--   Option A - SQL*Plus or SQL Developer:
--     Run as-is; the PDF size is printed to DBMS_OUTPUT to confirm success.
--
--   Option B - Save to file via Oracle Directory:
--     Uncomment the rad_pdf.save() call and set your directory name.
--     CREATE OR REPLACE DIRECTORY PDF_OUT AS '/tmp/rad_pdf';
--     GRANT WRITE ON DIRECTORY PDF_OUT TO your_schema;
--
--   Option C - SQL Developer bind variable:
--     Uncomment the ":rad_pdf := l_pdf" line, then right-click the result
--     and choose Save As.
--
-- PREREQUISITES
--   RAD_PDF v1.4.0+ installed (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc      rad_pdf_types.t_doc_handle;
  l_pdf      BLOB;
  l_cols     rad_pdf_types.t_columns;
  l_clr      rad_pdf_types.t_color_scheme;
  l_logo_blob BLOB;
  l_img_id   PLS_INTEGER := NULL;
  i          PLS_INTEGER;

  -- Minimal 8x8 steel-blue PNG used as a stand-in logo.
  -- Replace this with your own image BLOB, or use one of:
  --   l_img_id := rad_pdf_images.load_image(l_doc, 'MY_DIR', 'logo.png');
  --   l_img_id := rad_pdf_images.load_image(l_doc, 'https://example.com/logo.png');
  c_stand_in_png CONSTANT RAW(200) :=
    HEXTORAW(
      '89504E470D0A1A0A0000000D494844520000000800000008'
      || '08020000004B6D29DC0000001149444154789C63706BDA82'
      || '15310C2D090003735F010FD97D610000000049454E44AE42'
      || '6082');

BEGIN
  rad_pdf_styles.load_defaults;

  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Load logo from BLOB and register image watermark
  -- =========================================================================
  DBMS_LOB.CREATETEMPORARY(l_logo_blob, TRUE);
  DBMS_LOB.WRITEAPPEND(l_logo_blob, UTL_RAW.LENGTH(c_stand_in_png), c_stand_in_png);

  BEGIN
    l_img_id := rad_pdf_images.load_image(l_doc, l_logo_blob);
    rad_pdf.set_watermark_image(
      p_doc       => l_doc,
      p_image_id  => l_img_id,
      p_opacity   => 0.25,    -- 25% opacity: image is visible but unobtrusive
      p_width_pct => 50,      -- image spans 50% of page width; aspect ratio kept
      p_layer     => 'UNDER');
  EXCEPTION
    WHEN OTHERS THEN NULL;    -- if image load fails, produce document without watermark
  END;

  DBMS_LOB.FREETEMPORARY(l_logo_blob);

  -- =========================================================================
  -- Column definitions (EMP report)
  -- =========================================================================
  l_cols := rad_pdf_types.t_columns();
  l_cols.EXTEND(5);

  FOR i IN 1..5 LOOP
    l_cols(i).data_fmt.margin_top    := 4;
    l_cols(i).data_fmt.margin_bot    := 4;
    l_cols(i).data_fmt.margin_left   := 6;
    l_cols(i).data_fmt.margin_rgt    := 6;
    l_cols(i).header_fmt.margin_top  := 4;
    l_cols(i).header_fmt.margin_bot  := 4;
    l_cols(i).header_fmt.margin_left := 6;
    l_cols(i).header_fmt.margin_rgt  := 6;
    l_cols(i).header_fmt.font_style  := 'B';
  END LOOP;

  l_cols(1).label              := 'No';
  l_cols(1).width              := 45;
  l_cols(1).header_fmt.align_h := 'C';
  l_cols(1).data_fmt.align_h   := 'C';

  l_cols(2).label := 'Name';
  l_cols(2).width := 90;

  l_cols(3).label := 'Job';
  l_cols(3).width := 90;

  l_cols(4).label              := 'Hired';
  l_cols(4).width              := 80;
  l_cols(4).header_fmt.align_h := 'C';
  l_cols(4).data_fmt.align_h   := 'C';

  l_cols(5).label               := 'Salary';
  l_cols(5).width               := 72;
  l_cols(5).header_fmt.align_h  := 'R';
  l_cols(5).data_fmt.align_h    := 'R';
  l_cols(5).data_fmt.num_format := '999,990.00';

  -- =========================================================================
  -- Color scheme: navy header, light alternating rows
  -- =========================================================================
  l_clr.header_paper  := '1A3A5C';
  l_clr.header_ink    := 'FFFFFF';
  l_clr.header_border := '1A3A5C';
  l_clr.even_paper    := 'FFFFFF';
  l_clr.even_border   := 'CCCCCC';
  l_clr.odd_paper     := 'EEF2F8';
  l_clr.odd_border    := 'CCCCCC';

  -- =========================================================================
  -- Document content
  -- =========================================================================
  rad_pdf.heading(l_doc, 'Employee Roster', 1);
  rad_pdf.write  (l_doc,
    'The logo watermark is drawn behind the table content at 25% opacity. '  ||
    'It is centred on every page and spans 50% of the page width. '          ||
    'To use your own logo, replace the minimal JPEG with a real image BLOB ' ||
    'or load it via rad_pdf_images.load_image from a directory or URL.');
  rad_pdf.spacer (l_doc, 10);

  rad_pdf.query2table(l_doc,
    'SELECT empno, ename, job, ' ||
    '       TO_CHAR(hiredate, ''DD-Mon-YYYY''), sal ' ||
    '  FROM emp ORDER BY ename',
    l_cols,
    p_colors => l_clr);

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B: save to file
  -- rad_pdf.save(l_doc, 'PDF_OUT', 'image_watermark.pdf');

  -- Option C: SQL Developer bind variable
  -- :rad_pdf := l_pdf;

  DBMS_LOB.FREETEMPORARY(l_pdf);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN rad_pdf.close_document(l_doc); EXCEPTION WHEN OTHERS THEN NULL; END;
    IF l_pdf IS NOT NULL THEN DBMS_LOB.FREETEMPORARY(l_pdf); END IF;
    RAISE;
END;
/
