-- =============================================================================
-- apex_debug_image.sql  -  Step-by-step diagnostic
-- =============================================================================
-- STEP 1: Run this first (image code commented out).
--         Expected: PDF with the two text lines visible.
--         If blank: the pure-canvas path is broken, unrelated to images.
-- STEP 2: Uncomment the image block and retest.
-- =============================================================================

DECLARE
  l_doc      rad_pdf_types.t_doc_handle;
  l_pdf      BLOB;
  -- l_blob     BLOB;
  -- l_logo_id  PLS_INTEGER;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- Pure canvas text - no image, no layout flowables
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'N', 12);
  rad_pdf_canvas.set_color(l_doc, '000000');
  rad_pdf_canvas.write_text(l_doc, 'STEP 1 - canvas text test', 42, 780, 'pt');
  rad_pdf_canvas.write_text(l_doc, 'If you see this, canvas rendering works.', 42, 760, 'pt');

  -- ── Uncomment this block for STEP 2 ─────────────────────────────────────
  -- SELECT file_content INTO l_blob
  -- FROM   apex_application_static_files
  -- WHERE  application_id = :APP_ID
  -- AND    file_name      = 'radicle_logo.jpg';
  --
  -- l_logo_id := rad_pdf_images.load_image(l_doc, l_blob);
  -- rad_pdf_canvas.write_text(l_doc, 'logo_id = ' || TO_CHAR(l_logo_id), 42, 730, 'pt');
  -- rad_pdf_canvas.put_image(l_doc, l_logo_id, 42, 710, 80, 80, 'L', 'T', 'pt');
  -- ─────────────────────────────────────────────────────────────────────────

  l_pdf := rad_pdf.finalize(l_doc);

  owa_util.mime_header('application/pdf', FALSE);
  htp.p('Content-Length: ' || DBMS_LOB.getlength(l_pdf));
  htp.p('Content-Disposition: inline; filename="debug_image.pdf"');
  htp.p('Cache-Control: no-store, no-cache, must-revalidate');
  owa_util.http_header_close;
  wpg_docload.download_file(l_pdf);
  DBMS_LOB.FREETEMPORARY(l_pdf);

  apex_application.stop_apex_engine;
END;
