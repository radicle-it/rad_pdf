-- =============================================================================
-- apex_sample14.sql  -  1D barcode labels from a query (demo app page 4)
-- =============================================================================
--
-- WHAT THIS SHOWS
--   A warehouse label sheet generated from an APEX page process: one label
--   per product row with a Code 128 SKU barcode and an EAN-13 retail code.
--   All bars are vector paths - crisp at any printer resolution, nothing to
--   upload to static files.
--
-- KEY TECHNIQUES
--   - rad_pdf.barcode generic facade in a cursor loop (one barcode per row)
--   - rad_pdf_barcode.ean13 with module width for standard-compliant sizing
--   - EAN-13 check digit validated automatically: a wrong 13th digit in your
--     product table raises ORA-20820 instead of printing a broken barcode
--   - Manual page break when the label grid is full
--   - Page item :P4_DEPT filters the products (NULL = all)
--
-- WHERE TO PUT THIS CODE
--   Processing -> Execute Server-side Code
--   Point:  On Load - Before Header  (e.g. page 4 of the demo app)
--
-- PAGE ITEMS REQUIRED
--   P4_DEPT  VARCHAR2 - optional product filter
--
-- DATA
--   Mock products generated inline with CONNECT BY; replace the cursor with
--   your product table (sku, ean, description columns).
--
-- PREREQUISITES
--   RAD_PDF v1.6.0+ installed in the workspace schema (or with synonyms).
--   See docs/apex/README.md.
-- =============================================================================

DECLARE
  l_doc   rad_pdf_types.t_doc_handle;
  l_pdf   BLOB;
  l_x     NUMBER;
  l_y     NUMBER;
  l_n     PLS_INTEGER := 0;
  c_per_row  CONSTANT PLS_INTEGER := 2;     -- labels per row
  c_label_w  CONSTANT NUMBER := 90;         -- mm
  c_label_h  CONSTANT NUMBER := 45;         -- mm
  c_top      CONSTANT NUMBER := 270;        -- first row y (mm, lower-left)
BEGIN
  rad_pdf_styles.load_defaults;
  l_doc := rad_pdf.new_document;

  FOR r IN (
    -- Replace with: SELECT sku, ean, descr FROM products WHERE ...
    SELECT 'SKU-' || TO_CHAR(LEVEL, 'FM0009')          AS sku,
           TO_CHAR(590123412300 + LEVEL)               AS ean,   -- 12 digits
           'Demo product ' || LEVEL                    AS descr
    FROM DUAL
    WHERE NVL(:P4_DEPT, 'ALL') IS NOT NULL
    CONNECT BY LEVEL <= 8
  ) LOOP
    -- Label grid position (2 columns)
    l_x := 15 + MOD(l_n, c_per_row) * (c_label_w + 10);
    l_y := c_top - TRUNC(l_n / c_per_row) * (c_label_h + 8) - c_label_h;

    -- New page when the sheet is full (5 rows of labels)
    IF l_y < 20 THEN
      rad_pdf.new_page(l_doc);
      l_n := 0;
      l_x := 15;
      l_y := c_top - c_label_h;
    END IF;

    -- Label frame + description
    rad_pdf_canvas.rect(l_doc, l_x, l_y, c_label_w, c_label_h,
                        p_line_color => 'AAAAAA', p_unit => 'mm');
    rad_pdf_canvas.set_font (l_doc, 'Helvetica', 'B', 9);
    rad_pdf_canvas.write_text(l_doc, r.descr, l_x + 4, l_y + c_label_h - 7, 'mm');

    -- Code 128 SKU (left) - human-readable line included
    rad_pdf.barcode(l_doc, 'CODE128', r.sku,
                    p_x => l_x + 4,  p_y => l_y + 20,
                    p_width => 38, p_height => 14, p_unit => 'mm');

    -- EAN-13 (right) - 12 digits, check digit computed; nominal module
    rad_pdf_barcode.ean13(l_doc, r.ean,
                          p_x => l_x + 48, p_y => l_y + 18,
                          p_height => 18, p_unit => 'mm');

    l_n := l_n + 1;
  END LOOP;

  l_pdf := rad_pdf.finalize(l_doc);

  -- Stream to the browser and stop the APEX engine
  OWA_UTIL.MIME_HEADER('application/pdf', FALSE);
  HTP.P('Content-Length: '      || DBMS_LOB.GETLENGTH(l_pdf));
  HTP.P('Content-Disposition: attachment; filename="labels.pdf"');
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
