-- =============================================================================
-- sample17.sql  -  QR codes: payment link, business card, coloured QR
-- =============================================================================
--
-- WHAT THIS SHOWS
--   Three QR codes on one page, generated as pure VECTOR graphics (filled
--   PDF paths, no raster images) by rad_pdf_barcode:
--     1. A payment URL next to invoice-style text (the classic use case)
--     2. A vCard-style multi-line value in UTF-8 (ECI mode)
--     3. A corporate-coloured QR at error correction level H
--
-- KEY TECHNIQUES
--   - rad_pdf.qrcode: facade shortcut (delegates to rad_pdf_barcode.qrcode)
--   - p_size: the square INCLUDES the mandatory 4-module quiet zone
--   - p_ec_level: L (7%) / M (15%, default) / Q (25%) / H (30%) damage
--     tolerance; higher levels allow logo overlays and survive dirty prints
--   - p_color: any 6-char hex RGB; keep strong contrast vs white for scanning
--   - rad_pdf_barcode.qrcode_modules: returns modules-per-side, useful to
--     compute the printed module size (p_size / modules >= ~1mm for print)
--   - Encoding mode (numeric / alphanumeric / byte / UTF-8) is automatic
--
-- DATA
--   Self-contained; no tables required.
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
--   RAD_PDF v1.6.0+ installed (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc     rad_pdf_types.t_doc_handle;
  l_pdf     BLOB;
  l_modules PLS_INTEGER;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  -- ---------------------------------------------------------------------
  -- 1. Invoice block with a payment QR on the right (the classic pattern)
  -- ---------------------------------------------------------------------
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 16);
  rad_pdf_canvas.write_text(l_doc, 'Invoice 2026-0042', 20, 270, 'mm');
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'N', 10);
  rad_pdf_canvas.write_text(l_doc, 'Amount due: EUR 1.250,00', 20, 262, 'mm');
  rad_pdf_canvas.write_text(l_doc, 'Scan to pay online:',      20, 256, 'mm');

  rad_pdf.qrcode(l_doc,
    p_value => 'https://pay.example.com/invoice/2026-0042',
    p_x     => 150, p_y => 240, p_size => 40,   -- 40 mm square
    p_unit  => 'mm');

  -- ---------------------------------------------------------------------
  -- 2. UTF-8 content (ECI mode is selected automatically)
  -- ---------------------------------------------------------------------
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 12);
  rad_pdf_canvas.write_text(l_doc, 'Contact (UTF-8 vCard)', 20, 200, 'mm');

  rad_pdf.qrcode(l_doc,
    p_value => 'BEGIN:VCARD' || CHR(10) ||
               'FN:Niccolò Macchiavelli'  || CHR(10) ||
               'ORG:Radicle S.r.l.'       || CHR(10) ||
               'URL:https://radicle.it'   || CHR(10) ||
               'END:VCARD',
    p_x     => 20, p_y => 145, p_size => 50,
    p_unit  => 'mm');

  -- ---------------------------------------------------------------------
  -- 3. Coloured QR, EC level H (30% damage tolerance)
  -- ---------------------------------------------------------------------
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 12);
  rad_pdf_canvas.write_text(l_doc, 'Corporate colour, EC level H', 20, 120, 'mm');

  l_modules := rad_pdf_barcode.qrcode_modules('https://radicle.it', 'H');
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'N', 8);
  rad_pdf_canvas.write_text(l_doc,
    l_modules || ' modules per side -> module size '
    || ROUND(50 / l_modules, 2) || ' mm', 20, 114, 'mm');

  rad_pdf.qrcode(l_doc,
    p_value    => 'https://radicle.it',
    p_x        => 20, p_y => 60, p_size => 50,
    p_ec_level => 'H',
    p_color    => '003366',                     -- navy on white scans fine
    p_unit     => 'mm');

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('PDF generated: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B - save to an Oracle Directory:
  -- rad_pdf.save(l_pdf, 'PDF_OUT', 'sample17_qrcode.pdf');

  -- Option C - SQL Developer bind:
  -- :rad_pdf := l_pdf;

  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
