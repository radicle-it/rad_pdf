CREATE OR REPLACE PACKAGE rad_pdf_barcode AUTHID DEFINER IS
/*
  rad_pdf_barcode — barcode and QR code rendering for RAD_PDF.
  Oracle 19c+.  AUTHID DEFINER.  Phase 10 of the modular install.

  Stateless: holds no per-document state and requires no close_doc hook
  (same model as rad_pdf_template).

  Depends on: rad_pdf_types, rad_pdf_units, rad_pdf_ctx, rad_pdf_canvas.

  Output is VECTOR: modules are emitted as filled PDF path rectangles via
  rad_pdf_canvas.path — no raster images involved, perfect scaling in print.

  QR encoding logic ported from AS_BARCODE by Anton Scheffer
  (https://github.com/antonscheffer/as_barcode), MIT license.
  See the package body header for the full copyright notice.
*/

-- ---------------------------------------------------------------------------
-- QR code
--
-- Draws a QR code with its lower-left corner at (p_x, p_y) occupying a
-- p_size × p_size square.  The mandatory 4-module quiet zone is INCLUDED
-- in p_size (the printed symbol is slightly smaller than the given square).
--
-- Encoding mode (numeric / alphanumeric / byte / UTF-8 ECI) and version
-- (1..40) are selected automatically from the content.
--
-- p_ec_level: error correction level L (7%), M (15%), Q (25%), H (30%).
--             Default M.  Unknown values fall back to M.
--
-- Raises c_err_barcode when p_value is NULL or exceeds the capacity of
-- version 40 at the requested EC level.
-- ---------------------------------------------------------------------------
  PROCEDURE qrcode(p_doc      IN rad_pdf_types.t_doc_handle,
                   p_value    IN VARCHAR2,
                   p_x        IN NUMBER,
                   p_y        IN NUMBER,
                   p_size     IN NUMBER,
                   p_ec_level IN VARCHAR2              DEFAULT 'M',
                   p_color    IN rad_pdf_types.t_rgb  DEFAULT '000000',
                   p_unit     IN rad_pdf_types.t_unit DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- Introspection helper: number of modules per side (quiet zone included)
-- for the QR code that p_value/p_ec_level would produce.  Useful to compute
-- the module size in advance (module = p_size / side_count).
-- ---------------------------------------------------------------------------
  FUNCTION qrcode_modules(p_value    IN VARCHAR2,
                          p_ec_level IN VARCHAR2 DEFAULT 'M')
    RETURN PLS_INTEGER;

-- ---------------------------------------------------------------------------
-- Code 128
--
-- Bars fill the p_width × p_height box at (p_x, p_y) lower-left, quiet zones
-- (10 modules each side) included.  Subset C (digit pairs) is selected
-- automatically for all-numeric values, subset B otherwise; Latin-1
-- characters are encoded via FNC4.
--
-- p_show_text: human-readable value under the bars (10 pt strip, Helvetica
-- 8 pt).  Skipped silently when p_height < 20 pt.  The current document
-- font is saved and restored; text colour is reset to black afterwards.
--
-- Raises c_err_barcode for NULL values or non-positive dimensions.
-- ---------------------------------------------------------------------------
  PROCEDURE code128(p_doc       IN rad_pdf_types.t_doc_handle,
                    p_value     IN VARCHAR2,
                    p_x         IN NUMBER,
                    p_y         IN NUMBER,
                    p_width     IN NUMBER,
                    p_height    IN NUMBER,
                    p_show_text IN BOOLEAN               DEFAULT TRUE,
                    p_color     IN rad_pdf_types.t_rgb  DEFAULT '000000',
                    p_unit      IN rad_pdf_types.t_unit DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- Code 39
--
-- Standard charset: A-Z 0-9 space - . $ / + %  (values outside it raise
-- c_err_barcode with a clear message).  p_full_ascii => TRUE enables
-- extended Code 39 (full ASCII 0-127, lowercase included).
-- Geometry and p_show_text behave as in code128; the human-readable line
-- is shown between the conventional '*' start/stop delimiters.
-- ---------------------------------------------------------------------------
  PROCEDURE code39(p_doc        IN rad_pdf_types.t_doc_handle,
                   p_value      IN VARCHAR2,
                   p_x          IN NUMBER,
                   p_y          IN NUMBER,
                   p_width      IN NUMBER,
                   p_height     IN NUMBER,
                   p_show_text  IN BOOLEAN               DEFAULT TRUE,
                   p_full_ascii IN BOOLEAN               DEFAULT FALSE,
                   p_color      IN rad_pdf_types.t_rgb  DEFAULT '000000',
                   p_unit       IN rad_pdf_types.t_unit DEFAULT 'pt');

-- ---------------------------------------------------------------------------
-- EAN-13
--
-- The symbol width is fixed by the standard: 113 modules including quiet
-- zones (95 + 11 left + 7 right).  Pass the module width instead of a total
-- width; NULL = nominal 0.33 mm (total ≈ 37.3 mm).  Total width in pt =
-- 113 × module.
--
-- p_digits: 1..13 digits.  Fewer than 13 → left-padded to 12, check digit
-- computed.  Exactly 13 → the 13th digit is VALIDATED as the check digit
-- (c_err_barcode on mismatch).
--
-- p_show_text: standard layout — lead digit in the left quiet zone, six
-- digits per half, guard bars descending through the text line.  Digits are
-- always black.  Skipped when p_height <= 12 modules.
-- ---------------------------------------------------------------------------
  PROCEDURE ean13(p_doc       IN rad_pdf_types.t_doc_handle,
                  p_digits    IN VARCHAR2,
                  p_x         IN NUMBER,
                  p_y         IN NUMBER,
                  p_height    IN NUMBER,
                  p_module_w  IN NUMBER               DEFAULT NULL,
                  p_show_text IN BOOLEAN              DEFAULT TRUE,
                  p_unit      IN rad_pdf_types.t_unit DEFAULT 'pt');

END rad_pdf_barcode;
/
