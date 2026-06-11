-- =============================================================================
-- apex_sample13.sql  -  QR code on an APEX-generated document (demo app page 3)
-- =============================================================================
--
-- WHAT THIS SHOWS
--   An invoice-style PDF generated from an APEX page process with a payment
--   QR code whose content is driven by page items. The QR is pure vector
--   (no images to upload or cache) and the URL embeds APEX session-safe
--   values read with V().
--
-- KEY TECHNIQUES
--   - rad_pdf.qrcode: facade shortcut; p_size INCLUDES the 4-module quiet zone
--   - Page items (:P3_INVOICE_ID) compose the encoded URL at runtime
--   - rad_pdf_barcode.qrcode_modules: pre-compute module size to keep it
--     printable (>= ~1 mm per module is comfortable for phone cameras)
--   - EC level 'Q' (25%): a good default for documents that may be printed,
--     photocopied, or scanned from a screen
--   - UTF-8 values (e.g. names with accents) are encoded automatically (ECI)
--
-- WHERE TO PUT THIS CODE
--   Processing -> Execute Server-side Code
--   Point:  On Load - Before Header  (e.g. page 3 of the demo app)
--
-- PAGE ITEMS REQUIRED
--   P3_INVOICE_ID  NUMBER  - invoice key passed to the page (e.g. from a link)
--
-- DATA
--   The invoice header is mocked inline; replace the literals with your
--   invoice query.
--
-- PREREQUISITES
--   RAD_PDF v1.6.0+ installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc     rad_pdf_types.t_doc_handle;
  l_pdf     BLOB;
  l_inv_id  NUMBER := NVL(:P3_INVOICE_ID, 1042);
  l_pay_url VARCHAR2(500);
  l_modules PLS_INTEGER;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- ---------------------------------------------------------------------
  -- Invoice header (replace with your real invoice query)
  -- ---------------------------------------------------------------------
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 16);
  rad_pdf_canvas.write_text(l_doc, 'Invoice #' || l_inv_id, 20, 270, 'mm');
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'N', 10);
  rad_pdf_canvas.write_text(l_doc, 'Issued: ' || TO_CHAR(SYSDATE, 'DD-MON-YYYY')
                            || '   -   User: ' || V('APP_USER'), 20, 262, 'mm');
  rad_pdf_canvas.write_text(l_doc, 'Amount due: EUR 1.250,00', 20, 254, 'mm');
  rad_pdf_canvas.h_line(l_doc, 20, 250, 170, 0.4, '003366', 'mm');

  -- ---------------------------------------------------------------------
  -- Payment QR: URL built from page items / session state
  -- ---------------------------------------------------------------------
  l_pay_url := 'https://pay.example.com/inv/' || l_inv_id;

  -- Keep the module printable: 45 mm symbol / N modules >= ~1 mm each
  l_modules := rad_pdf_barcode.qrcode_modules(l_pay_url, 'Q');

  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 10);
  rad_pdf_canvas.write_text(l_doc, 'Scan to pay online', 145, 248, 'mm');
  rad_pdf.qrcode(l_doc,
    p_value    => l_pay_url,
    p_x        => 145, p_y => 200, p_size => 45,
    p_ec_level => 'Q',
    p_unit     => 'mm');
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'N', 7);
  rad_pdf_canvas.write_text(l_doc,
    l_modules || ' modules - ' || ROUND(45 / l_modules, 2) || ' mm each',
    145, 196, 'mm');

  -- ... body of the invoice (tables, totals) goes here ...

  l_pdf := rad_pdf.finalize(l_doc);

  -- Stream to the browser and stop the APEX engine
  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: '      || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="invoice_' || l_inv_id || '.pdf"');
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
