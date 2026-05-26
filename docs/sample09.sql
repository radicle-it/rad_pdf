-- =============================================================================
-- sample09.sql  -  Embedding images (JPEG / PNG / GIF)
-- =============================================================================
--
-- WHAT THIS SHOWS
--   • rad_pdf_images.load_image      - load an image from a BLOB, Oracle Directory,
--                                   or HTTPS URL; returns an image_id integer
--   • rad_pdf_canvas.put_image       - place a loaded image at an exact x/y position
--                                   using the Canvas API
--   • rad_pdf.image                  - alternative: flow an image via the layout
--                                   engine alongside headings and paragraphs
--   • rad_pdf_images.get_image_dimensions - query natural pixel dimensions before
--                                   placing (useful for proportional scaling)
--
-- SUPPORTED FORMATS
--   JPEG (.jpg / .jpeg) - best for photographs
--   PNG  (.png)         - best for logos and sharp-edged diagrams (lossless)
--   GIF  (.gif)         - supported for legacy content
--
-- THREE WAYS TO LOAD AN IMAGE
--   Option A - from an Oracle Directory (most common in production)
--     Requires a DIRECTORY object pointing to a readable OS path:
--       CREATE OR REPLACE DIRECTORY IMG_DIR AS '/tmp/images';
--       GRANT READ ON DIRECTORY IMG_DIR TO <your_schema>;
--     Then: l_img_id := rad_pdf_images.load_image(l_doc, 'IMG_DIR', 'logo.png');
--
--   Option B - from a BLOB in memory
--     If the image is stored in a table column:
--       SELECT img_data INTO l_blob FROM my_images WHERE id = 1;
--       l_img_id := rad_pdf_images.load_image(l_doc, l_blob);
--
--   Option C - from an HTTPS URL
--     The database server must be able to make outbound HTTPS connections.
--     A network ACL must grant the calling schema 'http' privilege for the host.
--     Run once as DBA:
--       BEGIN
--         DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
--           host => 'your.image.server',
--           ace  => xs$ace_type(
--                     privilege_list => xs$name_list('http'),
--                     principal_name => '<your_schema>',
--                     principal_type => xs_acl.ptype_db));
--       END;
--     Then: l_img_id := rad_pdf_images.load_image(l_doc, 'https://your.server/logo.png');
--
-- SESSION CACHE
--   Images are cached by SHA-256 hash for the lifetime of the database session.
--   Loading the same image twice in one document returns the same image_id.
--   In batch loops, call rad_pdf_images.clear_image_cache after the loop completes.
--
-- HOW TO RUN
--   Edit the load_image call (choose Option A, B, or C) and set the correct
--   directory name / filename / URL for your environment.
--   Then run as any other sample - see sample01.sql for options.
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc    rad_pdf_types.t_doc_handle;
  l_pdf    BLOB;
  l_img_id PLS_INTEGER;   -- numeric identifier returned by load_image
  l_img_w  NUMBER;        -- natural pixel width  (returned in points)
  l_img_h  NUMBER;        -- natural pixel height (returned in points)
BEGIN
  rad_pdf_styles.load_defaults;

  l_doc := rad_pdf.new_document;

  -- =========================================================================
  -- Load the image - choose ONE of Options A, B, or C (see header above)
  -- =========================================================================

  -- Option B (active): from a BLOB - 8×8 steel-blue PNG embedded as a RAW
  -- literal so the sample runs without any directory or network setup.
  -- In production, replace with Option A (directory) or Option C (HTTPS URL).
  DECLARE
    l_blob BLOB;
    l_raw  RAW(32767) :=
      HEXTORAW('89504E470D0A1A0A0000000D494844520000000800000008'||
               '08020000004B6D29DC0000001149444154789C63706BDA82'||
               '15310C2D090003735F010FD97D610000000049454E44AE42'||
               '6082');
  BEGIN
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    DBMS_LOB.WRITEAPPEND(l_blob, UTL_RAW.LENGTH(l_raw), l_raw);
    l_img_id := rad_pdf_images.load_image(l_doc, l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);
  END;

  -- Option A: from an Oracle Directory (requires DIRECTORY object + file):
  -- l_img_id := rad_pdf_images.load_image(l_doc, 'IMG_DIR', 'logo.png');

  -- Option C: from an HTTPS URL (requires network ACL - see header):
  -- l_img_id := rad_pdf_images.load_image(l_doc, 'https://your.server/images/logo.png');

  -- =========================================================================
  -- Query natural dimensions
  -- get_image_dimensions returns width/height in points.
  -- Use these to calculate a scaled width that preserves aspect ratio.
  -- =========================================================================
  rad_pdf_images.get_image_dimensions(l_doc, l_img_id, l_img_w, l_img_h);
  DBMS_OUTPUT.PUT_LINE(
    'Image natural size: ' || ROUND(l_img_w) || ' × ' || ROUND(l_img_h) || ' pt');

  -- =========================================================================
  -- PAGE LAYOUT
  -- Mix canvas-API placement (put_image) with the layout engine (headings etc).
  -- In this sample we use both:
  --   - A heading and body text via the layout engine
  --   - The image placed at an absolute canvas position
  -- =========================================================================

  rad_pdf.heading(l_doc, 'Image Embedding Demo', 1);
  rad_pdf.write  (l_doc,
    'The image below is loaded from disk and placed at absolute coordinates ' ||
    'using the Canvas API.  Provide p_width to scale; omit both p_width and ' ||
    'p_height to use the natural image size.');
  rad_pdf.spacer (l_doc, 10);

  -- =========================================================================
  -- Place the image via Canvas API
  -- Coordinate origin is lower-left corner.  x=50, y=500 is near the middle
  -- of an A4 page.  Supply p_width to scale; height is calculated automatically
  -- to preserve the aspect ratio.
  -- =========================================================================
  rad_pdf_canvas.put_image(
    p_doc      => l_doc,
    p_image_id => l_img_id,
    p_x        => 50,
    p_y        => 500,
    p_width    => 150,   -- scale to 150 pt wide; height auto-proportioned
    p_unit     => 'pt');

  -- Caption directly below the image (canvas API, absolute positioning)
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'I', 8);
  rad_pdf_canvas.set_color(l_doc, '808080');
  rad_pdf_canvas.write_text(l_doc, 'Figure 1 - logo.png loaded from Oracle Directory', 50, 492, 'pt');

  -- =========================================================================
  -- Alternative: flow the image via the layout engine
  -- rad_pdf.image inserts the image as a flowable, right after the previous
  -- paragraph.  The layout engine handles page breaks automatically.
  -- Uncomment to use instead of (or in addition to) put_image above.
  -- =========================================================================
  -- rad_pdf.image(l_doc, l_img_id, p_width => 150);

  -- =========================================================================
  -- Finalise
  -- =========================================================================
  l_pdf := rad_pdf.finalize(l_doc);

  DBMS_OUTPUT.PUT_LINE('PDF generated - size: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');
  -- :rad_pdf := l_pdf;
  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
