-- =============================================================================
-- sample18.sql  -  1D barcodes: Code 128, EAN-13, Code 39 product labels
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A product-label sheet using the three 1D symbologies (v1.6.0), all
--   rendered as pure VECTOR bars (filled PDF paths, no raster images):
--     1. Code 128  - shipping/SKU codes (subsets B/C selected automatically)
--     2. EAN-13    - retail barcode with standard digit layout
--     3. Code 39   - legacy asset tags (* delimiters in the text line)
--
-- KEY TECHNIQUES
--   - rad_pdf.barcode: generic facade (p_type => 'CODE128'|'CODE39'|'EAN13')
--   - rad_pdf_barcode.ean13: direct API to control the module width
--   - EAN-13 width is fixed by the standard: 113 modules incl. quiet zones;
--     nominal module = 0.33 mm -> symbol ~37.3 mm wide
--   - EAN-13 check digit: 12 digits = computed for you; 13 digits = validated
--     (ORA-20820 on mismatch - catches data-entry errors early)
--   - p_show_text: human-readable line under the bars (suppressible)
--   - Code 39 standard charset is A-Z 0-9 space - . $ / + % ;
--     pass p_full_ascii => TRUE for lowercase/extended ASCII
--
-- DATA
--   Self-contained; no tables required.
--
-- HOW TO RUN
--   Same as sample01.sql - see its header for output options.
--
-- PREREQUISITES
--   RAD_PDF v1.6.0+ installed (run src/install.sql).
-- =============================================================================

SET SERVEROUTPUT ON

DECLARE
  l_doc rad_pdf_types.t_doc_handle;
  l_pdf BLOB;
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 14);
  rad_pdf_canvas.write_text(l_doc, 'Warehouse labels - 1D barcodes', 20, 275, 'mm');

  -- ---------------------------------------------------------------------
  -- 1. Code 128: alphanumeric SKU (subset B) and numeric lot (subset C)
  -- ---------------------------------------------------------------------
  rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'N', 9);
  rad_pdf_canvas.write_text(l_doc, 'SKU (Code 128, subset B):', 20, 262, 'mm');
  rad_pdf.barcode(l_doc, 'CODE128', 'RAD-PDF-2026',
                  p_x => 20, p_y => 240, p_width => 80, p_height => 18,
                  p_unit => 'mm');

  rad_pdf_canvas.write_text(l_doc, 'Lot number (Code 128, subset C - digits pack 2-per-symbol):',
                            110, 262, 'mm');
  rad_pdf.barcode(l_doc, 'CODE128', '00123456789012',
                  p_x => 110, p_y => 240, p_width => 70, p_height => 18,
                  p_unit => 'mm');

  -- ---------------------------------------------------------------------
  -- 2. EAN-13: retail barcode at nominal size (module 0.33 mm)
  -- ---------------------------------------------------------------------
  rad_pdf_canvas.write_text(l_doc, 'EAN-13 (12 digits in, check digit computed):',
                            20, 220, 'mm');
  rad_pdf_barcode.ean13(l_doc,
    p_digits => '590123412345',      -- 13th digit (7) computed automatically
    p_x      => 20, p_y => 190, p_height => 26,
    p_unit   => 'mm');               -- module NULL -> nominal 0.33 mm

  rad_pdf_canvas.write_text(l_doc, 'EAN-13 enlarged (module 0.5 mm):',
                            110, 220, 'mm');
  rad_pdf_barcode.ean13(l_doc,
    p_digits   => '8001120008978',   -- full 13 digits: check digit VALIDATED
    p_x        => 110, p_y => 190, p_height => 26,
    p_module_w => 0.5,
    p_unit     => 'mm');

  -- ---------------------------------------------------------------------
  -- 3. Code 39: asset tag
  -- ---------------------------------------------------------------------
  rad_pdf_canvas.write_text(l_doc, 'Asset tag (Code 39):', 20, 170, 'mm');
  rad_pdf.barcode(l_doc, 'CODE39', 'ASSET-0042',
                  p_x => 20, p_y => 148, p_width => 90, p_height => 18,
                  p_unit => 'mm');

  l_pdf := rad_pdf.finalize(l_doc);
  DBMS_OUTPUT.PUT_LINE('PDF generated: ' || DBMS_LOB.GETLENGTH(l_pdf) || ' bytes');

  -- Option B - save to an Oracle Directory:
  -- rad_pdf.save(l_pdf, 'PDF_OUT', 'sample18_barcodes.pdf');

  -- Option C - SQL Developer bind:
  -- :rad_pdf := l_pdf;

  DBMS_LOB.FREETEMPORARY(l_pdf);
END;
/
