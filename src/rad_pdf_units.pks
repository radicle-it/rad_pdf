CREATE OR REPLACE PACKAGE rad_pdf_units AUTHID DEFINER IS
/*
  rad_pdf_units — unit conversion, colour helpers and default-value factories.
  Oracle 19c+. Stateless: no package-level variables.
*/

-- ---------------------------------------------------------------------------
-- Unit conversion
-- Supported units: 'mm','cm','pt'/'point','in'/'inch','em'/'pica'/'pc'/'p'
-- All functions return points (1 pt = 1/72 inch).
-- ---------------------------------------------------------------------------
  FUNCTION to_pt(p_value IN NUMBER, p_unit IN rad_pdf_types.t_unit) RETURN NUMBER;
  FUNCTION from_pt(p_value_pt IN NUMBER, p_unit IN rad_pdf_types.t_unit) RETURN NUMBER;

  FUNCTION parse_with_unit(p_str IN VARCHAR2) RETURN NUMBER;

-- ---------------------------------------------------------------------------
-- Colour helpers
-- ---------------------------------------------------------------------------
  FUNCTION rgb(p_r IN PLS_INTEGER, p_g IN PLS_INTEGER, p_b IN PLS_INTEGER)
    RETURN rad_pdf_types.t_rgb;

  PROCEDURE assert_rgb(p_rgb IN rad_pdf_types.t_rgb);

-- ---------------------------------------------------------------------------
-- Default-value factories
-- ---------------------------------------------------------------------------
  FUNCTION default_color_scheme   RETURN rad_pdf_types.t_color_scheme;
  FUNCTION default_cell_format    RETURN rad_pdf_types.t_cell_format;
  FUNCTION default_table_options  RETURN rad_pdf_types.t_table_options;
  FUNCTION default_margins        RETURN rad_pdf_types.t_margins;
  FUNCTION default_page_format    RETURN rad_pdf_types.t_page_format;
  FUNCTION default_label_def      RETURN rad_pdf_types.t_label_def;
  FUNCTION default_page_template  RETURN rad_pdf_types.t_page_template;

  FUNCTION page_format(p_name IN VARCHAR2) RETURN rad_pdf_types.t_page_format;

-- ---------------------------------------------------------------------------
-- Border mask helper: parse 'TBLR','TB','LR',... into bitmask.
-- ---------------------------------------------------------------------------
  FUNCTION border_mask(p_str IN VARCHAR2) RETURN rad_pdf_types.t_border_msk;

-- ---------------------------------------------------------------------------
-- Decimal separator for current NLS settings (used internally).
-- ---------------------------------------------------------------------------
  FUNCTION decimal_sep RETURN VARCHAR2;

END rad_pdf_units;
/
