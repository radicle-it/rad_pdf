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

END rad_pdf_barcode;
/
